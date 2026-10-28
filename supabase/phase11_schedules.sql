-- =====================================================================
-- Next Move India LMS | Phase 11 | Course schedules (lock date + time for a whole course)
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-10.
--
-- A SCHEDULE is: a course/batch + teacher + the students in it + weekdays + time
-- + number of sessions. Creating one generates every class (so attendance,
-- recordings and assignments line up) and the Google script puts ONE repeating
-- event on the Calendar with ONE Meet link, inviting teacher + parents once.
-- =====================================================================

create table if not exists public.schedules (
  id                uuid primary key default gen_random_uuid(),
  title             text not null,
  course_name       text,
  teacher_id        uuid references public.teachers(id) on delete set null,
  kind              text not null default 'batch' check (kind in ('batch','one_to_one')),
  start_date        date not null,
  weekdays          int[] not null,                    -- ISO: 1=Mon ... 7=Sun
  class_time        text not null,                     -- e.g. 5:00 PM
  duration_min      int not null default 45 check (duration_min between 10 and 240),
  total_sessions    int not null check (total_sessions between 1 and 200),
  skip_dates        date[] not null default '{}',
  orig_dates        date[] not null default '{}',      -- the dates the course was first locked to
  status            text not null default 'active' check (status in ('active','completed','cancelled')),
  meet_link         text,
  calendar_event_id text,
  notes             text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
drop trigger if exists schedules_updated on public.schedules;
create trigger schedules_updated before update on public.schedules
  for each row execute function public.set_updated_at();

create table if not exists public.schedule_students (
  schedule_id uuid not null references public.schedules(id) on delete cascade,
  student_id  uuid not null references public.students(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (schedule_id, student_id)
);
create index if not exists schedule_students_student_idx on public.schedule_students (student_id);

alter table public.classes add column if not exists schedule_id uuid references public.schedules(id) on delete set null;
alter table public.classes add column if not exists session_no int;
create index if not exists classes_schedule_idx on public.classes (schedule_id);

alter table public.schedules enable row level security;
alter table public.schedule_students enable row level security;

drop policy if exists schedules_admin on public.schedules;
create policy schedules_admin on public.schedules for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
-- helper checks run as the system so the two tables' policies do not loop into each other
create or replace function public._sched_is_mine(p_schedule uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.schedules s join public.teachers t on t.id = s.teacher_id
                  where s.id = p_schedule and t.profile_id = (select auth.uid()))
$$;
create or replace function public._sched_has_my_child(p_schedule uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.schedule_students ss join public.students st on st.id = ss.student_id
                  where ss.schedule_id = p_schedule
                    and (st.parent_id = (select auth.uid()) or st.profile_id = (select auth.uid())
                         or lower(trim(coalesce(st.parent_email,''))) = (select lower(p.email) from public.profiles p where p.id = (select auth.uid()))))
$$;
revoke all on function public._sched_is_mine(uuid) from public, anon;
revoke all on function public._sched_has_my_child(uuid) from public, anon;
grant execute on function public._sched_is_mine(uuid) to authenticated;
grant execute on function public._sched_has_my_child(uuid) to authenticated;

drop policy if exists schedules_teacher on public.schedules;
create policy schedules_teacher on public.schedules for select to authenticated
  using (public.my_role() = 'teacher' and public._sched_is_mine(id));
drop policy if exists schedules_family on public.schedules;
create policy schedules_family on public.schedules for select to authenticated
  using (public.my_role() in ('parent','student') and public._sched_has_my_child(id));

drop policy if exists schedule_students_admin on public.schedule_students;
create policy schedule_students_admin on public.schedule_students for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists schedule_students_teacher on public.schedule_students;
create policy schedule_students_teacher on public.schedule_students for select to authenticated
  using (public.my_role() = 'teacher' and public._sched_is_mine(schedule_id));
drop policy if exists schedule_students_family on public.schedule_students;
create policy schedule_students_family on public.schedule_students for select to authenticated
  using (public.my_role() in ('parent','student') and public._sched_has_my_child(schedule_id));

-- ---------- generate classes for a schedule ---------------------------
create or replace function public._schedule_generate(p_id uuid, p_count int, p_from date) returns date[]
language plpgsql security definer set search_path = '' as $$
declare s public.schedules; d date; n int := 0; made date[] := '{}'; base int;
begin
  select * into s from public.schedules where id = p_id;
  select coalesce(max(session_no),0) into base from public.classes where schedule_id = p_id;
  d := p_from;
  while n < p_count and d < p_from + 1500 loop
    if extract(isodow from d)::int = any(s.weekdays) and not (d = any(s.skip_dates)) then
      n := n + 1; made := made || d;
      insert into public.classes (title, course_name, teacher_id, kind, class_date, class_time, duration_min,
                                  status, schedule_id, session_no, meet_link, notes)
      values (s.title || ' – Session ' || (base + n), s.course_name, s.teacher_id, s.kind, d, s.class_time, s.duration_min,
              'scheduled', p_id, base + n, s.meet_link, s.notes);
    end if;
    d := d + 1;
  end loop;
  return made;
end $$;
revoke all on function public._schedule_generate(uuid,int,date) from public, anon, authenticated;

create or replace function public.create_schedule(
  p_title text, p_course text, p_teacher uuid, p_kind text, p_start date, p_weekdays int[],
  p_time text, p_duration int, p_total int, p_skip date[], p_students uuid[], p_notes text
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare sid uuid; made date[];
begin
  if not public.is_admin() then raise exception 'Only the admin can create schedules'; end if;
  if coalesce(array_length(p_weekdays,1),0) = 0 then raise exception 'Choose at least one weekday'; end if;
  if nullif(trim(coalesce(p_time,'')),'') is null then raise exception 'Choose a class time'; end if;
  insert into public.schedules (title, course_name, teacher_id, kind, start_date, weekdays, class_time, duration_min,
                                total_sessions, skip_dates, notes)
  values (trim(p_title), nullif(p_course,''), p_teacher, coalesce(p_kind,'batch'), p_start, p_weekdays, trim(p_time),
          coalesce(p_duration,45), p_total, coalesce(p_skip,'{}'), nullif(p_notes,''))
  returning id into sid;
  made := public._schedule_generate(sid, p_total, p_start);
  update public.schedules set orig_dates = made where id = sid;
  insert into public.schedule_students (schedule_id, student_id)
    select sid, x from unnest(coalesce(p_students,'{}')) x on conflict do nothing;
  return sid;
end $$;
revoke all on function public.create_schedule(text,text,uuid,text,date,int[],text,int,int,date[],uuid[],text) from public, anon;
grant execute on function public.create_schedule(text,text,uuid,text,date,int[],text,int,int,date[],uuid[],text) to authenticated;

-- add more sessions after the last one
create or replace function public.schedule_extend(p_id uuid, p_more int) returns int
language plpgsql security definer set search_path = '' as $$
declare s public.schedules; last date; made date[];
begin
  if not public.is_admin() then raise exception 'Only the admin can change schedules'; end if;
  select * into s from public.schedules where id = p_id;
  if not found then raise exception 'Schedule not found'; end if;
  select max(class_date) into last from public.classes where schedule_id = p_id;
  made := public._schedule_generate(p_id, p_more, coalesce(last, s.start_date) + 1);
  update public.schedules set total_sessions = total_sessions + coalesce(array_length(made,1),0),
         orig_dates = orig_dates || made, status = 'active' where id = p_id;
  return coalesce(array_length(made,1),0);
end $$;
revoke all on function public.schedule_extend(uuid,int) from public, anon;
grant execute on function public.schedule_extend(uuid,int) to authenticated;

-- change time / length / teacher for every session still to come
create or replace function public.schedule_change_future(p_id uuid, p_time text, p_duration int, p_teacher uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.is_admin() then raise exception 'Only the admin can change schedules'; end if;
  update public.schedules set class_time = coalesce(nullif(trim(p_time),''), class_time),
         duration_min = coalesce(p_duration, duration_min), teacher_id = p_teacher where id = p_id;
  update public.classes c set class_time = s.class_time, duration_min = s.duration_min, teacher_id = s.teacher_id,
         teacher_name = (select full_name from public.teachers where id = s.teacher_id)
    from public.schedules s
   where c.schedule_id = p_id and s.id = p_id and c.status = 'scheduled' and c.class_date >= current_date;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.schedule_change_future(uuid,text,int,uuid) from public, anon;
grant execute on function public.schedule_change_future(uuid,text,int,uuid) to authenticated;

-- stop a schedule: cancels every session still to come (past ones stay in the records)
create or replace function public.schedule_cancel(p_id uuid) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.is_admin() then raise exception 'Only the admin can change schedules'; end if;
  update public.schedules set status = 'cancelled' where id = p_id;
  update public.classes set status = 'cancelled' where schedule_id = p_id and status = 'scheduled' and class_date >= current_date;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.schedule_cancel(uuid) from public, anon;
grant execute on function public.schedule_cancel(uuid) to authenticated;

-- ---------- for the Google sheet script (sync password only) ----------
create or replace function public.sheet_schedule_pull(p_secret text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_sync_secret(p_secret);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', s.id, 'title', s.title, 'status', s.status, 'weekdays', to_jsonb(s.weekdays),
      'class_time', s.class_time, 'duration_min', s.duration_min, 'orig_dates', to_jsonb(s.orig_dates),
      'calendar_event_id', s.calendar_event_id, 'meet_link', s.meet_link,
      'emails', to_jsonb(array(
         select distinct e from (
           select nullif(trim(t.email),'') e from public.teachers t where t.id = s.teacher_id
           union all select nullif(trim(st.parent_email),'') from public.schedule_students ss join public.students st on st.id = ss.student_id where ss.schedule_id = s.id
           union all select nullif(trim(g.email),'') from public.schedule_students ss join public.guardian_contacts g on g.student_id = ss.student_id where ss.schedule_id = s.id
         ) x where e is not null)),
      'classes', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'session_no', c.session_no,
                   'class_date', c.class_date, 'class_time', c.class_time, 'duration_min', c.duration_min, 'status', c.status)
                   order by c.session_no) from public.classes c where c.schedule_id = s.id), '[]'::jsonb)))
    from public.schedules s
    where s.status = 'active' or (s.status = 'cancelled' and s.calendar_event_id is not null)), '[]'::jsonb);
end $$;
revoke all on function public.sheet_schedule_pull(text) from public;
grant execute on function public.sheet_schedule_pull(text) to anon, authenticated;

create or replace function public.sheet_schedule_save(p_secret text, p_id uuid, p_event text, p_meet text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_sync_secret(p_secret);
  update public.schedules set calendar_event_id = nullif(p_event,''), meet_link = coalesce(nullif(p_meet,''), meet_link) where id = p_id;
  if nullif(p_meet,'') is not null then
    update public.classes set meet_link = p_meet where schedule_id = p_id and status = 'scheduled';
  end if;
end $$;
revoke all on function public.sheet_schedule_save(text,uuid,text,text) from public;
grant execute on function public.sheet_schedule_save(text,uuid,text,text) to anon, authenticated;

-- classes that belong to a schedule are handled by the repeating event, not one by one
create or replace function public.sheet_class_nocal(p_secret text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform private.check_sync_secret(p_secret);
  return coalesce((select jsonb_agg(id) from public.classes where schedule_id is not null), '[]'::jsonb);
end $$;
revoke all on function public.sheet_class_nocal(text) from public;
grant execute on function public.sheet_class_nocal(text) to anon, authenticated;

-- a teacher can see the children in the schedules they teach (needed for attendance)
create or replace function public._student_in_my_schedule(p_student uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.schedule_students ss
                  join public.schedules s on s.id = ss.schedule_id
                  join public.teachers t on t.id = s.teacher_id
                 where ss.student_id = p_student and t.profile_id = (select auth.uid()))
$$;
revoke all on function public._student_in_my_schedule(uuid) from public, anon;
grant execute on function public._student_in_my_schedule(uuid) to authenticated;
drop policy if exists students_teacher_schedule on public.students;
create policy students_teacher_schedule on public.students for select to authenticated
  using (public.my_role() = 'teacher' and public._student_in_my_schedule(id));

-- families see every class of a course their child is in
drop policy if exists classes_family_schedule on public.classes;
create policy classes_family_schedule on public.classes for select to authenticated
  using (schedule_id is not null and public.my_role() in ('parent','student') and public._sched_has_my_child(schedule_id));
