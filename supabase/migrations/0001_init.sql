-- 0001_init.sql
-- Initial schema for Meta smart glasses identity + transcript pipeline.
-- Mirrors the Swift models in CameraAccess/Models/*.swift.
--
-- Conventions:
--   * snake_case column names (Swift codingKeys layer maps to camelCase on the client)
--   * timestamptz everywhere; the iPhone is single source of wall-clock
--   * jsonb for shapes that already serialize as JSON in the Swift models
--   * vector(N) columns for embeddings — pgvector enables cosine similarity matching
--     directly in SQL once embeddings outgrow what fits in memory
--   * RLS is enabled on every table with NO policies — the iOS app uses the
--     service_role key (bypasses RLS); anon/authenticated roles are denied by default.
--     If you ever migrate to per-user auth, add policies here instead of disabling RLS.

set statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
create extension if not exists pgcrypto;
create extension if not exists vector;
create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- Enums (match the Swift String-backed enums)
-- ---------------------------------------------------------------------------
do $$ begin
  create type enrollment_status as enum ('unknown', 'pending', 'pendingName', 'enrolled', 'deleted');
exception when duplicate_object then null; end $$;

do $$ begin
  create type consent_status as enum ('unknown', 'consented', 'revoked');
exception when duplicate_object then null; end $$;

do $$ begin
  create type face_quality_tier as enum (
    'noFace', 'tooSmallForRecognition', 'usableForRecognition',
    'tooSmallForEnrollment', 'usableForEnrollment', 'preferredEnrollment',
    'rejectedBadQuality', 'rejectedBadPose', 'rejectedBadCrop'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type conversation_session_status as enum ('active', 'ended', 'unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type attribution_status as enum ('known', 'possible', 'unknown', 'noFace');
exception when duplicate_object then null; end $$;

do $$ begin
  create type active_identity_state as enum ('none', 'noFace', 'unknown', 'possible', 'confirmed', 'ambiguous');
exception when duplicate_object then null; end $$;

do $$ begin
  create type face_calibration_mode as enum ('samePerson', 'differentPerson');
exception when duplicate_object then null; end $$;

do $$ begin
  create type calibration_label_source as enum ('userTap', 'automatic', 'unknown');
exception when duplicate_object then null; end $$;

do $$ begin
  create type diarization_state as enum ('idle', 'recording', 'uploading', 'processing', 'done', 'failed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- Core: app runs and conversation sessions
-- ---------------------------------------------------------------------------
create table if not exists app_runs (
  id            uuid primary key default gen_random_uuid(),
  started_at    timestamptz not null,
  ended_at      timestamptz,
  app_build     text,
  app_version   text,
  device_id     text,
  notes         text,
  created_at    timestamptz not null default now()
);
create index if not exists app_runs_started_at_idx on app_runs (started_at desc);
create index if not exists app_runs_device_id_idx  on app_runs (device_id);

create table if not exists person_profiles (
  id                       uuid primary key default gen_random_uuid(),
  display_name             text not null,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now(),
  notes                    text,
  is_unknown_placeholder   boolean not null default false,
  last_seen_at             timestamptz,
  enrollment_status        enrollment_status not null default 'unknown',
  consent_status           consent_status not null default 'unknown',
  primary_embedding_id     uuid,
  -- denormalized count maintained from the join tables
  embedding_count          integer not null default 0
);
create index if not exists person_profiles_last_seen_idx        on person_profiles (last_seen_at desc nulls last);
create index if not exists person_profiles_enrollment_status_idx on person_profiles (enrollment_status);
create index if not exists person_profiles_display_name_trgm    on person_profiles using gin (display_name gin_trgm_ops);

create table if not exists conversation_sessions (
  id                   uuid primary key default gen_random_uuid(),
  app_run_id           uuid references app_runs (id) on delete set null,
  device_id            text,
  dat_device_id        text,
  person_id            uuid references person_profiles (id) on delete set null,
  started_at           timestamptz not null,
  ended_at             timestamptz,
  stream_started_at    timestamptz,
  stream_ended_at      timestamptz,
  state                text not null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  confidence           real not null default 0,
  status               conversation_session_status not null default 'active'
);
create index if not exists conversation_sessions_started_at_idx on conversation_sessions (started_at desc);
create index if not exists conversation_sessions_person_idx     on conversation_sessions (person_id);
create index if not exists conversation_sessions_app_run_idx    on conversation_sessions (app_run_id);
create index if not exists conversation_sessions_status_idx     on conversation_sessions (status);

-- ---------------------------------------------------------------------------
-- Face identity
-- ---------------------------------------------------------------------------
create table if not exists face_embeddings (
  id                        uuid primary key default gen_random_uuid(),
  person_id                 uuid references person_profiles (id) on delete cascade,
  app_run_id                uuid references app_runs (id) on delete set null,
  conversation_session_id   uuid references conversation_sessions (id) on delete set null,
  -- 512-dim AWS AdaFace output (L2-normalized)
  vector                    vector(512) not null,
  dimension                 integer not null default 512,
  model_name                text not null,
  model_version             text not null,
  model_source              text not null default 'unknown',
  preprocessing_version     text not null default 'unknown',
  quality_score             real,
  frame_number              bigint,
  source_frame_timestamp    timestamptz not null,
  created_at                timestamptz not null default now(),
  sample_image_local_path   text,
  -- the on-device JPEG may also be mirrored to Supabase Storage; key goes here
  sample_image_storage_path text,
  metadata                  jsonb,
  raw_face_box_pixels       jsonb,
  face_box_pixels           jsonb,
  quality_tier              face_quality_tier,
  face_capture_quality      real,
  yaw                       real,
  pitch                     real,
  roll                      real,
  crop_width                integer,
  crop_height               integer,
  source_frame_width        integer,
  source_frame_height       integer,
  orientation_used          text
);
create index if not exists face_embeddings_person_idx     on face_embeddings (person_id);
create index if not exists face_embeddings_session_idx    on face_embeddings (conversation_session_id);
create index if not exists face_embeddings_created_at_idx on face_embeddings (created_at desc);
create index if not exists face_embeddings_model_idx      on face_embeddings (model_name, model_version, preprocessing_version);
-- Cosine-distance ANN index for similarity search (built lazily; can be re-tuned later).
create index if not exists face_embeddings_vector_cosine_idx
  on face_embeddings using ivfflat (vector vector_cosine_ops) with (lists = 100);

create table if not exists person_averaged_face_embeddings (
  id                     uuid primary key default gen_random_uuid(),
  person_id              uuid not null references person_profiles (id) on delete cascade,
  averaged_vector        vector(512) not null,
  vector_dimension       integer not null default 512,
  sample_count           integer not null,
  model_name             text not null,
  model_version          text not null,
  model_source           text not null default 'unknown',
  preprocessing_version  text not null default 'unknown',
  updated_at             timestamptz not null default now(),
  unique (person_id, model_name, model_version, preprocessing_version)
);
create index if not exists person_avg_face_embeddings_person_idx on person_averaged_face_embeddings (person_id);
create index if not exists person_avg_face_embeddings_vec_idx
  on person_averaged_face_embeddings using ivfflat (averaged_vector vector_cosine_ops) with (lists = 50);

-- ---------------------------------------------------------------------------
-- Speaker / voice identity (TitaNet, 192-dim)
-- ---------------------------------------------------------------------------
create table if not exists speaker_embeddings (
  id                       uuid primary key default gen_random_uuid(),
  person_id                uuid references person_profiles (id) on delete cascade,
  app_run_id               uuid references app_runs (id) on delete set null,
  conversation_session_id  uuid references conversation_sessions (id) on delete set null,
  vector                   vector(192) not null,
  dimension                integer not null default 192,
  model_name               text not null,
  model_version            text not null,
  preprocessing_version    text not null,
  embedding_runtime        text,
  duration_seconds         real,
  source_clip_storage_path text,
  recorded_at              timestamptz not null
);
create index if not exists speaker_embeddings_person_idx     on speaker_embeddings (person_id);
create index if not exists speaker_embeddings_session_idx    on speaker_embeddings (conversation_session_id);
create index if not exists speaker_embeddings_recorded_idx   on speaker_embeddings (recorded_at desc);
create index if not exists speaker_embeddings_model_idx      on speaker_embeddings (model_name, model_version, preprocessing_version);
create index if not exists speaker_embeddings_vector_cosine_idx
  on speaker_embeddings using ivfflat (vector vector_cosine_ops) with (lists = 100);

create table if not exists speaker_averaged_embeddings (
  id                     uuid primary key default gen_random_uuid(),
  person_id              uuid not null references person_profiles (id) on delete cascade,
  name                   text,
  averaged_vector        vector(192) not null,
  vector_dimension       integer not null default 192,
  sample_count           integer not null,
  model_name             text not null,
  model_version          text not null,
  preprocessing_version  text not null,
  embedding_runtime      text,
  updated_at             timestamptz not null default now(),
  unique (person_id, model_name, model_version, preprocessing_version)
);
create index if not exists speaker_avg_embeddings_person_idx on speaker_averaged_embeddings (person_id);
create index if not exists speaker_avg_embeddings_vec_idx
  on speaker_averaged_embeddings using ivfflat (averaged_vector vector_cosine_ops) with (lists = 50);

create table if not exists wearer_voice_profiles (
  id                     uuid primary key default gen_random_uuid(),
  device_id              text,
  is_enrolled            boolean not null default false,
  sample_count           integer not null default 0,
  centroid_count         integer not null default 0,
  duration_seconds       real not null default 0,
  consistency_score      real,
  embedding_dimension    integer,
  model_name             text,
  model_version          text,
  preprocessing_version  text,
  centroids              jsonb,                  -- array of vectors as JSON; small (<=6)
  updated_at             timestamptz not null default now(),
  created_at             timestamptz not null default now()
);
create unique index if not exists wearer_voice_profiles_device_uidx on wearer_voice_profiles (device_id);

-- ---------------------------------------------------------------------------
-- Transcripts and conversation events
-- ---------------------------------------------------------------------------
create table if not exists transcript_chunks (
  id                       uuid primary key default gen_random_uuid(),
  app_run_id               uuid not null references app_runs (id) on delete cascade,
  conversation_session_id  uuid not null references conversation_sessions (id) on delete cascade,
  person_id                uuid references person_profiles (id) on delete set null,
  active_identity_state    text not null,
  text                     text not null,
  is_final                 boolean not null,
  started_at               timestamptz,
  ended_at                 timestamptz,
  transcript_updated_at    timestamptz not null,
  source                   text not null,
  created_at               timestamptz not null default now()
);
create index if not exists transcript_chunks_session_idx     on transcript_chunks (conversation_session_id, transcript_updated_at);
create index if not exists transcript_chunks_person_idx      on transcript_chunks (person_id, transcript_updated_at desc);
create index if not exists transcript_chunks_app_run_idx     on transcript_chunks (app_run_id);
create index if not exists transcript_chunks_text_trgm       on transcript_chunks using gin (text gin_trgm_ops);

create table if not exists conversation_events (
  id                  uuid primary key default gen_random_uuid(),
  session_id          uuid not null references conversation_sessions (id) on delete cascade,
  timestamp           timestamptz not null,
  transcript_text     text not null,
  is_final            boolean not null,
  visible_person_id   uuid references person_profiles (id) on delete set null,
  face_confidence     real,
  attribution_status  attribution_status not null default 'unknown'
);
create index if not exists conversation_events_session_idx on conversation_events (session_id, timestamp);

-- ---------------------------------------------------------------------------
-- Diarization (cloud EC2 worker)
-- ---------------------------------------------------------------------------
create table if not exists diarization_jobs (
  id                       uuid primary key default gen_random_uuid(),
  job_external_id          text unique not null,                       -- the jobId used in S3 keys
  app_run_id               uuid references app_runs (id) on delete set null,
  conversation_session_id  uuid references conversation_sessions (id) on delete cascade,
  audio_s3_key             text not null,
  stream_start_unix        double precision not null,
  state                    diarization_state not null default 'idle',
  speaker_count            integer,
  failure_reason           text,
  submitted_at             timestamptz not null default now(),
  processed_at             timestamptz
);
create index if not exists diarization_jobs_session_idx on diarization_jobs (conversation_session_id);
create index if not exists diarization_jobs_state_idx   on diarization_jobs (state);

create table if not exists diarization_segments (
  id                  uuid primary key default gen_random_uuid(),
  job_id              uuid not null references diarization_jobs (id) on delete cascade,
  start_seconds       double precision not null,
  end_seconds         double precision not null,
  speaker_index       integer not null,
  text                text not null,
  resolved_person_id  uuid references person_profiles (id) on delete set null
);
create index if not exists diarization_segments_job_idx     on diarization_segments (job_id);
create index if not exists diarization_segments_speaker_idx on diarization_segments (job_id, speaker_index);

create table if not exists unknown_diarization_speakers (
  id                       uuid primary key default gen_random_uuid(),
  job_id                   uuid not null references diarization_jobs (id) on delete cascade,
  conversation_session_id  uuid references conversation_sessions (id) on delete cascade,
  speaker_label            text not null,
  speaker_index            integer not null,
  clip_s3_key              text,
  segment_count            integer not null,
  total_seconds            double precision not null,
  resolved_person_id       uuid references person_profiles (id) on delete set null,
  created_at               timestamptz not null default now()
);
create index if not exists unknown_speakers_session_idx on unknown_diarization_speakers (conversation_session_id);
create index if not exists unknown_speakers_job_idx     on unknown_diarization_speakers (job_id);

-- ---------------------------------------------------------------------------
-- Events: face detection, identity match, calibration
-- ---------------------------------------------------------------------------
create table if not exists face_detection_events (
  id                       uuid primary key default gen_random_uuid(),
  app_run_id               uuid not null references app_runs (id) on delete cascade,
  conversation_session_id  uuid references conversation_sessions (id) on delete set null,
  frame_index              integer not null,
  frame_width              integer not null,
  frame_height             integer not null,
  ui_image_orientation     text not null,
  cg_image_width           integer not null,
  cg_image_height          integer not null,
  vision_orientation_used  text not null,
  preferred_face_count     integer not null,
  sweep_face_counts        jsonb not null,
  selected_orientation     text,
  selected_face_count      integer not null,
  created_at               timestamptz not null default now()
);
create index if not exists face_detection_events_app_run_idx on face_detection_events (app_run_id, created_at desc);

create table if not exists identity_match_events (
  id                          uuid primary key default gen_random_uuid(),
  app_run_id                  uuid not null references app_runs (id) on delete cascade,
  conversation_session_id     uuid references conversation_sessions (id) on delete set null,
  frame_number                bigint,
  detected_face_count         integer not null,
  crop_quality_tier           text,
  embedding_model_name        text,
  embedding_model_version     text,
  candidate_person_id         uuid references person_profiles (id) on delete set null,
  cosine_similarity           double precision not null,
  l2_distance                 double precision,
  threshold                   double precision not null,
  rolling_window_size         integer not null,
  rolling_confirm_count       integer not null,
  decision                    text not null,
  rolling_confirmation_state  text,
  created_at                  timestamptz not null default now()
);
create index if not exists identity_match_events_session_idx on identity_match_events (conversation_session_id, created_at desc);
create index if not exists identity_match_events_app_run_idx on identity_match_events (app_run_id, created_at desc);
create index if not exists identity_match_events_person_idx  on identity_match_events (candidate_person_id);

create table if not exists face_calibration_samples (
  id                        uuid primary key default gen_random_uuid(),
  app_run_id                uuid references app_runs (id) on delete set null,
  conversation_session_id   uuid references conversation_sessions (id) on delete set null,
  mode                      face_calibration_mode not null,
  source                    calibration_label_source not null default 'unknown',
  profile_label             text not null,
  score                     real,
  second_best_score         real,
  margin                    real,
  threshold                 real not null,
  decision                  text not null,
  raw_face_width            integer,
  raw_face_height           integer,
  crop_width                integer,
  crop_height               integer,
  quality                   real,
  brightness                real,
  blur                      real,
  accepted_for_recognition  boolean not null,
  accepted_for_enrollment   boolean not null,
  rejection_reason          text,
  created_at                timestamptz not null
);
create index if not exists face_calibration_samples_mode_idx       on face_calibration_samples (mode, created_at desc);
create index if not exists face_calibration_samples_app_run_idx    on face_calibration_samples (app_run_id);

-- ---------------------------------------------------------------------------
-- Glasses display interactions
-- ---------------------------------------------------------------------------
create table if not exists glasses_display_interaction_events (
  id                       uuid primary key default gen_random_uuid(),
  app_run_id               uuid not null references app_runs (id) on delete cascade,
  conversation_session_id  uuid references conversation_sessions (id) on delete set null,
  person_id                uuid references person_profiles (id) on delete set null,
  display_name             text,
  card_title               text not null,
  card_text                text not null,
  action                   text not null,
  source                   text not null,
  created_at               timestamptz not null default now()
);
create index if not exists glasses_display_interactions_session_idx on glasses_display_interaction_events (conversation_session_id, created_at desc);
create index if not exists glasses_display_interactions_person_idx  on glasses_display_interaction_events (person_id, created_at desc);
create index if not exists glasses_display_interactions_action_idx  on glasses_display_interaction_events (action);

-- ---------------------------------------------------------------------------
-- Scene context (Qwen VL 5W1H)
-- ---------------------------------------------------------------------------
create table if not exists scene_context_records (
  id                          uuid primary key default gen_random_uuid(),
  app_run_id                  uuid not null references app_runs (id) on delete cascade,
  conversation_session_id     uuid references conversation_sessions (id) on delete set null,
  person_id                   uuid references person_profiles (id) on delete set null,
  started_at                  timestamptz not null,
  ended_at                    timestamptz not null,
  created_at                  timestamptz not null default now(),
  model_name                  text not null,
  prompt_version              text not null,
  transcript_chunk_ids        jsonb not null,
  frame_timestamps            jsonb not null,
  location_label              text,
  latitude                    double precision,
  longitude                   double precision,
  location_accuracy_meters    double precision,
  who                         text not null,
  where_text                  text not null,
  what                        text not null,
  when_text                   text not null,
  why                         text not null,
  how                         text not null,
  interaction_style           text not null,
  summary                     text not null,
  confidence                  double precision not null,
  evidence                    jsonb not null
);
create index if not exists scene_context_records_session_idx on scene_context_records (conversation_session_id, started_at desc);
create index if not exists scene_context_records_person_idx  on scene_context_records (person_id, started_at desc);

-- ---------------------------------------------------------------------------
-- Now wire the FK person_profiles.primary_embedding_id → face_embeddings (deferred)
-- ---------------------------------------------------------------------------
do $$ begin
  alter table person_profiles
    add constraint person_profiles_primary_embedding_fkey
      foreign key (primary_embedding_id) references face_embeddings (id) on delete set null;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- updated_at touch triggers (cheap; firing only on UPDATE)
-- ---------------------------------------------------------------------------
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

do $$ begin
  create trigger person_profiles_set_updated_at
    before update on person_profiles
    for each row execute function set_updated_at();
exception when duplicate_object then null; end $$;

do $$ begin
  create trigger conversation_sessions_set_updated_at
    before update on conversation_sessions
    for each row execute function set_updated_at();
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- RLS: enable on every table, no policies. The iOS app uses the service_role
-- key (bypasses RLS); anon/authenticated roles get nothing without an explicit
-- policy. When moving to per-user auth, add policies here.
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security;', r.tablename);
    execute format('alter table public.%I force row level security;', r.tablename);
  end loop;
end $$;
