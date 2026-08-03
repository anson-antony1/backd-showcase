-- Copied verbatim from the private Backd repo: supabase/migrations/019_group_goals_v1.sql
-- Reproduced unmodified for reference. Nothing was redacted — this file
-- contains no credentials; every secret is read at runtime from the
-- environment (Supabase secrets / App Group storage).

-- =============================================================================
-- Migration 019: Group Goals v1 (invite-only, cooperative)
--
-- The first step of the social accountability layer: close friends commit to
-- the SAME goal together and see who is "locked in." Scope is deliberately
-- tight (see docs/GROUP_GOALS.md):
--   * invite-only, COOPERATIVE mode only (no competitive/leaderboards),
--   * the creator (admin) invites their existing accepted buddies,
--   * members mark themselves "locked in" per day; the group shows "X/Y today",
--   * a small members-only comment thread,
--   * NO group stakes / payments / public groups / real-time presence.
--
-- Everything is ADDITIVE — no existing table/enum/policy is changed, no
-- destructive SQL. There are intentionally NO real-money / stake columns in v1.
--
-- RLS is strict and member-scoped. To check membership inside policies WITHOUT
-- recursive RLS, membership is resolved by SECURITY DEFINER helpers (the same
-- pattern as are_buddies() in migration 013): the function bypasses RLS to read
-- group_goal_members, so the policy that protects that table can call it safely.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

create table if not exists group_goals (
  id           uuid primary key default uuid_generate_v4(),
  creator_id   uuid not null references auth.users(id) on delete cascade,
  title        text not null,
  description  text,
  cadence      text not null default 'daily'
                 check (cadence in ('daily', 'weekdays', 'weekly', 'custom')),
  -- v1 is cooperative only; the check keeps the column ready for future modes
  -- without implying competitive features exist yet.
  mode         text not null default 'cooperative'
                 check (mode in ('cooperative')),
  status       text not null default 'active'
                 check (status in ('active', 'archived')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists group_goal_members (
  id             uuid primary key default uuid_generate_v4(),
  group_goal_id  uuid not null references group_goals(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  role           text not null default 'member' check (role in ('admin', 'member')),
  -- A friendly label captured at invite time (the inviter already knows their
  -- buddy). Stored on the membership so co-members never need to read each
  -- other's profile row — profiles RLS stays owner-only/strict.
  display_label  text,
  status         text not null default 'invited'
                   check (status in ('invited', 'active', 'declined', 'removed')),
  invited_by     uuid references auth.users(id) on delete set null,
  joined_at      timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint group_goal_members_one_per_user unique (group_goal_id, user_id)
);

-- One "locked in" mark per member per day. This is a lightweight social
-- commitment, intentionally separate from personal goals/checkins.
create table if not exists group_goal_checkins (
  id             uuid primary key default uuid_generate_v4(),
  group_goal_id  uuid not null references group_goals(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  checkin_date   date not null default current_date,
  note           text,
  created_at     timestamptz not null default now(),
  constraint group_goal_checkins_one_per_day unique (group_goal_id, user_id, checkin_date)
);

create table if not exists group_goal_comments (
  id             uuid primary key default uuid_generate_v4(),
  group_goal_id  uuid not null references group_goals(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  body           text not null,
  created_at     timestamptz not null default now()
);

-- Lightweight in-app activity feed (member_invited / member_completed / etc).
-- No remote push; this just records events members can see.
create table if not exists group_goal_events (
  id             uuid primary key default uuid_generate_v4(),
  group_goal_id  uuid not null references group_goals(id) on delete cascade,
  actor_id       uuid references auth.users(id) on delete set null,
  subject_id     uuid references auth.users(id) on delete set null,
  event_type     text not null,
  metadata       jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);

drop trigger if exists group_goals_updated_at on group_goals;
create trigger group_goals_updated_at
  before update on group_goals
  for each row execute function set_updated_at();

drop trigger if exists group_goal_members_updated_at on group_goal_members;
create trigger group_goal_members_updated_at
  before update on group_goal_members
  for each row execute function set_updated_at();

-- -----------------------------------------------------------------------------
-- Membership helpers (SECURITY DEFINER — bypass RLS to avoid recursive policy
-- evaluation, exactly like are_buddies() in migration 013).
-- -----------------------------------------------------------------------------

create or replace function is_group_member(p_group uuid, p_user uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from group_goal_members m
    where m.group_goal_id = p_group
      and m.user_id = p_user
      and m.status in ('active', 'invited')
  );
$$;

create or replace function is_active_group_member(p_group uuid, p_user uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from group_goal_members m
    where m.group_goal_id = p_group
      and m.user_id = p_user
      and m.status = 'active'
  );
$$;

-- Admin = the group creator in v1 (only they invite/remove members).
create or replace function is_group_admin(p_group uuid, p_user uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from group_goals g
    where g.id = p_group
      and g.creator_id = p_user
  );
$$;

revoke all on function is_group_member(uuid, uuid)        from public;
revoke all on function is_active_group_member(uuid, uuid) from public;
revoke all on function is_group_admin(uuid, uuid)         from public;
grant execute on function is_group_member(uuid, uuid)        to authenticated;
grant execute on function is_active_group_member(uuid, uuid) to authenticated;
grant execute on function is_group_admin(uuid, uuid)         to authenticated;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------

alter table group_goals          enable row level security;
alter table group_goal_members   enable row level security;
alter table group_goal_checkins  enable row level security;
alter table group_goal_comments  enable row level security;
alter table group_goal_events    enable row level security;

-- group_goals: members read; creator creates/edits/deletes.
drop policy if exists "group_goals: member read" on group_goals;
create policy "group_goals: member read"
  on group_goals for select
  using (creator_id = auth.uid() or is_group_member(id, auth.uid()));

drop policy if exists "group_goals: creator insert" on group_goals;
create policy "group_goals: creator insert"
  on group_goals for insert
  with check (creator_id = auth.uid());

drop policy if exists "group_goals: creator update" on group_goals;
create policy "group_goals: creator update"
  on group_goals for update
  using (creator_id = auth.uid())
  with check (creator_id = auth.uid());

drop policy if exists "group_goals: creator delete" on group_goals;
create policy "group_goals: creator delete"
  on group_goals for delete
  using (creator_id = auth.uid());

-- group_goal_members: members read the roster; admin invites; a user manages
-- their OWN membership (accept/decline/leave); admin removes anyone.
drop policy if exists "group_goal_members: member read" on group_goal_members;
create policy "group_goal_members: member read"
  on group_goal_members for select
  using (user_id = auth.uid() or is_group_member(group_goal_id, auth.uid()));

drop policy if exists "group_goal_members: admin or self insert" on group_goal_members;
create policy "group_goal_members: admin or self insert"
  on group_goal_members for insert
  with check (
    -- the admin (creator) invites members…
    is_group_admin(group_goal_id, auth.uid())
    -- …and the creator can add their own admin row when bootstrapping the group.
    or user_id = auth.uid()
  );

drop policy if exists "group_goal_members: self or admin update" on group_goal_members;
create policy "group_goal_members: self or admin update"
  on group_goal_members for update
  using (user_id = auth.uid() or is_group_admin(group_goal_id, auth.uid()))
  with check (user_id = auth.uid() or is_group_admin(group_goal_id, auth.uid()));

drop policy if exists "group_goal_members: self leave or admin remove" on group_goal_members;
create policy "group_goal_members: self leave or admin remove"
  on group_goal_members for delete
  using (user_id = auth.uid() or is_group_admin(group_goal_id, auth.uid()));

-- group_goal_checkins: members read; a member writes only their OWN "locked in".
drop policy if exists "group_goal_checkins: member read" on group_goal_checkins;
create policy "group_goal_checkins: member read"
  on group_goal_checkins for select
  using (is_group_member(group_goal_id, auth.uid()));

drop policy if exists "group_goal_checkins: own insert" on group_goal_checkins;
create policy "group_goal_checkins: own insert"
  on group_goal_checkins for insert
  with check (user_id = auth.uid() and is_active_group_member(group_goal_id, auth.uid()));

drop policy if exists "group_goal_checkins: own update" on group_goal_checkins;
create policy "group_goal_checkins: own update"
  on group_goal_checkins for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "group_goal_checkins: own delete" on group_goal_checkins;
create policy "group_goal_checkins: own delete"
  on group_goal_checkins for delete
  using (user_id = auth.uid());

-- group_goal_comments: members read; active members write their own; own edit/del.
drop policy if exists "group_goal_comments: member read" on group_goal_comments;
create policy "group_goal_comments: member read"
  on group_goal_comments for select
  using (is_group_member(group_goal_id, auth.uid()));

drop policy if exists "group_goal_comments: own insert" on group_goal_comments;
create policy "group_goal_comments: own insert"
  on group_goal_comments for insert
  with check (user_id = auth.uid() and is_active_group_member(group_goal_id, auth.uid()));

drop policy if exists "group_goal_comments: own update" on group_goal_comments;
create policy "group_goal_comments: own update"
  on group_goal_comments for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "group_goal_comments: own delete" on group_goal_comments;
create policy "group_goal_comments: own delete"
  on group_goal_comments for delete
  using (user_id = auth.uid());

-- group_goal_events: members read; an active member logs events they act on.
drop policy if exists "group_goal_events: member read" on group_goal_events;
create policy "group_goal_events: member read"
  on group_goal_events for select
  using (is_group_member(group_goal_id, auth.uid()));

drop policy if exists "group_goal_events: actor insert" on group_goal_events;
create policy "group_goal_events: actor insert"
  on group_goal_events for insert
  with check (actor_id = auth.uid() and is_active_group_member(group_goal_id, auth.uid()));

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------
create index if not exists idx_group_goals_creator on group_goals(creator_id, status);
create index if not exists idx_group_goal_members_group on group_goal_members(group_goal_id, status);
create index if not exists idx_group_goal_members_user on group_goal_members(user_id, status);
create index if not exists idx_group_goal_checkins_group_date on group_goal_checkins(group_goal_id, checkin_date);
create index if not exists idx_group_goal_comments_group on group_goal_comments(group_goal_id, created_at);
create index if not exists idx_group_goal_events_group on group_goal_events(group_goal_id, created_at desc);

-- Verification hints:
--   select table_name from information_schema.tables
--     where table_name like 'group_goal%';
--   select proname from pg_proc
--     where proname in ('is_group_member','is_active_group_member','is_group_admin');
--   select polname from pg_policies where tablename like 'group_goal%';  -- (pg_policies.policyname)
-- =============================================================================
