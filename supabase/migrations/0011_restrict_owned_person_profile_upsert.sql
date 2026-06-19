-- 0011_restrict_owned_person_profile_upsert.sql
-- Prevent authenticated clients from claiming legacy person_profiles rows that
-- do not have an owner. Legacy ownership repair must be performed by a trusted
-- administrative backfill with an explicit user-to-profile mapping.

set statement_timeout = '120s';

create or replace function public.upsert_owned_person_profile(
  p_id uuid,
  p_display_name text,
  p_created_at timestamptz,
  p_updated_at timestamptz,
  p_notes text,
  p_is_unknown_placeholder boolean,
  p_last_seen_at timestamptz,
  p_enrollment_status text,
  p_consent_status text,
  p_primary_embedding_id uuid,
  p_embedding_count integer
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid := auth.uid();
  v_primary_embedding_id uuid;
begin
  if v_owner is null then
    raise exception 'authenticated user required'
      using errcode = '42501';
  end if;

  select fe.id
    into v_primary_embedding_id
    from public.face_embeddings fe
   where fe.id = p_primary_embedding_id
     and fe.owner_uid = v_owner
   limit 1;

  insert into public.person_profiles (
    id,
    display_name,
    created_at,
    updated_at,
    notes,
    is_unknown_placeholder,
    last_seen_at,
    enrollment_status,
    consent_status,
    primary_embedding_id,
    embedding_count,
    owner_uid
  )
  values (
    p_id,
    p_display_name,
    p_created_at,
    p_updated_at,
    p_notes,
    p_is_unknown_placeholder,
    p_last_seen_at,
    p_enrollment_status::public.enrollment_status,
    p_consent_status::public.consent_status,
    v_primary_embedding_id,
    greatest(coalesce(p_embedding_count, 0), 0),
    v_owner
  )
  on conflict (id) do update
    set display_name = excluded.display_name,
        created_at = least(public.person_profiles.created_at, excluded.created_at),
        updated_at = excluded.updated_at,
        notes = excluded.notes,
        is_unknown_placeholder = excluded.is_unknown_placeholder,
        last_seen_at = excluded.last_seen_at,
        enrollment_status = excluded.enrollment_status,
        consent_status = excluded.consent_status,
        primary_embedding_id = coalesce(excluded.primary_embedding_id, public.person_profiles.primary_embedding_id),
        embedding_count = excluded.embedding_count
  where public.person_profiles.owner_uid = v_owner;

  if not found then
    raise exception 'person_profiles row is not owned by authenticated user'
      using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.upsert_owned_person_profile(
  uuid,
  text,
  timestamptz,
  timestamptz,
  text,
  boolean,
  timestamptz,
  text,
  text,
  uuid,
  integer
) from public;

grant execute on function public.upsert_owned_person_profile(
  uuid,
  text,
  timestamptz,
  timestamptz,
  text,
  boolean,
  timestamptz,
  text,
  text,
  uuid,
  integer
) to authenticated;
