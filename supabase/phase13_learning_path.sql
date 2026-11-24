-- =====================================================================
-- Phase 13: Learning path (demo kit vs day-wise course material),
--           day-wise challenges and video submissions
-- Safe to run more than once. Run in the Supabase SQL Editor.
-- =====================================================================

-- ---------- 1. Materials: demo kit vs course, and which day -----------
alter table public.materials add column if not exists purpose text not null default 'course';
alter table public.materials add column if not exists day_no  int;
alter table public.materials add column if not exists section text not null default 'learn';

alter table public.materials drop constraint if exists materials_purpose_check;
alter table public.materials add  constraint materials_purpose_check check (purpose in ('demo','course'));
alter table public.materials drop constraint if exists materials_section_check;
alter table public.materials add  constraint materials_section_check check (section in ('learn','activity','practice'));
alter table public.materials drop constraint if exists materials_day_check;
alter table public.materials add  constraint materials_day_check check (day_no is null or day_no between 1 and 365);

-- Families only ever see COURSE material for the course their child is enrolled in.
-- The demo kit is staff-only.
drop policy if exists materials_read on public.materials;
create policy materials_read on public.materials for select to authenticated
using (
  published and (
    public.my_role() in ('counselor','teacher')
    or (purpose = 'course' and (
          course_name is null
          or course_name in (select s.course_name from public.students s
                             where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid()))))
  )
);

drop policy if exists "materials read" on storage.objects;
create policy "materials read" on storage.objects for select to authenticated
using (
  bucket_id = 'materials' and (
    public.my_role() in ('admin','counselor','teacher')
    or exists (select 1 from public.materials m
               where m.file_path = storage.objects.name and m.published and m.purpose = 'course'))
);

-- ---------- 2. Course days (a title / goal for each day) ---------------
create table if not exists public.course_days (
  id          uuid primary key default gen_random_uuid(),
  course_name text not null,
  day_no      int  not null check (day_no between 1 and 365),
  title       text,
  goal        text,
  emoji       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (course_name, day_no)
);
alter table public.course_days enable row level security;

drop policy if exists course_days_admin on public.course_days;
create policy course_days_admin on public.course_days for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists course_days_staff_read on public.course_days;
create policy course_days_staff_read on public.course_days for select to authenticated
  using (public.my_role() in ('counselor','teacher'));
drop policy if exists course_days_family_read on public.course_days;
create policy course_days_family_read on public.course_days for select to authenticated
  using (course_name in (select s.course_name from public.students s
                         where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())));

drop trigger if exists course_days_updated on public.course_days;
create trigger course_days_updated before update on public.course_days
  for each row execute function public.set_updated_at();

-- ---------- 3. Students: which day is unlocked -------------------------
-- Blank = follows classes completed + 1. Admin / teacher can set it by hand.
alter table public.students add column if not exists current_day int;
alter table public.students drop constraint if exists students_current_day_check;
alter table public.students add  constraint students_current_day_check check (current_day is null or current_day between 1 and 365);

-- ---------- 4. Assignments: day-wise + video answer --------------------
alter table public.assignments add column if not exists day_no int;
alter table public.assignments drop constraint if exists assignments_day_check;
alter table public.assignments add  constraint assignments_day_check check (day_no is null or day_no between 1 and 365);
alter table public.assignments drop constraint if exists assignments_answer_type_check;
alter table public.assignments add  constraint assignments_answer_type_check
  check (answer_type in ('link','text','both','video'));

-- ---------- 5. Submissions: uploaded video + stars ---------------------
alter table public.submissions add column if not exists video_path text;
alter table public.submissions add column if not exists video_name text;
alter table public.submissions add column if not exists video_size bigint;
alter table public.submissions add column if not exists stars smallint;
alter table public.submissions drop constraint if exists submissions_stars_check;
alter table public.submissions add  constraint submissions_stars_check check (stars is null or stars between 1 and 5);

-- Families can never write feedback / grade / stars / "reviewed".
create or replace function public.submissions_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  select a.title into new.assignment_title from public.assignments a where a.id = new.assignment_id;
  select s.full_name into new.student_name from public.students s where s.id = new.student_id;
  if public.my_role() in ('parent','student') then
    if tg_op = 'INSERT' then
      new.feedback := null; new.grade := null; new.stars := null; new.status := 'submitted';
    else
      new.feedback := old.feedback; new.grade := old.grade; new.stars := old.stars; new.status := 'submitted';
    end if;
    new.submitted_at := now();
  elsif tg_op = 'UPDATE' and (new.feedback is distinct from old.feedback or new.grade is distinct from old.grade
                              or new.stars is distinct from old.stars) and new.status = 'submitted' then
    new.status := 'reviewed';
  end if;
  return new;
end $$;

-- ---------- 6. Private bucket for children's videos -------------------
-- Path rule:  <student_id>/<assignment_id>/<file>
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('submissions', 'submissions', false, 52428800,
        array['video/mp4','video/quicktime','video/webm','video/x-m4v','video/3gpp',
              'audio/mpeg','audio/mp4','audio/webm','audio/x-m4a','audio/wav','audio/aac','audio/ogg'])
on conflict (id) do update set public = false, file_size_limit = 52428800,
  allowed_mime_types = excluded.allowed_mime_types;

-- helper: is this storage folder (student id) one of "my" children?
create or replace function public.my_student_folder(folder text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.students s
                 where s.id::text = folder
                   and (s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())))
$$;
create or replace function public.my_pupil_folder(folder text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.students s
                 join public.teachers t on t.id = s.teacher_id
                 where s.id::text = folder and t.profile_id = (select auth.uid()))
$$;

drop policy if exists "submissions family upload" on storage.objects;
create policy "submissions family upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'submissions' and public.my_role() in ('parent','student')
              and public.my_student_folder((storage.foldername(name))[1]));
drop policy if exists "submissions read" on storage.objects;
create policy "submissions read" on storage.objects for select to authenticated
  using (bucket_id = 'submissions' and (
           public.is_admin()
        or public.my_student_folder((storage.foldername(name))[1])
        or public.my_pupil_folder((storage.foldername(name))[1])));
drop policy if exists "submissions family delete" on storage.objects;
create policy "submissions family delete" on storage.objects for delete to authenticated
  using (bucket_id = 'submissions' and (
           public.is_admin()
        or (public.my_role() in ('parent','student') and public.my_student_folder((storage.foldername(name))[1]))));

-- ---------- 7. Helpful indexes ----------------------------------------
create index if not exists materials_course_day_idx on public.materials (course_name, day_no);
create index if not exists assignments_course_day_idx on public.assignments (course_name, day_no);
create index if not exists submissions_student_idx on public.submissions (student_id);
