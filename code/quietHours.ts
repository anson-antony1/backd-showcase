// Copied verbatim from the private Backd repo: src/lib/quietHours.ts
// Reproduced unmodified for reference. Nothing was redacted — this file
// contains no credentials; every secret is read at runtime from the
// environment (Supabase secrets / App Group storage).

// ---------------------------------------------------------------------------
// Pure, dependency-free mirror of fn_quiet_hours_release (SQL,
// supabase/migrations/062_notification_dispatcher.sql §5, roadmap task #7).
// Exists ONLY to make that SQL function's cross-midnight boundary logic
// testable without a live database connection (§17.3: pure-logic harness
// only) — the same "mirror, don't fix" spirit as sweepKeyForDueAt
// (src/services/checkins.ts) / tests/unit/sweepParity.test.ts, which pins
// the CLIENT's window math against what the SQL sweep assumes. This module
// pins the opposite direction: what the SQL quiet-hours function computes,
// expressed in JS so a boundary-matrix Vitest suite can catch drift between
// the two independent implementations.
//
// Unlike checkins.ts's todayAtTime/formatLocalDate (which rely on the HOST
// process's own TZ via Date's local getters — fine for a client that always
// runs IN the user's own timezone), this takes an explicit IANA `timeZone`
// argument and resolves it via Intl.DateTimeFormat — because the SQL
// function receives an explicit STORED profiles.timezone for a recipient who
// is very much not the machine evaluating the function (a cron job running
// in the database's own zone, for potentially thousands of recipients each
// in a different zone).
// ---------------------------------------------------------------------------

export type QuietHoursTime = { hour: number; minute: number; second: number };

/** Parses a Postgres `time` value ('HH:MM' or 'HH:MM:SS'). Null/invalid -> null. */
export function parseQuietHoursTime(value: string | null | undefined): QuietHoursTime | null {
  if (!value) return null;
  const m = /^(\d{1,2}):(\d{2})(?::(\d{2}))?$/.exec(value.trim());
  if (!m) return null;
  const hour = Number(m[1]);
  const minute = Number(m[2]);
  const second = m[3] ? Number(m[3]) : 0;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) return null;
  return { hour, minute, second };
}

function secondsOfDay(t: QuietHoursTime): number {
  return t.hour * 3600 + t.minute * 60 + t.second;
}

type ZonedParts = { year: number; month: number; day: number; hour: number; minute: number; second: number };

/** The wall-clock date/time `instant` reads as inside IANA zone `timeZone`. */
function zonedParts(instant: Date, timeZone: string): ZonedParts {
  const dtf = new Intl.DateTimeFormat('en-US', {
    timeZone,
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit',
    hour12: false,
  });
  const parts: Record<string, string> = {};
  for (const p of dtf.formatToParts(instant)) {
    if (p.type !== 'literal') parts[p.type] = p.value;
  }
  // A few ICU builds render midnight as "24" under hour12:false; normalize.
  const hour = Number(parts.hour) % 24;
  return {
    year: Number(parts.year),
    month: Number(parts.month),
    day: Number(parts.day),
    hour,
    minute: Number(parts.minute),
    second: Number(parts.second),
  };
}

/**
 * Converts a wall-clock date/time in `timeZone` to the UTC instant it
 * represents — the inverse of zonedParts. Standard single-correction
 * technique: use Date.UTC as an offset GUESS, read what that guess actually
 * reads as in the target zone, then correct once by the difference. Exact
 * for every ordinary case, including across a DST transition between the
 * "from" instant's date and the release date, because the correction is
 * always re-derived at the TARGET date/time, not the source's. Ambiguous or
 * nonexistent local times at the transition instant itself are a known,
 * accepted approximation — not reachable by this module's only caller, which
 * targets a quiet_hours_end time, never 2 a.m. itself.
 */
function zonedTimeToUtc(
  year: number, month: number, day: number,
  hour: number, minute: number, second: number,
  timeZone: string
): Date {
  const guessUtcMs = Date.UTC(year, month - 1, day, hour, minute, second);
  const asZoned = zonedParts(new Date(guessUtcMs), timeZone);
  const asZonedUtcMs = Date.UTC(
    asZoned.year, asZoned.month - 1, asZoned.day,
    asZoned.hour, asZoned.minute, asZoned.second
  );
  const offsetMs = asZonedUtcMs - guessUtcMs;
  return new Date(guessUtcMs - offsetMs);
}

function addDays(year: number, month: number, day: number, delta: number) {
  const d = new Date(Date.UTC(year, month - 1, day));
  d.setUTCDate(d.getUTCDate() + delta);
  return { year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate() };
}

/**
 * Pure mirror of fn_quiet_hours_release(p_user_id, p_from). Given the
 * recipient's quiet_hours_start/end ('HH:MM[:SS]' or null) and IANA
 * timeZone, returns the ISO instant a job due at `fromIso` should actually
 * release at:
 *   - `fromIso` UNCHANGED if quiet hours aren't configured (either side
 *     null), degenerate (start === end), or `fromIso` falls outside the
 *     window;
 *   - otherwise the next occurrence of quiet_hours_end — correctly handling
 *     a window that wraps past midnight (start > end) via an OR test
 *     (now >= start OR now < end), never a plain BETWEEN.
 */
export function computeQuietHoursRelease(
  fromIso: string,
  quietHoursStart: string | null | undefined,
  quietHoursEnd: string | null | undefined,
  timeZone: string
): string {
  const start = parseQuietHoursTime(quietHoursStart);
  const end = parseQuietHoursTime(quietHoursEnd);
  if (!start || !end) return fromIso;

  const startSec = secondsOfDay(start);
  const endSec = secondsOfDay(end);
  if (startSec === endSec) return fromIso; // degenerate window: treat as none configured

  const local = zonedParts(new Date(fromIso), timeZone);
  const nowSec = secondsOfDay(local);

  let releaseYMD: { year: number; month: number; day: number };
  if (startSec > endSec) {
    // Wraps past midnight (e.g. 22:00-07:00).
    if (nowSec >= startSec) {
      // Evening side: release lands tomorrow at quiet_hours_end.
      releaseYMD = addDays(local.year, local.month, local.day, 1);
    } else if (nowSec < endSec) {
      // Past-midnight side: release lands later today at quiet_hours_end.
      releaseYMD = { year: local.year, month: local.month, day: local.day };
    } else {
      return fromIso; // outside the window (daytime, between end and start)
    }
  } else {
    // Same-day window (e.g. 13:00-14:00).
    if (nowSec >= startSec && nowSec < endSec) {
      releaseYMD = { year: local.year, month: local.month, day: local.day };
    } else {
      return fromIso; // outside the window
    }
  }

  const release = zonedTimeToUtc(
    releaseYMD.year, releaseYMD.month, releaseYMD.day,
    end.hour, end.minute, end.second,
    timeZone
  );
  return release.toISOString();
}
