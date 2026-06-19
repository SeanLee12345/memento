-- 0002_owner_rls.sql
-- Move the app off the service-role key and onto Supabase Auth (anonymous to
-- start, upgradeable to Apple Sign In via supabase.auth.linkIdentity() later).
--
-- For every public table:
--   * add owner_uid uuid default auth.uid() references auth.users(id) on delete cascade
--   * add the matching index
--   * add per-table policies: select / insert / update / delete keyed on auth.uid()
--   * keep RLS enabled + forced (already set by 0001)
--
-- After this migration the iOS app uses the anon key + a per-install JWT.
-- The service role still bypasses RLS (BYPASSRLS attribute on the role),
-- so migrations and admin scripts from the laptop continue to work.
--
-- owner_uid is intentionally NULLABLE: this preserves the few rows that
-- pre-date this migration (they become unreachable via RLS, which is the
-- correct safe default) and allows service-role admin scripts to insert
-- rows that don't belong to any auth.users entry. Application inserts will
-- always populate owner_uid via the auth.uid() default.

set statement_timeout = '120s';

do $$
declare
  r record;
  t text;
begin
  for r in
    select tablename from pg_tables where schemaname = 'public'
  loop
    t := r.tablename;

    -- 1. Add owner_uid column (idempotent).
    execute format($f$
      alter table public.%I
        add column if not exists owner_uid uuid
          default auth.uid()
          references auth.users (id) on delete cascade
    $f$, t);

    -- 2. Index for the policy lookups + per-user queries.
    execute format($f$
      create index if not exists %I on public.%I (owner_uid)
    $f$, t || '_owner_uid_idx', t);

    -- 3. Drop any prior versions of the policies so this migration is re-runnable.
    execute format('drop policy if exists %I on public.%I', t || '_owner_select', t);
    execute format('drop policy if exists %I on public.%I', t || '_owner_insert', t);
    execute format('drop policy if exists %I on public.%I', t || '_owner_update', t);
    execute format('drop policy if exists %I on public.%I', t || '_owner_delete', t);

    -- 4. Owner-only policies. `to authenticated` covers both regular and
    --    anonymous Supabase auth users (anonymous users still have the
    --    `authenticated` role; `is_anonymous` lives in the JWT claims).
    execute format($f$
      create policy %I on public.%I
        for select to authenticated
        using (owner_uid = auth.uid())
    $f$, t || '_owner_select', t);

    execute format($f$
      create policy %I on public.%I
        for insert to authenticated
        with check (owner_uid = auth.uid())
    $f$, t || '_owner_insert', t);

    execute format($f$
      create policy %I on public.%I
        for update to authenticated
        using (owner_uid = auth.uid())
        with check (owner_uid = auth.uid())
    $f$, t || '_owner_update', t);

    execute format($f$
      create policy %I on public.%I
        for delete to authenticated
        using (owner_uid = auth.uid())
    $f$, t || '_owner_delete', t);
  end loop;
end $$;

-- Helper: a view returning the current user's auth metadata. Lets the iOS app
-- verify which JWT it's running under (auth.uid(), is_anonymous, expires_at)
-- via a single GET. Defined as security_invoker so RLS still applies.
create or replace view public.my_auth_context
  with (security_invoker = true)
  as
  select
    auth.uid()                                         as user_id,
    coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) as is_anonymous,
    (auth.jwt() ->> 'role')                            as jwt_role,
    to_timestamp(((auth.jwt() ->> 'exp')::bigint))     as jwt_expires_at;

grant select on public.my_auth_context to authenticated;
