-- =====================================================================
-- Next Move India LMS | Phase 5 | Family login, recordings, assignments
-- Run once in Supabase SQL Editor ("Run and enable RLS" if asked).
-- Safe to re-run. Needs phases 1-4.
--
-- * A student record has a "parent email". When a parent creates an account
--   with that email, the account is linked to the child automatically.
-- * Classes get a recording link.
-- * Assignments (set by admin/teacher) + submissions (by the family).
-- =====================================================================

alter table public.students add column if not exists parent_email text;
alter table public.classes  add column if not exists recording_url text;

-- ---------- parent <-> child linking (by email) ----------------------
create or replace function public.link_parent() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'students' then
    if nullif(trim(new.parent_email),'') is not null
       and (tg_op = 'INSERT' or new.parent_id is null or new.parent_email is distinct from old.parent_email) then
      select p.id into new.parent_id from public.profiles p
        where lower(p.email) = lower(trim(new.parent_email)) limit 1;
    end if;
    if new.parent_id is not null then
      update public.profiles set role = 'parent' where id = new.parent_id and role = 'student';
    end if;
  else
    update public.students s set parent_id = new.id
      where s.parent_id is null and lower(trim(coalesce(s.parent_email,''))) = lower(coalesce(new.email,''));
    if new.role = 'student' and exists (select 1 from public.students s where s.parent_id = new.id) then
      update public.profiles set role = 'parent' where id = new.id and role = 'student';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists students_link_parent on public.students;
create trigger students_link_parent before insert or update of parent_email on public.students
  for each row execute function public.link_parent();
drop trigger if exists profiles_link_parent on public.profiles;
create trigger profiles_link_parent after insert or update of email on public.profiles
  for each row execute function public.link_parent();
revoke all on function public.link_parent() from public, anon, authenticated;

-- enrolling a lead copies the parent's email onto the student
create or replace function public.convert_lead_to_student(
  p_lead uuid, p_course uuid, p_teacher uuid default null,
  p_batch text default null, p_total_sessions int default null
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare l public.leads; c public.courses; sid uuid; age_txt text;
begin
  select * into l from public.leads where id = p_lead;
  if not found then raise exception 'Lead not found'; end if;
  if not (public.is_admin()
          or (public.my_role() = 'counselor' and l.assigned_to = (select auth.uid()))) then
    raise exception 'You are not allowed to enrol this lead';
  end if;
  if l.converted_student_id is not null then return l.converted_student_id; end if;
  select * into c from public.courses where id = p_course;
  age_txt := regexp_replace(coalesce(l.child_age,''), '\D', '', 'g');
  insert into public.students (full_name, age, course_id, course_name, teacher_id,
                               lead_id, batch_timings, total_sessions, parent_email)
  values (coalesce(nullif(l.child_name,''), 'Student'),
          case when age_txt ~ '^\d{1,2}$' then age_txt::int end,
          p_course, c.name, p_teacher, l.id, p_batch, p_total_sessions, nullif(trim(l.email),''))
  returning id into sid;
  insert into public.guardian_contacts (student_id, parent_name, phone, email)
  values (sid, l.parent_name, l.phone, l.email);
  update public.leads set status = 'enrolled', converted_student_id = sid where id = p_lead;
  return sid;
end $$;
revoke all on function public.convert_lead_to_student(uuid,uuid,uuid,text,int) from public, anon;
grant execute on function public.convert_lead_to_student(uuid,uuid,uuid,text,int) to authenticated;

-- link anything that already matches
update public.students s set parent_id = p.id from public.profiles p
  where s.parent_id is null and lower(trim(coalesce(s.parent_email,''))) = lower(coalesce(p.email,''));
update public.profiles p set role = 'parent'
  where p.role = 'student' and exists (select 1 from public.students s where s.parent_id = p.id);

-- ---------- assignments ----------------------------------------------
create table if not exists public.assignments (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  instructions text,
  course_name  text,
  due_date     date,
  answer_type  text not null default 'both' check (answer_type in ('link','text','both')),
  published    boolean not null default true,
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
drop trigger if exists assignments_updated on public.assignments;
create trigger assignments_updated before update on public.assignments
  for each row execute function public.set_updated_at();

create or replace function public.assignments_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, (select auth.uid())); end if;
  return new;
end $$;
drop trigger if exists assignments_fill_trg on public.assignments;
create trigger assignments_fill_trg before insert on public.assignments
  for each row execute function public.assignments_fill();

create table if not exists public.submissions (
  id               uuid primary key default gen_random_uuid(),
  assignment_id    uuid not null references public.assignments(id) on delete cascade,
  student_id       uuid not null references public.students(id) on delete cascade,
  answer_text      text,
  answer_link      text,
  status           text not null default 'submitted' check (status in ('submitted','reviewed')),
  feedback         text,
  grade            text,
  assignment_title text,
  student_name     text,
  submitted_at     timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (assignment_id, student_id)
);
create index if not exists submissions_student_idx on public.submissions (student_id);
drop trigger if exists submissions_updated on public.submissions;
create trigger submissions_updated before update on public.submissions
  for each row execute function public.set_updated_at();

create or replace function public.submissions_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  select a.title into new.assignment_title from public.assignments a where a.id = new.assignment_id;
  select s.full_name into new.student_name from public.students s where s.id = new.student_id;
  -- families can never write feedback / grade / "reviewed"
  if public.my_role() in ('parent','student') then
    if tg_op = 'INSERT' then
      new.feedback := null; new.grade := null; new.status := 'submitted';
    else
      new.feedback := old.feedback; new.grade := old.grade; new.status := 'submitted';
    end if;
  elsif tg_op = 'UPDATE' and (new.feedback is distinct from old.feedback or new.grade is distinct from old.grade)
        and new.status = 'submitted' then
    new.status := 'reviewed';
  end if;
  return new;
end $$;
drop trigger if exists submissions_fill_trg on public.submissions;
create trigger submissions_fill_trg before insert or update on public.submissions
  for each row execute function public.submissions_fill();
revoke all on function public.assignments_fill()  from public, anon, authenticated;
revoke all on function public.submissions_fill()  from public, anon, authenticated;

alter table public.assignments enable row level security;
alter table public.submissions enable row level security;

drop policy if exists assignments_admin on public.assignments;
create policy assignments_admin on public.assignments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists assignments_teacher on public.assignments;
create policy assignments_teacher on public.assignments for all to authenticated
  using (public.my_role() = 'teacher' and created_by = (select auth.uid()))
  with check (public.my_role() = 'teacher' and created_by = (select auth.uid()));
drop policy if exists assignments_teacher_read on public.assignments;
create policy assignments_teacher_read on public.assignments for select to authenticated
  using (public.my_role() = 'teacher');
drop policy if exists assignments_family on public.assignments;
create policy assignments_family on public.assignments for select to authenticated
  using (published and (course_name is null or course_name in (
    select s.course_name from public.students s
    where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid()))));

drop policy if exists submissions_admin on public.submissions;
create policy submissions_admin on public.submissions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists submissions_teacher on public.submissions;
create policy submissions_teacher on public.submissions for all to authenticated
  using (student_id in (select s.id from public.students s
         where s.teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid()))))
  with check (student_id in (select s.id from public.students s
         where s.teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid()))));
drop policy if exists submissions_family_read on public.submissions;
create policy submissions_family_read on public.submissions for select to authenticated
  using (student_id in (select s.id from public.students s
         where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())));
drop policy if exists submissions_family_write on public.submissions;
create policy submissions_family_write on public.submissions for insert to authenticated
  with check (public.my_role() in ('parent','student') and student_id in (select s.id from public.students s
         where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())));
drop policy if exists submissions_family_update on public.submissions;
create policy submissions_family_update on public.submissions for update to authenticated
  using (public.my_role() in ('parent','student') and student_id in (select s.id from public.students s
         where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())))
  with check (student_id in (select s.id from public.students s
         where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())));

-- ---------- sheet sync: new columns and tabs -------------------------
create or replace function private.sync_spec(p_table text, out cols text[], out can_insert boolean)
language plpgsql immutable set search_path = '' as $$
begin
  case p_table
    when 'students'    then cols := array['full_name','age','course_name','batch_timings','sessions_completed','total_sessions','progress_notes','status','joined_at','parent_email']; can_insert := true;
    when 'teachers'    then cols := array['full_name','email','phone','subject','status']; can_insert := true;
    when 'tasks'       then cols := array['title','description','priority','status','due_date','assignee_name']; can_insert := true;
    when 'materials'   then cols := array['title','course_name','kind','url','age_group','language','description','published','sort_order']; can_insert := true;
    when 'classes'     then cols := array['title','course_name','teacher_name','kind','class_date','class_time','duration_min','meet_link','recording_url','status','notes']; can_insert := true;
    when 'payments'    then cols := array['course_name','package','amount','due_date','paid_date','status']; can_insert := false;
    when 'attendance'  then cols := array['status','note']; can_insert := false;
    when 'assignments' then cols := array['title','instructions','course_name','due_date','answer_type','published']; can_insert := true;
    when 'submissions' then cols := array['feedback','grade']; can_insert := false;
    else cols := null; can_insert := false;
  end case;
end $$;
revoke all on function private.sync_spec(text) from public, anon, authenticated;
