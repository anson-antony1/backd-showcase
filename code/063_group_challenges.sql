-- Copied verbatim from the private Backd repo: supabase/migrations/063_group_challenges.sql
-- Reproduced unmodified for reference. Nothing was redacted — this file
-- contains no credentials; every secret is read at runtime from the
-- environment (Supabase secrets / App Group storage).

-- =============================================================================
-- Migration 063: Group Challenges — a time-boxed bundle of group goals
--
-- WHAT: lets a group run a multi-rule challenge together (e.g. "30-Day Hard":
-- work out 5×/week + run 2 miles every day + no junk food, for 30 days).
-- A challenge is an UMBRELLA row; each rule inside it is a full, ordinary
-- `group_goals` row tagged with `challenge_id`. Check-ins, standings, comments,
-- events, trophies, and the weekly recap all keep working per-rule with ZERO
-- new machinery — this migration deliberately adds no parallel checkin/member
-- tables (do-not-duplicate contract, BACKD_FUTURE_FEATURE_ARCHITECTURE §17.15).
--
-- Membership: a challenge has no member table of its own. You are "in" a
-- challenge iff you are a member of any of its rule goals; the service invites
-- and accepts across all rules in one operation. This keeps 019's entire RLS
-- membership model authoritative.
--
-- `goal_kind` ('do' | 'abstain') is added to group_goals so "don't eat junk
-- food" rules can render honest copy ("Avoided it today") instead of
-- pretending abstention is an activity. Pure copy/UX hint — no behavior
-- change for existing rows (default 'do').
--
-- Hard mode is a READ-side concept: the client computes each member's current
-- clean-day run from existing group_goal_checkins (see
-- src/services/groupChallenges.ts). Nothing here enforces or punishes — a
-- broken run just restarts the counter, framed recovery-first (no shame UX).
--
-- SAFETY / HOUSE RULES: additive + idempotent only; RLS enabled in this same
-- file; helpers follow 019's SECURITY DEFINER pattern; no money columns; no
-- public visibility — every read path is member-scoped.
--
-- Rollback: drop policies + `drop table group_challenges cascade;` +
-- `alter table group_goals drop column challenge_id, drop column goal_kind;`
-- (cascade removes only the FK link values, not any group goal).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. The challenge umbrella
-- -----------------------------------------------------------------------------

create table if not exists group_challenges (
  id           uuid primary key default uuid_generate_v4(),
  creator_id   uuid not null references auth.users(id) on delete cascade,
  title        text not null,
  description  text,
  -- Time-boxing is REQUIRED for a challenge (that's what makes it one).
  start_date   date not null,
  end_date     date not null,
  -- 'standard': adherence % over the window. 'hard': a missed required daily
  -- rule restarts the member's personal clean-day run (30-day-hard style).
  -- Judged client-side; stored so every member sees the same rules of the game.
  mode         text not null default 'standard'
                 check (mode in ('standard', 'hard')),
  status       text not null default 'active'
                 check (status in ('active', 'completed', 'archived')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint group_challenges_window_valid check (start_date <= end_date),
  -- 365-day cap: a "challenge" longer than a year is an open-ended goal and
  -- should be one.
  constraint group_challenges_window_sane check (end_date - start_date < 365)
);

drop trigger if exists group_challenges_updated_at on group_challenges;
create trigger group_challenges_updated_at
  before update on group_challenges
  for each row execute function set_updated_at();

-- -----------------------------------------------------------------------------
-- 2. Link rule goals to their challenge + the do/abstain kind
-- -----------------------------------------------------------------------------

alter table group_goals
  add column if not exists challenge_id uuid references group_challenges(id) on delete cascade;

alter table group_goals
  add column if not exists goal_kind text not null default 'do';

do $$ begin
  if not exists (
    select 1 from pg_constraint where conname = 'group_goals_goal_kind_check'
  ) then
    alter table group_goals
      add constraint group_goals_goal_kind_check check (goal_kind in ('do', 'abstain'));
  end if;
end $$;

create index if not exists group_goals_challenge_idx
  on group_goals (challenge_id) where challenge_id is not null;

-- -----------------------------------------------------------------------------
-- 3. Membership helper (SECURITY DEFINER — same pattern as is_group_member in
--    019; bypasses RLS to answer "is this user in any of this challenge's rule
--    goals?" without recursive-policy problems).
-- -----------------------------------------------------------------------------

create or replace function is_challenge_member(p_challenge uuid, p_user uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from group_goals g
    join group_goal_members m on m.group_goal_id = g.id
    where g.challenge_id = p_challenge
      and m.user_id = p_user
      and m.status in ('invited', 'active')
  );
$$;

revoke all on function is_challenge_member(uuid, uuid) from public;
grant execute on function is_challenge_member(uuid, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 4. RLS — members (incl. invitees, so an invite preview can show the
--    challenge) read; only the creator writes.
-- -----------------------------------------------------------------------------

alter table group_challenges enable row level security;

drop policy if exists "group_challenges: member read" on group_challenges;
create policy "group_challenges: member read"
  on group_challenges for select
  using (
    creator_id = auth.uid()
    or is_challenge_member(id, auth.uid())
  );

drop policy if exists "group_challenges: creator insert" on group_challenges;
create policy "group_challenges: creator insert"
  on group_challenges for insert
  with check (creator_id = auth.uid());

drop policy if exists "group_challenges: creator update" on group_challenges;
create policy "group_challenges: creator update"
  on group_challenges for update
  using (creator_id = auth.uid())
  with check (creator_id = auth.uid());

drop policy if exists "group_challenges: creator delete" on group_challenges;
create policy "group_challenges: creator delete"
  on group_challenges for delete
  using (creator_id = auth.uid());

-- =============================================================================
-- Owner verification (SQL editor, after applying):
--   select challenge_id, goal_kind from group_goals limit 1;
--   select id, mode, start_date, end_date from group_challenges limit 1;
--   select is_challenge_member('00000000-0000-0000-0000-000000000000'::uuid, auth.uid());
-- =============================================================================
