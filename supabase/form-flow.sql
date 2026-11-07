-- Guest forms tied to stay requests (run after booking.sql and forms.sql).
--
-- After someone sends a stay request, its status page asks for what's still missing:
--   - a new family: the whole guest form (family page, a page per pet, waiver),
--   - a known family bringing a pet we don't have yet: just that pet's page,
--   - a family she marked "ask for an updated form" (formUpdate on the family): the form again.
-- It's never required: they can skip it and bring the paper form at drop-off.
-- "Known" means a family in the app (records, kind client) with the request's phone number, or,
-- for someone with a new phone, the same first and last name AND at least one pet with the same
-- name (a name alone could be a different family). A pet is known if that family has one by that name.

alter table public.guest_forms add column if not exists req_token uuid;     -- the request it was sent from
alter table public.guest_forms add column if not exists mode text not null default 'new';  -- new | pets | update

-- What a request still needs. Reveals no details, only which of the names they typed are new.
drop function if exists public.form_needs(text, jsonb);
create or replace function public.form_needs(p_phone text, p_pets jsonb, p_name text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  nm text[] := regexp_split_to_array(lower(trim(coalesce(p_name, ''))), '\s+');
  asked text[] := array(select lower(trim(x->>'name')) from jsonb_array_elements(coalesce(p_pets, '[]')) x);
  c jsonb; have text[]; missing jsonb;
begin
  if length(d) = 10 then
    select r.data into c from records r
     where r.kind = 'client' and not r.deleted and d in (
       right(regexp_replace(coalesce(r.data->>'cell',  ''), '\D', '', 'g'), 10),
       right(regexp_replace(coalesce(r.data->>'phone', ''), '\D', '', 'g'), 10),
       right(regexp_replace(coalesce(r.data->>'work',  ''), '\D', '', 'g'), 10))
     order by r.updated_at desc limit 1;
  end if;
  -- a new phone: same first and last name, and one of the pets they named
  if c is null and array_length(nm, 1) >= 2 then
    select r.data into c from records r
     where r.kind = 'client' and not r.deleted
       and lower(trim(coalesce(r.data->>'first', ''))) = nm[1]
       and lower(trim(coalesce(r.data->>'name',  ''))) = nm[array_length(nm, 1)]
       and exists (select 1 from jsonb_array_elements(coalesce(r.data->'pets', '[]')) q where lower(trim(q->>'name')) = any(asked))
     order by r.updated_at desc limit 1;
  end if;
  if c is null then
    return jsonb_build_object('family', false, 'update', false,
      'newPets', coalesce((select jsonb_agg(trim(x->>'name')) from jsonb_array_elements(coalesce(p_pets, '[]')) x), '[]'::jsonb));
  end if;
  select array_agg(lower(trim(x->>'name'))) into have from jsonb_array_elements(coalesce(c->'pets', '[]')) x;
  select coalesce(jsonb_agg(trim(x->>'name')), '[]'::jsonb) into missing
    from jsonb_array_elements(coalesce(p_pets, '[]')) x
   where not (lower(trim(x->>'name')) = any(coalesce(have, '{}')));
  return jsonb_build_object('family', true, 'newPets', missing, 'update', coalesce((c->>'formUpdate')::boolean, false));
end $$;
revoke execute on function public.form_needs(text, jsonb, text) from public, anon, authenticated;

-- The request's status page, now with what it still needs ('form'), while the stay is ahead.
create or replace function public.request_status(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  -- a request past the auto-decline time reads as declined, with her message
  select jsonb_build_object('status', case when timed then 'declined' else r.status end,
    'start', r.start_date, 'end', r.end_date, 'arr', r.arr, 'pick', r.pick, 'pets', r.pets,
    'reply', case when timed then coalesce(nullif(b->>'autoMsg',''), 'Sorry, we weren’t able to get back to you in time. Please call or text us to book.') else r.reply end,
    'form', case when not timed and r.status in ('pending', 'approved') and r.end_date >= public.book_today(b)
      then public.form_needs(r.phone, r.pets, r.name)
           || jsonb_build_object('sent', exists(select 1 from guest_forms g where g.req_token = r.token and g.status <> 'deleted'),
                                 'name', r.name, 'phone', r.phone, 'email', r.email) end)
  from requests r, (select book_rules() b) x,
    lateral (select r.status='pending' and coalesce((b->>'auto')::int, 0) > 0
                    and r.created_at <= now() - make_interval(hours => (b->>'auto')::int) as timed) t
  where r.token = p_token
$$;
grant execute on function public.request_status(uuid) to anon, authenticated;

-- Sending a guest form: as before, plus which request it came from and what kind it is.
-- A "pets" form (new pets for a family we know) has no family page or waiver to sign.
create or replace function public.guest_form_submit(p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare d jsonb := p->'data'; o jsonb; t uuid; nm text; ph text; names text; md text; rq uuid;
begin
  if coalesce(p->>'key','') ~ '^[0-9a-fA-F-]{36}$' then
    select id into t from guest_forms where client_key = (p->>'key')::uuid;
    if t is not null then return jsonb_build_object('ok', true, 'id', t); end if;
  end if;
  if jsonb_typeof(d) <> 'object' or length(d::text) > 60000 then return jsonb_build_object('ok', false, 'reason', 'That’s too long.'); end if;
  md := case when d->>'mode' in ('pets', 'update') then d->>'mode' else 'new' end;
  if coalesce(p->>'req','') ~ '^[0-9a-fA-F-]{36}$' then
    select token into rq from requests where token = (p->>'req')::uuid;
  end if;
  o := d->'owner';
  nm := trim(coalesce(o->>'first','') || ' ' || coalesce(o->>'last',''));
  ph := regexp_replace(coalesce(o->>'cell','') || coalesce(o->>'main',''), '\D', '', 'g');
  if length(nm) not between 2 and 100 then return jsonb_build_object('ok', false, 'reason', 'Enter your name.'); end if;
  if length(ph) < 10 then return jsonb_build_object('ok', false, 'reason', 'Enter a phone number with area code.'); end if;
  if jsonb_typeof(d->'pets') <> 'array' or jsonb_array_length(d->'pets') not between 1 and 8 then return jsonb_build_object('ok', false, 'reason', 'Add your pets.'); end if;
  if md <> 'pets' and length(trim(coalesce(d->'sign'->>'name',''))) < 2 then return jsonb_build_object('ok', false, 'reason', 'Sign the form.'); end if;
  select string_agg(trim(x->>'name'), ', ') into names from jsonb_array_elements(d->'pets') x;
  insert into guest_forms (client_key, name, phone, pets, data, req_token, mode)
  values (case when coalesce(p->>'key','') ~ '^[0-9a-fA-F-]{36}$' then (p->>'key')::uuid end,
          nm, coalesce(nullif(o->>'cell',''), o->>'main'), coalesce(names, ''), d, rq, md)
  returning id into t;
  return jsonb_build_object('ok', true, 'id', t);
end $$;
revoke execute on function public.guest_form_submit(jsonb) from public, anon, authenticated;
grant execute on function public.guest_form_submit(jsonb) to service_role;
