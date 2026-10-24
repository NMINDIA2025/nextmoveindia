-- =====================================================================
-- Next Move India LMS | Phase 6 | Demo status -> class, link fixes
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-5.
--
-- * Setting a lead to "Demo scheduled / rescheduled" creates (or updates)
--   a Demo class for it. The Google Sheet script then creates the
--   Google Calendar event with a Google Meet link and writes the link back.
-- * "Demo completed" marks that class completed; "not interested /
--   not reachable" cancels it.
-- * Links typed without https:// (the cause of 404 pages) are fixed.
-- =====================================================================

alter table public.classes add column if not exists lead_id uuid references public.leads(id) on delete set null;
alter table public.classes add column if not exists calendar_event_id text;
create index if not exists classes_lead_idx on public.classes (lead_id);

-- ---------- links: always start with https:// ------------------------
create or replace function public.fix_url(u text) returns text
language sql immutable set search_path = '' as $$
  select case
    when nullif(trim(u),'') is null then null
    when trim(u) ~* '^(https?|mailto|tel):' then trim(u)
    else 'https://' || regexp_replace(trim(u), '^/+', '')
  end
$$;

create or replace function public.fix_links() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_table_name = 'classes' then
    new.meet_link := public.fix_url(new.meet_link);
    new.recording_url := public.fix_url(new.recording_url);
  elsif tg_table_name = 'materials' then
    new.url := public.fix_url(new.url);
  elsif tg_table_name = 'submissions' then
    new.answer_link := public.fix_url(new.answer_link);
  end if;
  return new;
end $$;
drop trigger if exists classes_fix_links on public.classes;
create trigger classes_fix_links before insert or update on public.classes
  for each row execute function public.fix_links();
drop trigger if exists materials_fix_links on public.materials;
create trigger materials_fix_links before insert or update on public.materials
  for each row execute function public.fix_links();
drop trigger if exists submissions_fix_links on public.submissions;
create trigger submissions_fix_links before insert or update on public.submissions
  for each row execute function public.fix_links();

update public.classes   set meet_link = public.fix_url(meet_link), recording_url = public.fix_url(recording_url)
  where (meet_link is not null and meet_link !~* '^https?:') or (recording_url is not null and recording_url !~* '^https?:');
update public.materials set url = public.fix_url(url) where url is not null and url !~* '^https?:';

-- ---------- demo status on a lead -> a Demo class ---------------------
create or replace function public.parse_demo_date(t text) returns date
language plpgsql immutable set search_path = '' as $$
begin
  t := trim(coalesce(t,''));
  if t ~ '^\d{4}-\d{1,2}-\d{1,2}' then return substring(t from '^\d{4}-\d{1,2}-\d{1,2}')::date; end if;
  if t ~ '^\d{1,2}[/.-]\d{1,2}[/.-]\d{4}' then
    return to_date(replace(replace(substring(t from '^\d{1,2}[/.-]\d{1,2}[/.-]\d{4}'),'.','/'),'-','/'), 'DD/MM/YYYY');
  end if;
  return null;
exception when others then return null;
end $$;

create or replace function public.lead_demo_class() returns trigger
language plpgsql security definer set search_path = '' as $$
declare cid uuid; d date; ttl text;
begin
  d := public.parse_demo_date(new.demo_date);
  ttl := 'Free demo – ' || coalesce(nullif(split_part(coalesce(new.child_name,''),' ',1),''), 'new student')
         || coalesce(' (' || nullif(new.interested_course,'') || ')', '');
  if new.status in ('demo_scheduled','demo_rescheduled') then
    select id into cid from public.classes where lead_id = new.id and kind = 'demo' and status = 'scheduled' limit 1;
    if cid is null then
      insert into public.classes (title, course_name, kind, class_date, class_time, duration_min, status, lead_id)
      values (ttl, new.interested_course, 'demo', d, nullif(trim(coalesce(new.demo_time,'')),''), 30, 'scheduled', new.id);
    else
      update public.classes set title = ttl, course_name = new.interested_course, class_date = d,
             class_time = nullif(trim(coalesce(new.demo_time,'')),'') where id = cid;
    end if;
  elsif new.status = 'demo_completed' then
    update public.classes set status = 'completed' where lead_id = new.id and kind = 'demo' and status = 'scheduled';
  elsif new.status in ('not_interested','not_reachable') then
    update public.classes set status = 'cancelled' where lead_id = new.id and kind = 'demo' and status = 'scheduled';
  end if;
  return null;
end $$;
drop trigger if exists leads_demo_class on public.leads;
create trigger leads_demo_class after insert or update of status, demo_date, demo_time, child_name, interested_course on public.leads
  for each row execute function public.lead_demo_class();
revoke all on function public.lead_demo_class() from public, anon, authenticated;
revoke all on function public.fix_links() from public, anon, authenticated;

-- sheet script may store the calendar event id
create or replace function private.sync_spec(p_table text, out cols text[], out can_insert boolean)
language plpgsql immutable set search_path = '' as $$
begin
  case p_table
    when 'students'    then cols := array['full_name','age','course_name','batch_timings','sessions_completed','total_sessions','progress_notes','status','joined_at','parent_email']; can_insert := true;
    when 'teachers'    then cols := array['full_name','email','phone','subject','status']; can_insert := true;
    when 'tasks'       then cols := array['title','description','priority','status','due_date','assignee_name']; can_insert := true;
    when 'materials'   then cols := array['title','course_name','kind','url','age_group','language','description','published','sort_order']; can_insert := true;
    when 'classes'     then cols := array['title','course_name','teacher_name','kind','class_date','class_time','duration_min','meet_link','recording_url','status','notes','calendar_event_id']; can_insert := true;
    when 'payments'    then cols := array['course_name','package','amount','due_date','paid_date','status']; can_insert := false;
    when 'attendance'  then cols := array['status','note']; can_insert := false;
    when 'assignments' then cols := array['title','instructions','course_name','due_date','answer_type','published']; can_insert := true;
    when 'submissions' then cols := array['feedback','grade']; can_insert := false;
    else cols := null; can_insert := false;
  end case;
end $$;
revoke all on function private.sync_spec(text) from public, anon, authenticated;

-- demos already scheduled before this was installed
insert into public.classes (title, course_name, kind, class_date, class_time, duration_min, status, lead_id)
select 'Free demo – ' || coalesce(nullif(split_part(coalesce(l.child_name,''),' ',1),''), 'new student')
         || coalesce(' (' || nullif(l.interested_course,'') || ')', ''),
       l.interested_course, 'demo', public.parse_demo_date(l.demo_date), nullif(trim(coalesce(l.demo_time,'')),''), 30, 'scheduled', l.id
from public.leads l
where l.status in ('demo_scheduled','demo_rescheduled')
  and public.parse_demo_date(l.demo_date) >= current_date
  and not exists (select 1 from public.classes c where c.lead_id = l.id and c.kind = 'demo');

-- ---------- who to invite to a class's Calendar event ------------------
-- (teacher email + the parent's email for a demo). Used only by the sheet
-- script with the sync password; parent emails are never exposed to teachers.
create or replace function public.sheet_class_guests(p_secret text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_sync_secret(p_secret);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id,
             'emails', to_jsonb(array_remove(array[nullif(trim(t.email),''), nullif(trim(l.email),'')], null))))
    from public.classes c
    left join public.teachers t on t.id = c.teacher_id
    left join public.leads l on l.id = c.lead_id
    where c.status = 'scheduled'), '[]'::jsonb);
end $$;
revoke all on function public.sheet_class_guests(text) from public;
grant execute on function public.sheet_class_guests(text) to anon, authenticated;
