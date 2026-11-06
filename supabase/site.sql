-- Website content edited in the app (Settings > Website). Paste into Supabase:
-- SQL Editor > New query > Run. Safe to run more than once. Needs schema.sql first.
--
-- The text and photo list live in the shared book as records(kind='site', id='main'),
-- so they sync, keep newest edits and go into the nightly backup like everything else.
-- The public website reads them through site_content() only.
create or replace function public.site_content() returns jsonb
language sql stable security definer set search_path = public as $$
  select data from records where kind='site' and id='main' and not deleted
$$;
revoke execute on function public.site_content() from public;
grant execute on function public.site_content() to anon, authenticated;

-- Website photos: a PUBLIC bucket (anyone can view a photo by its address, like any
-- website image). Signed-in users can add photos; nobody can change or delete them.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('site', 'site', true, 5242880, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "staff add site photos" on storage.objects;
create policy "staff add site photos" on storage.objects for insert to authenticated with check (bucket_id = 'site');
