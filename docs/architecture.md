# Architecture

Backd is a React Native / Expo app on Supabase. The shape of the system is driven
by one rule: **the client is never trusted with privilege it doesn't need.**

## Layers

```
┌──────────────────────────────────────────────────────────────────────┐
│ Client — React Native / Expo, TypeScript                             │
│                                                                      │
│   67 screens (expo-router)                                           │
│   64 service modules in src/services — all Postgres access goes      │
│     through these, never straight from a component                   │
│   4 Swift native modules (Screen Time among them)                    │
│   1 WidgetKit target + 1 DeviceActivityMonitor extension             │
│                                                                      │
│   Holds: the anon key and the signed-in user's JWT. Nothing else.    │
└──────────────────────────────────────────────────────────────────────┘
                │                                    ▲
                │ supabase-js, as the end user       │ 18 edge functions,
                │                                    │ service-role
                ▼                                    │
╔══════════════════════ RLS boundary ═══════════════════════════════════╗
║ Postgres                                                             ║
║   81 tables — RLS enabled on every one                               ║
║   110 policies in production, built up across 107 migrations         ║
║   SECURITY DEFINER functions for the few operations that must see    ║
║     across users (group aggregates, audit writes, rate checks)       ║
╚══════════════════════════════════════════════════════════════════════╝
```

## Why the boundary sits there

The client authenticates as the end user, so every query it issues is filtered by
policy in the database. That means a compromised or decompiled client is not a
data breach — it can still only read rows its own JWT permits. There is no
"trusted client" path and no service-role key in the bundle.

That forces anything privileged into an edge function:

| Function | Why it can't be client-side |
|---|---|
| `verify-proof` | Holds the vision-provider API key; reads a private storage object; must not be bypassable |
| `moderate-proof-media` | Writes the verdict that decides whether a friend can ever see a proof photo |
| `purge-proof-media` | Scheduled; deletes proof photos whose retention window has ended |
| `send-push` | Needs other users' device tokens |
| `send-buddy-invite` | Writes a row for a user who isn't the caller |
| `generate-report` | Aggregates across a group |
| `delete-account` | Must delete rows the caller can no longer select |
| `apple-token` | Exchanges Sign in with Apple's one-time code for a token stored service-only |
| `revenuecat-webhook`, `app-store-notifications` | Authenticate a third party, not a user |

Plus a shared `_shared/` module for the pieces they all need (CORS, auth
extraction, rate limiting).

The rest are in the repo but ship switched off: `coach`, `send-sms`,
`canvas-import` and `email-tips` sit behind flags, and the four stakes
payment functions run only in Stripe test mode, off by default. A sanity script
fails the build if app code ever holds a Stripe key or calls Stripe, or if a
live key appears anywhere in code. Code that was cut from a release was left in
place rather than deleted.

## The RLS pattern

Policies are written as `DROP POLICY IF EXISTS` then `CREATE POLICY`, which makes
every migration re-runnable. Across 107 files that's 137 creates against 122
drops, resolving to 110 policies in production.

Group data is the interesting case, because a row's visibility depends on
membership in another table rather than on `user_id = auth.uid()`. The naive
version — an inline `EXISTS (select 1 from group_members where ...)` inside each
policy — **recurses**: the subquery reads a table that has its own RLS policy,
which reads membership again.

[`019_group_goals_v1.sql`](../code/019_group_goals_v1.sql) solves that with a
`SECURITY DEFINER` helper, `is_group_member(p_group, p_user)`. Because it runs as
its owner it bypasses RLS, so the recursion stops. Nine policies in that file call
it and there are zero inline `EXISTS` subqueries, which also means the membership
rule is stated once.

The helper is then locked down the way any definer function should be:

```sql
revoke all on function is_group_member(uuid, uuid) from public;
grant execute on function is_group_member(uuid, uuid) to authenticated;
```

It takes the user id as a parameter and returns a boolean, never rows — so it
can answer "is this person a member" without becoming a way to enumerate members.
[`063_group_challenges.sql`](../code/063_group_challenges.sql) reuses the same
pattern for challenges.

## The three-process native problem

The iOS side is not one process:

```
   Backd.app                DeviceActivityMonitor        BackdWidget
   (React Native)           extension                    (WidgetKit)
        │                        │                            │
        │  writes schedule       │  wakes on schedule          │  renders on
        │  + state               │  boundary, applies          │  OS timeline
        │                        │  shields                    │
        └────────────┬───────────┴──────────────┬──────────────┘
                     ▼                          ▼
              App Group container: group.com.anson.lockin
```

The extension and the widget both run when the app does not. Neither can call
into the JS runtime. So the App Group container is the only channel, and every
write to it has to be self-sufficient — enough state for another process to render
or enforce without asking a follow-up question. That constraint is why the widget
payload is denormalised rather than a set of ids to resolve.

## Data flow: a proof submission

1. The client uploads the image to a **private** bucket and inserts a
   `proof_submissions` row. EXIF and GPS are stripped before upload. The image
   is moderated server-side, and no friend can see it until it passes.
2. The client checks a local per-user daily AI budget. If exceeded, it never calls
   the function.
3. `verify-proof` authenticates the caller, authorises them as the proof owner or
   the goal's assigned buddy, and rate-limits per user per hour plus a global
   daily cap.
4. It mints a 120-second signed URL, fetches the image server-side, and sends it
   to the vision model as a data URL. The bucket stays private throughout.
5. The model's reply is parsed defensively, deterministic hard rules can downgrade
   an `approve`, and the verdict is recorded as an advisory audit row.
6. The friend reviewing it sees the proof and the advisory opinion, and makes
   the call. Their decision is reconciled against the model's, which is how
   agreement is tracked over time.

If any of steps 3–5 fail, the client falls back to an on-device rules engine that
is structurally incapable of returning `approve` — so degradation can never
approve anything.
