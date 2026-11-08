-- New guest forms filled out online (lvpetlodge guest-form.html).
-- The public page can't touch this table: it sends through the request-spot edge function,
-- which checks Turnstile and calls guest_form_submit() with the service key.
-- In the app they show under Requests, and get filed onto a family.

create table if not exists public.guest_forms (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  client_key  uuid unique,                        -- the page's idempotency key (a resend returns the same form)
  name        text not null,
  phone       text not null,
  pets        text not null default '',           -- pet names, for the list
  data        jsonb not null,                     -- everything they filled in (see guest-form.html)
  status      text not null default 'new' check (status in ('new','filed','archived','deleted')),
  client_id   text,                               -- the family it was filed onto
  filed_at    timestamptz
);
-- filed forms can be archived (put away, still kept); only new or archived ones get deleted
alter table public.guest_forms drop constraint if exists guest_forms_status_check;
alter table public.guest_forms add constraint guest_forms_status_check check (status in ('new','filed','archived','deleted'));
create index if not exists guest_forms_status on public.guest_forms (status, created_at desc);

revoke all on public.guest_forms from anon, authenticated, service_role;
grant select, update on public.guest_forms to authenticated;
grant select on public.guest_forms to service_role;
alter table public.guest_forms enable row level security;
drop policy if exists "staff read forms"  on public.guest_forms;
drop policy if exists "staff file forms"  on public.guest_forms;
create policy "staff read forms" on public.guest_forms for select to authenticated using (true);
create policy "staff file forms" on public.guest_forms for update to authenticated using (true) with check (true);

-- p: {key, data:{owner:{first,last,cell,...}, pets:[{name,...}], sign:{name, img, date}, ...}}
create or replace function public.guest_form_submit(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare d jsonb := p->'data'; o jsonb; t uuid; nm text; ph text; names text;
begin
  if coalesce(p->>'key','') ~ '^[0-9a-fA-F-]{36}$' then
    select id into t from guest_forms where client_key = (p->>'key')::uuid;
    if t is not null then return jsonb_build_object('ok', true, 'id', t); end if;
  end if;
  if jsonb_typeof(d) <> 'object' or length(d::text) > 60000 then return jsonb_build_object('ok', false, 'reason', 'That’s too long.'); end if;
  o := d->'owner';
  nm := trim(coalesce(o->>'first','') || ' ' || coalesce(o->>'last',''));
  ph := regexp_replace(coalesce(o->>'cell','') || coalesce(o->>'main',''), '\D', '', 'g');
  if length(nm) not between 2 and 100 then return jsonb_build_object('ok', false, 'reason', 'Enter your name.'); end if;
  if length(ph) < 10 then return jsonb_build_object('ok', false, 'reason', 'Enter a phone number with area code.'); end if;
  if jsonb_typeof(d->'pets') <> 'array' or jsonb_array_length(d->'pets') not between 1 and 8 then return jsonb_build_object('ok', false, 'reason', 'Add your pets.'); end if;
  if length(trim(coalesce(d->'sign'->>'name',''))) < 2 then return jsonb_build_object('ok', false, 'reason', 'Sign the form.'); end if;
  select string_agg(trim(x->>'name'), ', ') into names from jsonb_array_elements(d->'pets') x;
  insert into guest_forms (client_key, name, phone, pets, data)
  values (case when coalesce(p->>'key','') ~ '^[0-9a-fA-F-]{36}$' then (p->>'key')::uuid end,
          nm, coalesce(nullif(o->>'cell',''), o->>'main'), coalesce(names, ''), d)
  returning id into t;
  return jsonb_build_object('ok', true, 'id', t);
end $$;
revoke execute on function public.guest_form_submit(jsonb) from public, anon, authenticated;
grant execute on function public.guest_form_submit(jsonb) to service_role;
