-- Vet or shot records sent from a stay request's page (run after form-flow.sql).
--
-- The request page (lvpetlodge book.html ?r=<token>) lets them send a photo or PDF for each pet,
-- new or returning, while the request is waiting or booked and the stay is still ahead.
-- requests.docs = [{pet (index into pets), name, kind 'img'|'pdf', path, at}].
-- Files live in the private "docs" bucket at requests/<request id>/<pet>-<n>.jpg|pdf, up to 6 per pet.
-- The request-spot server function (kind "records") runs the human check, calls request_add_docs,
-- then hands back one-time upload links for the new paths ('ix' echoes which of the page's files each one is). In the app, approving the request
-- puts the records on the pets; ones sent after that can be added from the request.

alter table public.requests add column if not exists docs jsonb not null default '[]';

create or replace function public.request_add_docs(p_token uuid, p_docs jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r requests; b jsonb := book_rules(); added jsonb := '[]'; d jsonb; i int; n int;
begin
  select * into r from requests where token = p_token for update;
  if r.id is null or r.status not in ('pending', 'approved') or r.hidden or r.end_date < book_today(b) then
    return jsonb_build_object('ok', false, 'reason', 'This request is closed, so records can’t be added here. Bring them at drop-off, or call or text us.');
  end if;
  if jsonb_typeof(p_docs) is distinct from 'array' or jsonb_array_length(p_docs) not between 1 and 9 then
    return jsonb_build_object('ok', false, 'reason', 'Bad request.');
  end if;
  for d in select * from jsonb_array_elements(p_docs) loop
    if coalesce(d->>'pet', '') !~ '^\d{1,2}$' then continue; end if;
    i := (d->>'pet')::int;
    if i >= jsonb_array_length(r.pets) then continue; end if;
    select count(*) into n from jsonb_array_elements(r.docs || added) x where x->>'pet' = i::text;
    if n >= 6 then continue; end if;
    added := added || jsonb_build_array(jsonb_build_object('pet', i, 'ix', d->'ix',
      'name', left(coalesce(nullif(btrim(d->>'name'), ''), 'Vet record'), 60),
      'kind', case when d->>'kind' = 'pdf' then 'pdf' else 'img' end,
      'path', 'requests/' || r.id || '/' || i || '-' || n || case when d->>'kind' = 'pdf' then '.pdf' else '.jpg' end,
      'at', now()));
  end loop;
  if jsonb_array_length(added) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'That’s as many records as we can take here. Please bring the rest at drop-off.');
  end if;
  update requests set docs = docs || (select jsonb_agg(x - 'ix') from jsonb_array_elements(added) x) where id = r.id;
  return jsonb_build_object('ok', true, 'docs', added, 'name', r.name,
    'pets', (select string_agg(distinct r.pets->((x->>'pet')::int)->>'name', ', ') from jsonb_array_elements(added) x));
end $$;
revoke execute on function public.request_add_docs(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.request_add_docs(uuid, jsonb) to service_role;

-- The request's status page, as in form-flow.sql, plus the records already sent ('docs': pet, name, kind, form):
-- ones sent on this page, and ones sent with a guest form from this request (matched to its pets by name, form: true).
create or replace function public.request_status(p_token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  -- a request past the auto-decline time reads as declined, with her message
  select case when r.status = 'deleted' then null
    when r.hidden or r.end_date < public.book_today(b) then jsonb_build_object('status', 'closed') else
  jsonb_build_object('status', case when timed then 'declined' else r.status end,
    'start', r.start_date, 'end', r.end_date, 'arr', r.arr, 'pick', r.pick, 'pets', r.pets,
    'reply', case when timed then coalesce(nullif(b->>'autoMsg',''), 'Sorry, we weren’t able to get back to you in time. Please call or text us to book.') else r.reply end,
    'docs', (select coalesce(jsonb_agg(z.d), '[]'::jsonb) from (
        select jsonb_build_object('pet', x->'pet', 'name', x->'name', 'kind', x->'kind') d from jsonb_array_elements(r.docs) x
        union all
        select jsonb_build_object('pet', rp.i - 1, 'name', fd->'name', 'kind', fd->'kind', 'form', true)
        from guest_forms g, jsonb_array_elements(coalesce(g.data->'pets', '[]'::jsonb)) fp,
             jsonb_array_elements(case when jsonb_typeof(fp->'docs') = 'array' then fp->'docs' else '[]'::jsonb end) fd,
             jsonb_array_elements(r.pets) with ordinality rp(p, i)
        where g.req_token = r.token and g.status <> 'deleted' and lower(btrim(fp->>'name')) = lower(btrim(rp.p->>'name'))) z),
    'form', case when not timed and r.status in ('pending', 'approved') and r.end_date >= public.book_today(b)
      then public.form_needs(r.phone, r.pets, r.name)
           || jsonb_build_object('sent', exists(select 1 from guest_forms g where g.status <> 'deleted' and (g.req_token = r.token
                   or (g.status = 'new' and right(regexp_replace(g.phone, '\D', '', 'g'), 10) = right(regexp_replace(r.phone, '\D', '', 'g'), 10)))),
                                 'name', r.name, 'phone', r.phone, 'email', r.email) end) end
  from requests r, (select book_rules() b) x,
    lateral (select r.status='pending' and coalesce((b->>'auto')::int, 0) > 0
                    and r.created_at <= now() - make_interval(hours => (b->>'auto')::int) as timed) t
  where r.token = p_token
$$;
grant execute on function public.request_status(uuid) to anon, authenticated;


-- What a request still needs (form_needs, as in form-flow.sql), plus 'onFile': the newest vet record date
-- for each pet of a family we know, so the request page can say records are on file even on another phone.
create or replace function public.form_needs(p_phone text, p_pets jsonb, p_name text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  d text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  nm text[] := regexp_split_to_array(lower(trim(coalesce(p_name, ''))), '\s+');
  asked text[] := array(select lower(trim(x->>'name')) from jsonb_array_elements(coalesce(p_pets, '[]')) x);
  c jsonb; have text[]; missing jsonb; by_name boolean := false; onfile jsonb := '[]';
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
    by_name := c is not null;
  end if;
  -- the newest vet record on file for each pet they named (the date it was added): {pet: index into p_pets, at}
  if c is not null then
    select coalesce(jsonb_agg(jsonb_build_object('pet', a.i - 1, 'at', m.at)), '[]'::jsonb) into onfile
      from jsonb_array_elements(coalesce(p_pets, '[]')) with ordinality a(x, i),
      lateral (select max(dd->>'at') at from jsonb_array_elements(coalesce(c->'pets', '[]')) q,
                 jsonb_array_elements(case when jsonb_typeof(q->'docs') = 'array' then q->'docs' else '[]'::jsonb end) dd
               where lower(trim(q->>'name')) = lower(trim(a.x->>'name')) and coalesce(dd->>'at', '') ~ '^\d{4}-\d\d-\d\d') m
     where m.at is not null;
  end if;
  if c is null or coalesce(c->>'signed', '') = '' then
    return jsonb_build_object('family', false, 'update', false, 'onFile', onfile,
      'newPets', coalesce((select jsonb_agg(trim(x->>'name')) from jsonb_array_elements(coalesce(p_pets, '[]')) x), '[]'::jsonb));
  end if;
  select array_agg(lower(trim(x->>'name'))) into have from jsonb_array_elements(coalesce(c->'pets', '[]')) x;
  select coalesce(jsonb_agg(trim(x->>'name')), '[]'::jsonb) into missing
    from jsonb_array_elements(coalesce(p_pets, '[]')) x
   where not (lower(trim(x->>'name')) = any(coalesce(have, '{}')));
  return jsonb_build_object('family', true, 'newPets', missing, 'newPhone', by_name, 'onFile', onfile,
    'update', by_name or coalesce((c->>'formUpdate')::boolean, false));
end $$;
revoke execute on function public.form_needs(text, jsonb, text) from public, anon, authenticated;
