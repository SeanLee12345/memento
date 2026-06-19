-- 0007_person_average_embedding_space_key.sql
-- Keep averaged face embeddings unique by the full model space. This lets the
-- Supabase mirror store historical 128-d MobileFaceNet averages and 512-d
-- AdaFace averages for the same person without one overwriting the other.

set statement_timeout = '120s';

do $$
declare
  constraint_record record;
begin
  for constraint_record in
    select conname
    from pg_constraint
    where conrelid = 'person_averaged_face_embeddings'::regclass
      and contype = 'u'
      and pg_get_constraintdef(oid) like '%person_id%'
      and pg_get_constraintdef(oid) like '%model_name%'
      and pg_get_constraintdef(oid) like '%model_version%'
      and pg_get_constraintdef(oid) like '%preprocessing_version%'
  loop
    execute format(
      'alter table person_averaged_face_embeddings drop constraint %I',
      constraint_record.conname
    );
  end loop;
end $$;

create unique index if not exists person_avg_face_embeddings_space_uidx
  on person_averaged_face_embeddings (
    person_id,
    model_name,
    model_version,
    model_source,
    preprocessing_version,
    vector_dimension
  );

notify pgrst, 'reload schema';
