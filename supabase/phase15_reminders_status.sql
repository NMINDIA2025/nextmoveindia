-- =====================================================================
-- Phase 15: automatic parent reminders + reliable demo / class status
-- Safe to run more than once. Run in the Supabase SQL Editor.
-- =====================================================================

-- ---------- 1. Reminder settings (one row) ----------------------------
create table if not exists public.reminder_settings (
  id                 int primary key default 1 check (id = 1),
  enabled            boolean not null default true,
  email_day_before   boolean not null default true,
  email_hour_before  boolean not null default true,
  include_demos      boolean not null default true,
  include_classes    boolean not null default true,
  last_run_at        timestamptz,
  updated_at         timestamptz not null default now()
);
insert into public.reminder_settings (id) values (1) on conflict (id) do nothing;
alter table public.reminder_settings enable row level security;
drop policy if exists reminder_settings_admin on public.reminder_settings;
create policy reminder_settings_admin on public.reminder_settings for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists reminder_settings_staff_read on public.reminder_settings;
create policy reminder_settings_staff_read on public.reminder_settings for select to authenticated
  using (public.my_role() in ('counselor','teacher'));

-- ---------- 2. Reminder log -------------------------------------------
create table if not exists public.reminders (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references public.classes(id) on delete cascade,
  kind        text not null check (kind in ('day_before','hour_before','manual')),
  channel     text not null check (channel in ('email','whatsapp')),
  to_email    text,
  to_name     text,
  status      text not null default 'pending' check (status in ('pending','sent','failed')),
  error       text,
  claimed_at  timestamptz not null default now(),
  sent_at     timestamptz,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create unique index if not exists reminders_once on public.reminders (class_id, kind, channel, to_email) where kind <> 'manual';
create index if not exists reminders_class_idx on public.reminders (class_id);
alter table public.reminders enable row level security;
drop policy if exists reminders_admin on public.reminders;
create policy reminders_admin on public.reminders for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
-- staff see the log only for classes they can already see
drop policy if exists reminders_staff_read on public.reminders;
create policy reminders_staff_read on public.reminders for select to authenticated
  using (public.my_role() in ('counselor','teacher') and exists (select 1 from public.classes c where c.id = reminders.class_id));

-- ---------- 3. Clock parser ("5:30 pm", "9:30", "17:30", "5pm") --------
create or replace function public.parse_clock(t text) returns time
language plpgsql immutable set search_path = '' as $$
declare m text[]; h int; mi int; s text := lower(btrim(coalesce(t,'')));
begin
  s := replace(s, '.', ':');
  m := regexp_match(s, '^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$');
  if m is null then return null; end if;
  h := m[1]::int; mi := coalesce(m[2],'0')::int;
  if m[3] = 'pm' and h < 12 then h := h + 12; end if;
  if m[3] = 'am' and h = 12 then h := 0; end if;
  if h > 23 or mi > 59 then return null; end if;
  return make_time(h, mi, 0);
end $$;

-- ---------- 4. Who should be reminded right now -----------------------
create or replace function private.reminder_candidates()
returns table (class_id uuid, cat text, rkind text, to_email text, to_name text, children text,
               title text, course_name text, teacher_name text, meet_link text,
               class_date date, class_time text, duration_min int, start_ts timestamptz)
language sql stable security definer set search_path = '' as $$
  with cls as (
    select c.*, ((c.class_date + public.parse_clock(c.class_time)) at time zone 'Asia/Kolkata') as st
    from public.classes c
    where c.status = 'scheduled' and c.class_date is not null and public.parse_clock(c.class_time) is not null
  ),
  upc as (
    select *, extract(epoch from (st - now())) / 3600.0 as hrs
    from cls where st > now() and st <= now() + interval '26 hours'
  ),
  demo_r as (
    select u.id as class_id, 'demo'::text as cat, u.hrs,
           lower(btrim(l.email)) as email,
           nullif(split_part(coalesce(l.parent_name,''),' ',1),'') as parent,
           nullif(split_part(coalesce(l.child_name,''),' ',1),'') as child
    from upc u join public.leads l on l.id = u.lead_id
    where u.kind = 'demo'
  ),
  roster as (
    select u.id as class_id, s.id as student_id, s.full_name, s.parent_email
    from upc u join public.students s on s.status = 'active' and (
         (u.schedule_id is not null and exists (select 1 from public.schedule_students ss where ss.schedule_id = u.schedule_id and ss.student_id = s.id))
      or (u.schedule_id is null and u.kind in ('batch','workshop') and u.course_name is not null and s.course_name = u.course_name))
    where u.kind <> 'demo'
  ),
  addr as (
    select r.class_id, r.student_id, r.full_name, lower(btrim(x.e)) as email
    from roster r
    cross join lateral (select r.parent_email as e
                        union all select g.email from public.guardian_contacts g where g.student_id = r.student_id) x
    where x.e ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
  ),
  cls_r as (
    select a.class_id, 'class'::text as cat, u.hrs, a.email,
           (select nullif(split_part(coalesce(p.full_name,''),' ',1),'') from public.profiles p where lower(p.email) = a.email limit 1) as parent,
           string_agg(distinct nullif(split_part(a.full_name,' ',1),''), ' & ') as child
    from addr a join upc u on u.id = a.class_id
    group by a.class_id, a.email, u.hrs
  ),
  allr as (select * from demo_r union all select * from cls_r)
  select u.id, r.cat,
         case when r.hrs <= 1.25 then 'hour_before' when r.hrs > 3 then 'day_before' end,
         r.email, r.parent, r.child, u.title, u.course_name, u.teacher_name, u.meet_link,
         u.class_date, u.class_time, u.duration_min, u.st
  from allr r join upc u on u.id = r.class_id
  where r.email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    and case when r.hrs <= 1.25 then 'hour_before' when r.hrs > 3 then 'day_before' end is not null
$$;
revoke all on function private.reminder_candidates() from public, anon, authenticated;

-- ---------- 5. Script talks to these (sync password only) -------------
create or replace function public.sheet_claim_reminders(p_secret text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare st public.reminder_settings; out jsonb;
begin
  perform private.check_sync_secret(p_secret);
  update public.reminder_settings set last_run_at = now() where id = 1 returning * into st;
  if st.id is null or not st.enabled then return '[]'::jsonb; end if;
  -- a sender that crashed leaves "pending" rows: free them for a retry
  delete from public.reminders where status = 'pending' and channel = 'email' and claimed_at < now() - interval '30 minutes';
  with cand as (
    select * from private.reminder_candidates() c
    where ((c.cat = 'demo' and st.include_demos) or (c.cat = 'class' and st.include_classes))
      and ((c.rkind = 'day_before' and st.email_day_before) or (c.rkind = 'hour_before' and st.email_hour_before))
  ), ins as (
    insert into public.reminders (class_id, kind, channel, to_email, to_name)
    select c.class_id, c.rkind, 'email', c.to_email, c.to_name from cand c
    on conflict (class_id, kind, channel, to_email) where kind <> 'manual' do nothing
    returning id, class_id, kind, to_email
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', i.id, 'kind', i.kind, 'cat', c.cat, 'to_email', c.to_email, 'parent', c.to_name, 'children', c.children,
      'title', c.title, 'course', c.course_name, 'teacher', c.teacher_name, 'meet_link', c.meet_link,
      'class_date', c.class_date, 'class_time', c.class_time, 'duration_min', c.duration_min)), '[]'::jsonb)
    into out
  from ins i join cand c on c.class_id = i.class_id and c.rkind = i.kind and c.to_email = i.to_email;
  return out;
end $$;
revoke all on function public.sheet_claim_reminders(text) from public;
grant execute on function public.sheet_claim_reminders(text) to anon, authenticated;

create or replace function public.sheet_finish_reminder(p_secret text, p_id uuid, p_ok boolean, p_error text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_sync_secret(p_secret);
  update public.reminders set status = case when p_ok then 'sent' else 'failed' end,
         sent_at = case when p_ok then now() end, error = left(p_error, 300)
   where id = p_id and status = 'pending';
end $$;
revoke all on function public.sheet_finish_reminder(text,uuid,boolean,text) from public;
grant execute on function public.sheet_finish_reminder(text,uuid,boolean,text) to anon, authenticated;

-- ---------- 6. Team taps "send on WhatsApp": keep a record ------------
create or replace function public.log_reminder(p_class uuid, p_channel text default 'whatsapp') returns void
language plpgsql security definer set search_path = '' as $$
declare c public.classes; l public.leads; me uuid := (select auth.uid()); ok boolean;
begin
  select * into c from public.classes where id = p_class;
  if not found then raise exception 'Class not found'; end if;
  if c.lead_id is not null then select * into l from public.leads where id = c.lead_id; end if;
  ok := public.is_admin() or public.my_role() = 'counselor'
     or (c.lead_id is not null and (l.assigned_to = me or public._lead_in_my_demo(c.lead_id)))
     or exists (select 1 from public.teachers t where t.id = c.teacher_id and t.profile_id = me);
  if not ok then raise exception 'Not allowed'; end if;
  insert into public.reminders (class_id, kind, channel, status, sent_at, created_by, to_name)
  values (p_class, 'manual', coalesce(nullif(p_channel,''),'whatsapp'), 'sent', now(), me,
          (select p.full_name from public.profiles p where p.id = me));
end $$;
revoke all on function public.log_reminder(uuid,text) from public, anon;
grant execute on function public.log_reminder(uuid,text) to authenticated;

-- =====================================================================
-- STATUS FIXES
-- =====================================================================

-- ---------- 7. "Demo conducted" works for every demo -------------------
-- (also demos created straight in Classes with no lead, and can't be done twice)
create or replace function public.complete_demo(p_class uuid, p_rating integer, p_level text, p_interest text,
                                                p_course text, p_notes text, p_next date) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.classes; l public.leads; ok boolean; summary text; me uuid := (select auth.uid());
begin
  select * into c from public.classes where id = p_class and kind = 'demo';
  if not found then raise exception 'Demo not found'; end if;
  if c.status = 'completed' then raise exception 'This demo is already marked as done'; end if;
  if c.status = 'cancelled' then raise exception 'This demo was cancelled'; end if;
  if c.lead_id is not null then select * into l from public.leads where id = c.lead_id; end if;
  ok := public.is_admin()
     or (c.lead_id is not null and (l.assigned_to = me or public._lead_in_my_demo(c.lead_id)))
     or exists (select 1 from public.teachers t where t.id = c.teacher_id and t.profile_id = me);
  if not ok then raise exception 'Not allowed'; end if;
  summary := 'Demo conducted. Rating ' || coalesce(p_rating::text,'-') || '/5'
    || coalesce(' · level: ' || nullif(p_level,''), '')
    || coalesce(' · parent: ' || nullif(p_interest,''), '')
    || coalesce(' · suggested: ' || nullif(p_course,''), '')
    || coalesce(E'\n' || nullif(trim(p_notes),''), '');
  update public.classes set status = 'completed',
         notes = case when c.lead_id is null then coalesce(c.notes || E'\n', '') || summary else c.notes end
   where id = p_class;
  if c.lead_id is not null then
    perform set_config('nmi.bypass', '1', true);
    update public.leads set status = 'demo_completed',
           next_follow_up = coalesce(p_next, next_follow_up),
           interested_course = coalesce(nullif(p_course,''), interested_course)
     where id = c.lead_id;
    insert into public.lead_activities (lead_id, actor_id, kind, outcome, note, next_follow_up)
    values (c.lead_id, me, 'note', 'note', summary, p_next);
    if l.assigned_to is not null and l.assigned_to is distinct from me then
      insert into public.tasks (title, due_date, priority, lead_id, assignee_id)
      values ('Demo done — share fee & follow up: ' || coalesce(nullif(l.parent_name,''), nullif(l.phone,''), 'lead')
              || coalesce(' (' || nullif(l.child_name,'') || ')', ''), coalesce(p_next, current_date + 1), 'high', c.lead_id, l.assigned_to);
    end if;
  end if;
end $$;

-- ---------- 8. "Parent did not attend" -------------------------------
create or replace function public.demo_no_show(p_class uuid, p_next date, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.classes; l public.leads; ok boolean; me uuid := (select auth.uid()); msg text;
begin
  select * into c from public.classes where id = p_class and kind = 'demo';
  if not found then raise exception 'Demo not found'; end if;
  if c.status <> 'scheduled' then raise exception 'This demo is already closed'; end if;
  if c.lead_id is not null then select * into l from public.leads where id = c.lead_id; end if;
  ok := public.is_admin()
     or (c.lead_id is not null and (l.assigned_to = me or public._lead_in_my_demo(c.lead_id)))
     or exists (select 1 from public.teachers t where t.id = c.teacher_id and t.profile_id = me);
  if not ok then raise exception 'Not allowed'; end if;
  msg := 'Demo not attended by the parent' || coalesce(E'\n' || nullif(trim(p_note),''), '');
  update public.classes set status = 'cancelled', notes = coalesce(c.notes || E'\n', '') || msg where id = p_class;
  if c.lead_id is not null then
    perform set_config('nmi.bypass', '1', true);
    update public.leads set status = 'call_back_later', next_follow_up = coalesce(p_next, current_date + 1) where id = c.lead_id;
    insert into public.lead_activities (lead_id, actor_id, kind, outcome, note, next_follow_up)
    values (c.lead_id, me, 'note', 'note', msg, coalesce(p_next, current_date + 1));
    if l.assigned_to is not null and l.assigned_to is distinct from me then
      insert into public.tasks (title, due_date, priority, lead_id, assignee_id)
      values ('Demo missed — rebook: ' || coalesce(nullif(l.parent_name,''), nullif(l.phone,''), 'lead')
              || coalesce(' (' || nullif(l.child_name,'') || ')', ''), coalesce(p_next, current_date + 1), 'high', c.lead_id, l.assigned_to);
    end if;
  end if;
end $$;
revoke all on function public.demo_no_show(uuid,date,text) from public, anon;
grant execute on function public.demo_no_show(uuid,date,text) to authenticated;

-- ---------- 9. Class -> lead: keep the two in step --------------------
create or replace function public.classes_sync_lead() returns trigger
language plpgsql security definer set search_path = '' as $$
declare ls text;
begin
  if new.kind <> 'demo' or new.lead_id is null or new.status is not distinct from old.status then return null; end if;
  select status into ls from public.leads where id = new.lead_id;
  if ls in ('demo_scheduled','demo_rescheduled') then
    perform set_config('nmi.bypass', '1', true);
    if new.status = 'completed' then
      update public.leads set status = 'demo_completed', next_follow_up = coalesce(next_follow_up, current_date + 1) where id = new.lead_id;
    elsif new.status = 'cancelled' and not exists (
        select 1 from public.classes o where o.lead_id = new.lead_id and o.kind = 'demo' and o.status = 'scheduled' and o.id <> new.id) then
      update public.leads set status = 'call_back_later', next_follow_up = coalesce(next_follow_up, current_date + 1) where id = new.lead_id;
    end if;
  end if;
  return null;
end $$;
drop trigger if exists classes_sync_lead_trg on public.classes;
create trigger classes_sync_lead_trg after update of status on public.classes
  for each row execute function public.classes_sync_lead();

-- ---------- 10. Attendance taken => the class is done ------------------
create or replace function public.attendance_complete_class() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.classes set status = 'completed'
   where id = new.class_id and status = 'scheduled' and class_date <= current_date;
  return null;
end $$;
drop trigger if exists attendance_complete_class_trg on public.attendance;
create trigger attendance_complete_class_trg after insert on public.attendance
  for each row execute function public.attendance_complete_class();
