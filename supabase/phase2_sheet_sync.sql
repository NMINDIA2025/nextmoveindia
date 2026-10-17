-- =====================================================================
-- Next Move India LMS  |  Phase 2  |  Two-way Google Sheet sync
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to re-run. Requires phase1_foundation.sql to have been run first.
--
-- How it works: the Google Sheet talks to two guarded functions below.
-- Every call must carry a private secret that only you hold, so the
-- public website key alone can never read or change your leads.
-- =====================================================================
begin;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.app_secrets (
  name       text primary key,
  value      text not null,
  created_at timestamptz not null default now()
);
revoke all on private.app_secrets from public, anon, authenticated;

-- a key that identifies each website-form row, so it is never added twice
alter table public.leads add column if not exists sheet_key text;
create unique index if not exists leads_sheet_key_uidx
  on public.leads (sheet_key) where sheet_key is not null;

create or replace function private.check_sync_secret(p_secret text) returns void
language plpgsql security definer set search_path = '' as $$
declare s text;
begin
  select value into s from private.app_secrets where name = 'sheet_sync';
  if s is null or p_secret is null or p_secret <> s then
    raise exception 'unauthorized' using errcode = '28000';
  end if;
end $$;

-- ---- LMS -> Sheet: every lead, ready to mirror into a tab ---------
create or replace function public.sheet_leads_pull(p_secret text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_sync_secret(p_secret);
  return coalesce((
    select jsonb_agg(to_jsonb(t) order by t.created_at desc)
    from (
      select l.id, l.created_at, l.parent_name, l.phone, l.child_name, l.child_age,
             l.city, l.interested_course, l.status,
             p.email as assigned_email, l.next_follow_up, l.demo_date, l.demo_time,
             l.notes, l.lost_reason,
             to_char(l.updated_at at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') as updated_at
      from public.leads l
      left join public.profiles p on p.id = l.assigned_to
    ) t), '[]'::jsonb);
end $$;

-- ---- Sheet -> LMS: edits to existing leads + brand-new website leads
create or replace function public.sheet_leads_push(p_secret text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  r jsonb; cur public.leads; base timestamptz; st text; aid uuid; ph text; ch text;
  v_ins int := 0; v_upd int := 0; v_skip int := 0; v_conf int := 0; v_bad int := 0;
  allowed text[] := array['new','contacted','interested','call_back_later','demo_scheduled',
    'demo_rescheduled','demo_completed','follow_up','enrolled','not_interested','not_reachable'];
begin
  perform private.check_sync_secret(p_secret);

  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      st := lower(nullif(trim(r->>'status'), ''));
      if st is not null and not (st = any (allowed)) then st := null; end if;

      if nullif(r->>'id', '') is not null then
        -- ---- edit of an existing lead ----
        select * into cur from public.leads where id = (r->>'id')::uuid for update;
        if not found then v_bad := v_bad + 1; continue; end if;

        base := nullif(r->>'base_updated_at', '')::timestamptz;
        if base is not null and cur.updated_at > base then   -- changed in the LMS meanwhile
          v_conf := v_conf + 1; continue;
        end if;

        aid := cur.assigned_to;
        if r ? 'assigned_email' then
          if nullif(trim(r->>'assigned_email'), '') is null then
            aid := null;
          else
            select id into aid from public.profiles
              where lower(email) = lower(trim(r->>'assigned_email')) and role in ('admin','counselor');
            if aid is null then v_bad := v_bad + 1; continue; end if;
          end if;
        end if;

        update public.leads set
          status            = coalesce(st, status),
          assigned_to       = aid,
          interested_course = case when r ? 'interested_course' then nullif(trim(r->>'interested_course'),'') else interested_course end,
          next_follow_up    = case when r ? 'next_follow_up'    then nullif(trim(r->>'next_follow_up'),'')::date else next_follow_up end,
          demo_date         = case when r ? 'demo_date'         then nullif(trim(r->>'demo_date'),'')  else demo_date end,
          demo_time         = case when r ? 'demo_time'         then nullif(trim(r->>'demo_time'),'')  else demo_time end,
          notes             = case when r ? 'notes'             then nullif(r->>'notes','')            else notes end,
          lost_reason       = case when r ? 'lost_reason'       then nullif(r->>'lost_reason','')      else lost_reason end
        where id = cur.id
          and (status, assigned_to, interested_course, next_follow_up, demo_date, demo_time, notes, lost_reason)
              is distinct from
              (coalesce(st, status), aid,
               case when r ? 'interested_course' then nullif(trim(r->>'interested_course'),'') else interested_course end,
               case when r ? 'next_follow_up' then nullif(trim(r->>'next_follow_up'),'')::date else next_follow_up end,
               case when r ? 'demo_date' then nullif(trim(r->>'demo_date'),'') else demo_date end,
               case when r ? 'demo_time' then nullif(trim(r->>'demo_time'),'') else demo_time end,
               case when r ? 'notes' then nullif(r->>'notes','') else notes end,
               case when r ? 'lost_reason' then nullif(r->>'lost_reason','') else lost_reason end);
        if found then v_upd := v_upd + 1; else v_skip := v_skip + 1; end if;

      else
        -- ---- a new lead from the website form ----
        if coalesce(nullif(trim(r->>'parent_name'),''), nullif(trim(r->>'phone'),''), nullif(trim(r->>'child_name'),'')) is null then
          v_skip := v_skip + 1; continue;
        end if;
        if nullif(r->>'sheet_key','') is not null
           and exists (select 1 from public.leads where sheet_key = r->>'sheet_key') then
          v_skip := v_skip + 1; continue;
        end if;
        ph := right(regexp_replace(coalesce(r->>'phone',''), '\D', '', 'g'), 10);
        ch := lower(trim(coalesce(r->>'child_name','')));
        if exists (select 1 from public.leads
                   where phone_norm = ph and lower(trim(coalesce(child_name,''))) = ch) then
          v_skip := v_skip + 1; continue;
        end if;

        insert into public.leads (parent_name, phone, child_name, child_age, city, source, status,
                                  demo_date, demo_time, sheet_key, created_at)
        values (nullif(trim(r->>'parent_name'),''), nullif(trim(r->>'phone'),''),
                nullif(trim(r->>'child_name'),''), nullif(trim(r->>'child_age'),''),
                nullif(trim(r->>'city'),''), 'website', coalesce(st, 'new'),
                nullif(trim(r->>'demo_date'),''), nullif(trim(r->>'demo_time'),''),
                nullif(r->>'sheet_key',''),
                coalesce(nullif(r->>'created_at','')::timestamptz, now()));
        v_ins := v_ins + 1;
      end if;
    exception when others then
      v_bad := v_bad + 1;
    end;
  end loop;

  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'unchanged', v_skip,
                            'conflicts', v_conf, 'rejected', v_bad);
end $$;

revoke all on function public.sheet_leads_pull(text)        from public;
revoke all on function public.sheet_leads_push(text, jsonb) from public;
grant execute on function public.sheet_leads_pull(text)        to anon, authenticated;
grant execute on function public.sheet_leads_push(text, jsonb) to anon, authenticated;

commit;

-- =====================================================================
-- STEP 2 (run this separately, after the block above succeeded):
-- creates your private sync password and shows it once. Copy the value
-- from the result table; you will paste it into the Google Sheet script.
--
--   insert into private.app_secrets (name, value)
--   values ('sheet_sync', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''))
--   on conflict (name) do nothing;
--   select value as "sync password" from private.app_secrets where name = 'sheet_sync';
-- =====================================================================
