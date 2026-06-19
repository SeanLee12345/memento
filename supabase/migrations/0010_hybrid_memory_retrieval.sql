-- Selective semantic memory retrieval for the wearable assistant.
-- Additive only: existing transcript, scene-context, and identity tables remain unchanged.

set statement_timeout = '120s';

create table if not exists public.memory_chunks (
  id                     uuid primary key default gen_random_uuid(),
  owner_uid              uuid not null default auth.uid()
                           references auth.users (id) on delete cascade,
  conversation_id        uuid references public.conversation_sessions (id) on delete cascade,
  stream_id              uuid,
  person_id              uuid references public.person_profiles (id) on delete set null,
  source_record_id       uuid not null,
  source_type            text not null check (source_type in (
                           'transcript_chunk',
                           'stream_summary',
                           'scene_context',
                           'person_note'
                         )),
  chunk_text             text not null,
  summary_text           text,
  keywords               text[] not null default '{}',
  categories             text[] not null default '{}',
  embedding              halfvec(2048) not null,
  embedding_model        text not null default 'nvidia/llama-nemotron-embed-1b-v2',
  start_time             timestamptz,
  end_time               timestamptz,
  importance_score       real check (importance_score is null or importance_score between 0 and 1),
  sensitivity_level      smallint not null default 0 check (sensitivity_level between 0 and 2),
  metadata               jsonb not null default '{}'::jsonb,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  unique (owner_uid, source_type, source_record_id)
);

create index if not exists memory_chunks_owner_created_idx
  on public.memory_chunks (owner_uid, created_at desc);
create index if not exists memory_chunks_owner_person_idx
  on public.memory_chunks (owner_uid, person_id, created_at desc);
create index if not exists memory_chunks_owner_source_idx
  on public.memory_chunks (owner_uid, source_type, created_at desc);
create index if not exists memory_chunks_keywords_gin_idx
  on public.memory_chunks using gin (keywords);
create index if not exists memory_chunks_categories_gin_idx
  on public.memory_chunks using gin (categories);
create index if not exists memory_chunks_text_trgm_idx
  on public.memory_chunks using gin ((coalesce(summary_text, '') || ' ' || chunk_text) gin_trgm_ops);
create index if not exists memory_chunks_embedding_cosine_idx
  on public.memory_chunks using ivfflat (embedding halfvec_cosine_ops) with (lists = 100);

alter table public.memory_chunks enable row level security;
alter table public.memory_chunks force row level security;

drop policy if exists memory_chunks_owner_select on public.memory_chunks;
drop policy if exists memory_chunks_owner_insert on public.memory_chunks;
drop policy if exists memory_chunks_owner_update on public.memory_chunks;
drop policy if exists memory_chunks_owner_delete on public.memory_chunks;

create policy memory_chunks_owner_select on public.memory_chunks
  for select to authenticated using (owner_uid = auth.uid());
create policy memory_chunks_owner_insert on public.memory_chunks
  for insert to authenticated with check (owner_uid = auth.uid());
create policy memory_chunks_owner_update on public.memory_chunks
  for update to authenticated
  using (owner_uid = auth.uid()) with check (owner_uid = auth.uid());
create policy memory_chunks_owner_delete on public.memory_chunks
  for delete to authenticated using (owner_uid = auth.uid());

grant select, insert, update, delete on public.memory_chunks to authenticated;

create or replace function public.hybrid_memory_search(
  p_user_id uuid,
  p_query_embedding halfvec(2048),
  p_query_keywords text[] default '{}',
  p_query_categories text[] default '{}',
  p_person_ids uuid[] default '{}',
  p_limit integer default 8,
  p_min_similarity real default 0.20,
  p_include_source_types text[] default '{}',
  p_max_sensitivity smallint default 1
)
returns table (
  memory_chunk_id uuid,
  conversation_id uuid,
  stream_id uuid,
  person_id uuid,
  chunk_text text,
  summary_text text,
  keywords text[],
  categories text[],
  similarity real,
  final_score real,
  source_type text,
  start_time timestamptz,
  end_time timestamptz,
  created_at timestamptz,
  importance_score real,
  sensitivity_level smallint,
  metadata jsonb
)
language sql
stable
security invoker
set search_path = public
as $$
  with candidates as (
    select
      mc.*,
      greatest(0, 1 - (mc.embedding <=> p_query_embedding))::real as similarity_value,
      (
        select count(*)::real
        from unnest(coalesce(p_query_keywords, '{}'::text[])) as query_keyword
        where lower(query_keyword) = any(mc.keywords)
      ) as keyword_matches,
      (
        select count(*)::real
        from unnest(coalesce(p_query_categories, '{}'::text[])) as query_category
        where lower(query_category) = any(mc.categories)
      ) as category_matches
    from public.memory_chunks mc
    where mc.owner_uid = auth.uid()
      and p_user_id = auth.uid()
      and mc.sensitivity_level <= greatest(0, least(p_max_sensitivity, 2))
      and (
        cardinality(coalesce(p_include_source_types, '{}'::text[])) = 0
        or mc.source_type = any(p_include_source_types)
      )
  ), scored as (
    select
      c.*,
      (
        c.similarity_value * 0.62
        + least(c.keyword_matches, 3) * 0.055
        + least(c.category_matches, 2) * 0.065
        + case when c.person_id = any(coalesce(p_person_ids, '{}'::uuid[])) then 0.12 else 0 end
        + exp(-greatest(0, extract(epoch from (now() - c.created_at)) / 86400) / 180) * 0.06
        + coalesce(c.importance_score, 0.5) * 0.05
        + case c.source_type
            when 'stream_summary' then 0.08
            when 'person_note' then 0.07
            when 'scene_context' then 0.04
            else 0.02
          end
      )::real as score_value
    from candidates c
    where c.similarity_value >= greatest(0, least(p_min_similarity, 1))
       or c.keyword_matches > 0
       or c.category_matches > 0
  )
  select
    s.id,
    s.conversation_id,
    s.stream_id,
    s.person_id,
    s.chunk_text,
    s.summary_text,
    s.keywords,
    s.categories,
    s.similarity_value,
    s.score_value,
    s.source_type,
    s.start_time,
    s.end_time,
    s.created_at,
    s.importance_score,
    s.sensitivity_level,
    s.metadata
  from scored s
  order by s.score_value desc, s.created_at desc
  limit greatest(1, least(p_limit, 20));
$$;

revoke all on function public.hybrid_memory_search(
  uuid, halfvec, text[], text[], uuid[], integer, real, text[], smallint
) from public;
grant execute on function public.hybrid_memory_search(
  uuid, halfvec, text[], text[], uuid[], integer, real, text[], smallint
) to authenticated;
