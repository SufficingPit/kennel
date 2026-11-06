-- Online booking requests. Paste into Supabase: SQL Editor > New query > Run.
-- Safe to run more than once. Needs schema.sql first.
--
-- The public page never reads the schedule. It can only call the functions below,
-- which answer with counts ("4 dog spots open") and accept a request. The rules
-- (hours, shortest stay, closed dates, which kennels are online) come from the app's
-- shared settings row, records(kind='settings', id='main').data->'book'.
--
-- A spot is one kennel free for every night of the stay. A night is the date a pet
-- sleeps there: a stay from Nov 10 to Nov 15 uses the nights of Nov 10 through 14,
-- so the kennel can take a new arrival on Nov 15. Pending requests hold their spots
-- until answered, or (when book.auto > 0) until that many hours pass, when it counts as declined.

create table if not exists public.requests (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  status      text not null default 'pending' check (status in ('pending','approved','declined','cancelled')),
  start_date  date not null,
  end_date    date not null,
  arr         text,                 -- drop-off time, 'HH:MM'
  pick        text,                 -- pickup time
  dog_spots   int  not null default 0,
  cat_spots   int  not null default 0,
  name        text not null,
  phone       text not null,
  email       text,
  pets        jsonb not null default '[]',   -- [{name, species, breed}]
  share       boolean not null default true, -- one family's pets may share a kennel
  notes       text,
  reply       text,                 -- note from the kennel when answering
  answered_at timestamptz,
  answered_by uuid references auth.users(id),
  stay_id     text,                 -- the stay made from it, once approved
  token       uuid not null default gen_random_uuid() unique   -- the customer's status link
);
create index if not exists requests_open on public.requests (status, start_date);
-- the page sends a fresh key with each request, so a double tap or a resend after a dropped
-- connection gives back the same request instead of making a second one
alter table public.requests add column if not exists client_key uuid unique;
-- false while the answer still needs texting from her phone (answers made before this read as sent)
alter table public.requests add column if not exists texted boolean not null default true;

-- Staff (signed in) read and answer requests. Nobody deletes. The public gets nothing
-- directly, only the functions.
revoke all on public.requests from anon, authenticated, service_role;
grant select, update on public.requests to authenticated;
grant select on public.requests to service_role;
alter table public.requests enable row level security;
drop policy if exists "staff read requests"   on public.requests;
drop policy if exists "staff answer requests" on public.requests;
create policy "staff read requests"   on public.requests for select to authenticated using (true);
create policy "staff answer requests" on public.requests for update to authenticated using (true) with check (true);

-- The booking rules, with defaults for anything missing
create or replace function public.book_rules() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce((select data->'book' from records where kind='settings' and id='main' and not deleted), '{}'::jsonb)
$$;

-- Today where the kennel is
create or replace function public.book_today(b jsonb) returns date
language sql stable as $$
  select (now() at time zone coalesce(nullif(b->>'tz',''), 'America/New_York'))::date
$$;

-- Online kennels: (id, kind) where kind is dog or cat
create or replace function public.book_kennels(b jsonb) returns table(kid text, kind text)
language sql stable security definer set search_path = public as $$
  select k->>'id', coalesce(b->'kk'->>(k->>'id'), case when k->>'name' ilike 'c%' then 'cat' else 'dog' end)
  from records r, jsonb_array_elements(r.data->'kennels') k
  where r.kind='settings' and r.id='main' and not r.deleted
$$;

-- Stays that use a kennel: (kennel, first night, end date). A stay that moved kennels
-- partway through (data.moves = [{date, time, kennel}]) counts in each kennel for its part:
-- the night of a move day belongs to the new kennel.
create or replace function public.book_stays() returns table(kid text, s date, e date)
language sql stable security definer set search_path = public as $$
  with st as (select id, data, (data->>'start')::date s0, (data->>'end')::date e0
              from records where kind='stay' and not deleted and coalesce(data->>'status','') <> 'out'),
  pts as (select id, e0, data->>'kennel' k, s0 d from st
          union all
          select id, e0, m->>'kennel', (m->>'date')::date from st, jsonb_array_elements(coalesce(data->'moves','[]'::jsonb)) m
          where (m->>'date')::date > s0 and (m->>'date')::date < e0)
  select k, d, coalesce(lead(d) over (partition by id order by d, k), e0) from pts
$$;

-- Requests still holding spots
create or replace function public.book_holds(b jsonb) returns setof requests
language sql stable security definer set search_path = public as $$
  select * from requests where status='pending'
    and (coalesce((b->>'auto')::int, 0) <= 0 or created_at > now() - make_interval(hours => (b->>'auto')::int))
$$;

-- Open spots for every night from p_from up to (not including) p_to, for the public calendar
create or replace function public.booking_days(p_from date, p_to date)
returns table(day date, dogs int, cats int, closed boolean)
language plpgsql stable security definer set search_path = public as $$
declare b jsonb := book_rules();
begin
  if p_to - p_from > 120 or p_to <= p_from then raise exception 'bad range'; end if;
  return query
  with days as (select d::date as day from generate_series(p_from, p_to - 1, interval '1 day') d),
       ks as (select * from book_kennels(b)),
       st as (select * from book_stays()),
       hd as (select * from book_holds(b))
  select days.day,
    greatest(0, (select count(*) from ks where ks.kind='dog' and not exists (select 1 from st where st.kid=ks.kid and st.s <= days.day and days.day < st.e))::int
      - coalesce((select sum(dog_spots) from hd where hd.start_date <= days.day and days.day < hd.end_date), 0)::int),
    greatest(0, (select count(*) from ks where ks.kind='cat' and not exists (select 1 from st where st.kid=ks.kid and st.s <= days.day and days.day < st.e))::int
      - coalesce((select sum(cat_spots) from hd where hd.start_date <= days.day and days.day < hd.end_date), 0)::int),
    exists (select 1 from jsonb_array_elements(coalesce(b->'closed','[]')) c
            where (c->>'from')::date <= days.day and days.day <= (c->>'to')::date)
  from days order by days.day;
end $$;

-- Can a stay from p_start to p_end be requested? Kennels free for the whole stay,
-- minus spots held by pending requests that overlap it. ok=false comes with a reason.
create or replace function public.booking_check(p_start date, p_end date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b jsonb := book_rules(); td date := book_today(b); dogs int; cats int; why text;
begin
  if p_start is null or p_end is null or p_end <= p_start then why := 'Pick a pickup date after the drop-off date.';
  elsif not coalesce((b->>'on')::boolean, false) then why := 'Online requests are turned off right now. Please call us.';
  elsif p_start < td + coalesce((b->>'lead')::int, 1) then why := 'That’s too soon to book online. Please call us.';
  elsif p_end > td + coalesce((b->>'ahead')::int, 180) then why := 'That’s too far ahead to book yet.';
  elsif p_end - p_start < coalesce((b->>'minN')::int, 1) then why := 'The shortest stay is '||(b->>'minN')||' nights.';
  elsif exists (select 1 from jsonb_array_elements(coalesce(b->'closed','[]')) c
                where (c->>'from')::date <= p_end and p_start <= (c->>'to')::date) then why := 'We’re closed during part of those dates.';
  end if;
  with ks as (select * from book_kennels(b)), st as (select * from book_stays()), hd as (select * from book_holds(b))
  select
    greatest(0, (select count(*) from ks where kind='dog' and not exists (select 1 from st where st.kid=ks.kid and st.s < p_end and p_start < st.e))::int
      - coalesce((select sum(dog_spots) from hd where hd.start_date < p_end and p_start < hd.end_date), 0)::int),
    greatest(0, (select count(*) from ks where kind='cat' and not exists (select 1 from st where st.kid=ks.kid and st.s < p_end and p_start < st.e))::int
      - coalesce((select sum(cat_spots) from hd where hd.start_date < p_end and p_start < hd.end_date), 0)::int)
  into dogs, cats;
  return jsonb_build_object('ok', why is null, 'reason', why, 'dogs', dogs, 'cats', cats);
end $$;

-- What the public page needs to draw itself: hours, fee, rules
create or replace function public.booking_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('on', coalesce((b->>'on')::boolean, false), 'offNote', b->'offNote', 'hours', b->'hours', 'fee', b->'fee', 'eveFee', b->'eveFee', 'eveFrom', b->'eveFrom',
    'minN', b->'minN', 'lead', b->'lead', 'ahead', b->'ahead', 'today', book_today(b))
  from (select book_rules() b) x
$$;

-- Send a request. p: {start, end, arr, pick, name, phone, email, notes, share, pets:[{name, species, breed}]}
-- Returns {ok, token} or {ok:false, reason}.
create or replace function public.request_spot(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b jsonb := book_rules(); c jsonb; s date; e date; nd int; nc int; ds int; cs int; digits text; t uuid; pet jsonb;
  dg text[] := '{}'; cg text[] := '{}'; g text; grouped boolean := false;
begin
  -- one at a time, so two people can't both take the last spot
  perform pg_advisory_xact_lock(hashtext('request_spot'));
  if coalesce(p->>'key','') ~ '^[0-9a-fA-F-]{36}$' then
    select token into t from requests where client_key = (p->>'key')::uuid;
    if t is not null then return jsonb_build_object('ok', true, 'token', t); end if;
  end if;
  begin s := (p->>'start')::date; e := (p->>'end')::date;
  exception when others then return jsonb_build_object('ok', false, 'reason', 'Pick your dates.'); end;
  c := booking_check(s, e);
  if not (c->>'ok')::boolean then return jsonb_build_object('ok', false, 'reason', c->>'reason'); end if;

  if length(trim(coalesce(p->>'name',''))) not between 2 and 80 then return jsonb_build_object('ok', false, 'reason', 'Enter your name.'); end if;
  digits := regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g');
  if length(digits) not between 10 and 11 then return jsonb_build_object('ok', false, 'reason', 'Enter a phone number with area code.'); end if;
  if length(coalesce(p->>'email','')) > 120 or length(coalesce(p->>'notes','')) > 1000 then return jsonb_build_object('ok', false, 'reason', 'That’s too long.'); end if;
  if coalesce(p->>'arr','') !~ '^\d\d:\d\d$' or coalesce(p->>'pick','') !~ '^\d\d:\d\d$' then return jsonb_build_object('ok', false, 'reason', 'Pick drop-off and pickup times.'); end if;
  if jsonb_typeof(p->'pets') <> 'array' or jsonb_array_length(p->'pets') not between 1 and 6 then return jsonb_build_object('ok', false, 'reason', 'Add your pets.'); end if;
  nd := 0; nc := 0;
  for pet in select * from jsonb_array_elements(p->'pets') loop
    if length(trim(coalesce(pet->>'name',''))) not between 1 and 40 or length(coalesce(pet->>'breed','')) > 60 then return jsonb_build_object('ok', false, 'reason', 'Check your pets’ names.'); end if;
    -- pets with the same kennel letter share one kennel (a dog and a cat never share)
    g := nullif(left(pet->>'group', 2), ''); if g is not null then grouped := true; end if;
    if pet->>'species' = 'dog' then nd := nd + 1; if g is not null and not g = any(dg) then dg := dg || g; end if;
    elsif pet->>'species' = 'cat' then nc := nc + 1; if g is not null and not g = any(cg) then cg := cg || g; end if;
    else return jsonb_build_object('ok', false, 'reason', 'We board dogs and cats.'); end if;
  end loop;
  if grouped then
    if dg && cg then return jsonb_build_object('ok', false, 'reason', 'A dog and a cat can’t share a kennel.'); end if;
    ds := cardinality(dg); cs := cardinality(cg);
  elsif coalesce((p->>'share')::boolean, true) then ds := least(nd, 1); cs := least(nc, 1); else ds := nd; cs := nc; end if;
  if ds > (c->>'dogs')::int or cs > (c->>'cats')::int then
    return jsonb_build_object('ok', false, 'reason', 'Not enough open spots for those dates.'); end if;

  -- flood limits: one open request per phone, and a cap per hour overall
  if exists (select 1 from book_holds(b) h where regexp_replace(h.phone, '\D', '', 'g') = digits) then
    return jsonb_build_object('ok', false, 'reason', 'You already have a request waiting. We’ll be in touch soon.'); end if;
  if (select count(*) from requests where created_at > now() - interval '1 hour') >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'We’re getting a lot of requests right now. Please call us.'); end if;

  insert into requests (start_date, end_date, arr, pick, dog_spots, cat_spots, name, phone, email, pets, share, notes, client_key)
  values (s, e, p->>'arr', p->>'pick', ds, cs, trim(p->>'name'), trim(p->>'phone'), nullif(trim(coalesce(p->>'email','')),''),
          p->'pets', coalesce((p->>'share')::boolean, true), nullif(trim(coalesce(p->>'notes','')),''),
          case when coalesce(p->>'key','') ~ '^[0-9a-fA-F-]{36}$' then (p->>'key')::uuid end)
  returning token into t;
  return jsonb_build_object('ok', true, 'token', t);
end $$;

-- The customer's status page and cancel button, by the token in their link
create or replace function public.request_status(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  -- a request past the auto-decline time reads as declined, with her message
  select jsonb_build_object('status', case when timed then 'declined' else r.status end,
    'start', r.start_date, 'end', r.end_date, 'arr', r.arr, 'pick', r.pick, 'pets', r.pets,
    'reply', case when timed then coalesce(nullif(b->>'autoMsg',''), 'Sorry, we weren’t able to get back to you in time. Please call or text us to book.') else r.reply end)
  from requests r, (select book_rules() b) x,
    lateral (select r.status='pending' and coalesce((b->>'auto')::int, 0) > 0
                    and r.created_at <= now() - make_interval(hours => (b->>'auto')::int) as timed) t
  where r.token = p_token
$$;
create or replace function public.request_cancel(p_token uuid) returns boolean
language sql volatile security definer set search_path = public as $$
  update requests set status = 'cancelled', answered_at = now() where token = p_token and status in ('pending','approved') returning true
$$;

-- Only the public entry points are callable without a login
revoke execute on function public.book_rules(), public.book_today(jsonb), public.book_kennels(jsonb), public.book_stays(), public.book_holds(jsonb) from public, anon, authenticated;
grant execute on function public.booking_days(date, date), public.booking_check(date, date), public.booking_info(),
  public.request_status(uuid), public.request_cancel(uuid) to anon, authenticated;
-- Sending a request goes through the request-spot server function, which runs the
-- spam check first; only that function (with the secret key) may call request_spot.
revoke execute on function public.request_spot(jsonb) from public, anon, authenticated;
grant execute on function public.request_spot(jsonb) to service_role;
