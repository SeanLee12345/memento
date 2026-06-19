-- 0004_presence_episodes.sql
-- Durable, queryable record of who the wearer was with during a stream.
-- App code upserts these rows as face/voice/transcript/name-address evidence
-- changes, then closes active rows when the stream stops or a goodbye/departure
-- signal is detected.

set statement_timeout = '120s';

create table if not exists public.presence_episodes (
  id                       uuid primary key default gen_random_uuid(),
  app_run_id               uuid not null references public.app_runs (id) on delete cascade,
  conversation_session_id  uuid references public.conversation_sessions (id) on delete cascade,
  person_id                uuid references public.person_profiles (id) on delete set null,
  display_name             text not null,
  started_at               timestamptz not null,
  last_evidence_at         timestamptz not null,
  ended_at                 timestamptz,
  status                   text not null,
  confidence               real not null,
  evidence_summary         text not null,
  updated_at               timestamptz not null default now()
);

do $$ begin
  alter table public.presence_episodes
    add constraint presence_episodes_status_check
      check (status in ('active', 'departed', 'uncertain'));
exception when duplicate_object then null; end $$;

create index if not exists presence_episodes_session_idx
  on public.presence_episodes (conversation_session_id, started_at desc);

create index if not exists presence_episodes_person_idx
  on public.presence_episodes (person_id, started_at desc);

create index if not exists presence_episodes_app_run_idx
  on public.presence_episodes (app_run_id, started_at desc);

create index if not exists presence_episodes_status_idx
  on public.presence_episodes (status, last_evidence_at desc);

alter table public.presence_episodes
  add column if not exists owner_uid uuid
    default auth.uid()
    references auth.users (id) on delete cascade;

create index if not exists presence_episodes_owner_uid_idx
  on public.presence_episodes (owner_uid);

alter table public.presence_episodes enable row level security;
alter table public.presence_episodes force row level security;

drop policy if exists presence_episodes_owner_select on public.presence_episodes;
drop policy if exists presence_episodes_owner_insert on public.presence_episodes;
drop policy if exists presence_episodes_owner_update on public.presence_episodes;
drop policy if exists presence_episodes_owner_delete on public.presence_episodes;

create policy presence_episodes_owner_select on public.presence_episodes
  for select to authenticated
  using (owner_uid = auth.uid());

create policy presence_episodes_owner_insert on public.presence_episodes
  for insert to authenticated
  with check (owner_uid = auth.uid());

create policy presence_episodes_owner_update on public.presence_episodes
  for update to authenticated
  using (owner_uid = auth.uid())
  with check (owner_uid = auth.uid());

create policy presence_episodes_owner_delete on public.presence_episodes
  for delete to authenticated
  using (owner_uid = auth.uid());
