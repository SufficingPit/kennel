-- Kennel app database. Paste into Supabase: SQL Editor > New query > Run.
-- Safe to run more than once.
--
-- One business, one shared book: everyone who can sign in (owner, staff) sees and
-- edits the same rows. Sign-ups are off in Supabase, so the only logins are the ones
-- added by hand under Authentication > Users.
--
-- Every piece of the app's data (a family with its pets, a stay, a kennel, a type
-- of care, one check-off, the settings) is one row. Phones send only rows that
-- changed, and rows are never really deleted, only marked deleted.

create table if not exists public.records (
  kind       text        not null,          -- client, stay, log, settings
  id         text        not null,
  data       jsonb,
  deleted    boolean     not null default false,
  updated_at timestamptz not null,          -- when the change was made on the phone
  synced_at  timestamptz not null default now(),  -- when the server got it; phones pull by this
  user_id    uuid        not null default auth.uid() references auth.users(id),  -- who last changed it
  primary key (kind, id)
);
create index if not exists records_pull on public.records (synced_at);

-- Signed-in users can read, add and change; nobody can delete. The nightly backup
-- reads with the secret key (service_role) and gets nothing more than that.
-- Someone without a login gets nothing at all.
revoke all on public.records from anon, authenticated, service_role;
grant select, insert, update on public.records to authenticated;
grant select on public.records to service_role;

alter table public.records enable row level security;
drop policy if exists "staff read"   on public.records;
drop policy if exists "staff add"    on public.records;
drop policy if exists "staff change" on public.records;
create policy "staff read"   on public.records for select to authenticated using (true);
create policy "staff add"    on public.records for insert to authenticated with check (true);
create policy "staff change" on public.records for update to authenticated using (true) with check (true);

-- Newest edit wins. An older edit arriving late (a phone that was offline) never
-- overwrites a newer one. The server stamps who made the change and when it arrived.
create or replace function public.records_keep_newest() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.updated_at <= old.updated_at then
    return null;
  end if;
  new.user_id := coalesce(auth.uid(), new.user_id);
  new.synced_at := clock_timestamp();
  return new;
end $$;
drop trigger if exists records_keep_newest on public.records;
create trigger records_keep_newest before insert or update on public.records
  for each row execute function public.records_keep_newest();
