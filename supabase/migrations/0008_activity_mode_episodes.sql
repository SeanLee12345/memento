-- 0008_activity_mode_episodes.sql
-- Durable, queryable record of stream activity modes classified from
-- multimodal scene context and transcript evidence.

set statement_timeout = '120s';

create table if not exists public.activity_mode_episodes (
  id                       uuid primary key default gen_random_uuid(),
  app_run_id               uuid not null references public.app_runs (id) on delete cascade,
  conversation_session_id  uuid references public.conversation_sessions (id) on delete cascade,
  mode                     text not null,
  specific_activity        text not null,
  started_at               timestamptz not null,
  last_evidence_at         timestamptz not null,
  ended_at                 timestamptz,
  confidence               double precision not null,
  reason                   text not null,
  source                   text not null,
  model_name               text not null,
  prompt_version           text not null,
  updated_at               timestamptz not null default now()
);

do $$ begin
  alter table public.activity_mode_episodes
    add constraint activity_mode_episodes_mode_check
      check (
        mode in (
          'entertainment',
          'sport',
          'study',
          'social',
          'commute',
          'shopping',
          'work',
          'general',
          'unknown',
          'custom'
        )
        or length(mode) between 1 and 24
      );
exception when duplicate_object then null; end $$;

create index if not exists activity_mode_episodes_session_idx
  on public.activity_mode_episodes (conversation_session_id, started_at desc);

create index if not exists activity_mode_episodes_app_run_idx
  on public.activity_mode_episodes (app_run_id, started_at desc);

create index if not exists activity_mode_episodes_mode_idx
  on public.activity_mode_episodes (mode, started_at desc);

alter table public.activity_mode_episodes
  add column if not exists owner_uid uuid
    default auth.uid()
    references auth.users (id) on delete cascade;

create index if not exists activity_mode_episodes_owner_uid_idx
  on public.activity_mode_episodes (owner_uid);

alter table public.activity_mode_episodes enable row level security;
alter table public.activity_mode_episodes force row level security;

drop policy if exists activity_mode_episodes_owner_select on public.activity_mode_episodes;
drop policy if exists activity_mode_episodes_owner_insert on public.activity_mode_episodes;
drop policy if exists activity_mode_episodes_owner_update on public.activity_mode_episodes;
drop policy if exists activity_mode_episodes_owner_delete on public.activity_mode_episodes;

create policy activity_mode_episodes_owner_select on public.activity_mode_episodes
  for select to authenticated
  using (owner_uid = auth.uid());

create policy activity_mode_episodes_owner_insert on public.activity_mode_episodes
  for insert to authenticated
  with check (owner_uid = auth.uid());

create policy activity_mode_episodes_owner_update on public.activity_mode_episodes
  for update to authenticated
  using (owner_uid = auth.uid())
  with check (owner_uid = auth.uid());

create policy activity_mode_episodes_owner_delete on public.activity_mode_episodes
  for delete to authenticated
  using (owner_uid = auth.uid());
