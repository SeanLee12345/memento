-- 0003_storage_rls.sql
-- Per-user storage RLS for the face-crops bucket.
--
-- Object keys must be of the form "<auth.uid()>/<filename>". Storage's
-- storage.foldername(name) splits on '/', so the first segment is the user's
-- uid. Policies allow each authenticated user to CRUD only inside their own
-- folder; the service role still bypasses RLS for migrations and admin scripts.

set statement_timeout = '60s';

-- Drop any prior versions so this migration is re-runnable.
drop policy if exists face_crops_owner_select on storage.objects;
drop policy if exists face_crops_owner_insert on storage.objects;
drop policy if exists face_crops_owner_update on storage.objects;
drop policy if exists face_crops_owner_delete on storage.objects;

create policy face_crops_owner_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'face-crops'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy face_crops_owner_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'face-crops'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy face_crops_owner_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'face-crops'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'face-crops'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy face_crops_owner_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'face-crops'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
