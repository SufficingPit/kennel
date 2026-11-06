-- Kennel app database. Paste into Supabase: SQL Editor > New query > Run.
-- Safe to run more than once.
--
-- Every piece of the app's data (a family with its pets, a stay, a kennel, a type
-- of care, one check-off, the settings) is one row. The phone sends only rows
-- that changed, and rows are never really deleted, only marked deleted.

create table if not exists public.records (
  user_id    uuid        not null default auth.uid() references auth.users(id),
  kind       text        not null,          -- client, stay, kennel, tag, log, settings
  id         text        not null,
  data       jsonb,
  deleted    boolean     not null default false,
  updated_at timestamptz not null,          -- when the change was made on the phone
  synced_at  timestamptz not null default now(),  -- when the server got it; phones pull by this
  primary key (user_id, kind, id)
);
create index if not exists records_pull on public.records (user_id, synced_at);

-- Only signed-in users can use the table at all; someone without a login gets nothing.
revoke all on public.records from anon, authenticated;
grant select, insert, update on public.records to authenticated;

-- Each signed-in user only ever sees and writes their own rows.
alter table public.records enable row level security;
drop policy if exists "read own"   on public.records;
drop policy if exists "add own"    on public.records;
drop policy if exists "change own" on public.records;
create policy "read own"   on public.records for select using (user_id = auth.uid());
create policy "add own"    on public.records for insert with check (user_id = auth.uid());
create policy "change own" on public.records for update using (user_id = auth.uid()) with check (user_id = auth.uid());
-- No delete policy on purpose: the app can't erase anything, it can only mark rows deleted.

-- Newest edit wins. An older edit arriving late (a phone that was offline) never
-- overwrites a newer one. The server stamps synced_at itself.
create or replace function public.records_keep_newest() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.updated_at <= old.updated_at then
    return null;
  end if;
  new.synced_at := clock_timestamp();
  return new;
end $$;
drop trigger if exists records_keep_newest on public.records;
create trigger records_keep_newest before insert or update on public.records
  for each row execute function public.records_keep_newest();
