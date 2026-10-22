-- =====================================================================
-- Next Move India LMS  |  Phase 3  |  Workspace + two-way sheet sync
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to re-run. Requires phase1 and phase2 to have been run first.
--
-- Adds: Classes, Attendance, Teaching Materials, Tasks, and one guarded
-- sync engine so Students, Teachers, Classes, Attendance, Materials,
-- Tasks and Payments can all be edited either in the LMS or in your
-- Google Sheet (the sheet script handles the sheet side).
-- =====================================================================
begin;

-- ---------- 0. updated_at on tables that did not have it -------------
alter table public.teachers add column if not exists updated_at timestamptz not null default now();
alter table public.payments add column if not exists updated_at timestamptz not null default now();
alter table public.payments add column if not exists student_name text;

drop trigger if exists teachers_updated on public.teachers;
create trigger teachers_updated before update on public.teachers
  for each row execute function public.set_updated_at();
drop trigger if exists payments_updated on public.payments;
create trigger payments_updated before update on public.payments
  for each row execute function public.set_updated_at();

create or replace function public.payments_fill_name() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  select s.full_name into new.student_name from public.students s where s.id = new.student_id;
  return new;
end $$;
drop trigger if exists payments_fill_name_trg on public.payments;
create trigger payments_fill_name_trg before insert or update of student_id on public.payments
  for each row execute function public.payments_fill_name();
update public.payments p set student_name = s.full_name from public.students s
  where s.id = p.student_id and p.student_name is null;

-- ---------- 1. Tasks --------------------------------------------------
create table if not exists public.tasks (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  description   text,
  priority      text not null default 'normal' check (priority in ('low','normal','high')),
  status        text not null default 'todo'   check (status in ('todo','doing','done')),
  due_date      date,
  assignee_id   uuid references public.profiles(id) on delete set null,
  assignee_name text,
  lead_id       uuid references public.leads(id) on delete set null,
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists tasks_assignee_idx on public.tasks (assignee_id);
create index if not exists tasks_status_idx   on public.tasks (status, due_date);
drop trigger if exists tasks_updated on public.tasks;
create trigger tasks_updated before update on public.tasks
  for each row execute function public.set_updated_at();

create or replace function public.tasks_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, (select auth.uid())); end if;
  if new.assignee_id is not null and (tg_op = 'INSERT' or new.assignee_id is distinct from old.assignee_id)
     and (new.assignee_name is null or tg_op = 'UPDATE' and new.assignee_name is not distinct from old.assignee_name) then
    select coalesce(p.full_name, p.email) into new.assignee_name from public.profiles p where p.id = new.assignee_id;
  end if;
  return new;
end $$;
drop trigger if exists tasks_fill_trg on public.tasks;
create trigger tasks_fill_trg before insert or update on public.tasks
  for each row execute function public.tasks_fill();

-- ---------- 2. Teaching materials (links to Google Drive etc.) -------
create table if not exists public.materials (
  id          uuid primary key default gen_random_uuid(),
  title       text not null,
  course_name text,
  kind        text not null default 'link'
              check (kind in ('video','pdf','worksheet','slides','quiz','game','link')),
  url         text,
  age_group   text,
  language    text default 'English',
  description text,
  published   boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists materials_course_idx on public.materials (course_name);
drop trigger if exists materials_updated on public.materials;
create trigger materials_updated before update on public.materials
  for each row execute function public.set_updated_at();

-- ---------- 3. Classes (batches, demos, workshops) -------------------
create table if not exists public.classes (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  course_name  text,
  teacher_id   uuid references public.teachers(id) on delete set null,
  teacher_name text,
  kind         text not null default 'batch' check (kind in ('batch','demo','one_to_one','workshop')),
  class_date   date,
  class_time   text,
  duration_min int not null default 45,
  meet_link    text,
  status       text not null default 'scheduled' check (status in ('scheduled','completed','cancelled')),
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists classes_date_idx    on public.classes (class_date);
create index if not exists classes_teacher_idx on public.classes (teacher_id);
drop trigger if exists classes_updated on public.classes;
create trigger classes_updated before update on public.classes
  for each row execute function public.set_updated_at();

-- teacher can be chosen by id (in the LMS) or typed by name (in the sheet)
create or replace function public.classes_fill_teacher() returns trigger
language plpgsql security definer set search_path = '' as $$
declare tid uuid; tname text;
begin
  if tg_op = 'INSERT' or new.teacher_name is distinct from old.teacher_name then
    if nullif(trim(new.teacher_name),'') is not null then
      select id into tid from public.teachers where lower(full_name) = lower(trim(new.teacher_name)) limit 1;
      if tid is not null then new.teacher_id := tid; end if;
    elsif tg_op = 'UPDATE' then
      new.teacher_id := null;
    end if;
  end if;
  if new.teacher_id is not null and (tg_op = 'INSERT' or new.teacher_id is distinct from old.teacher_id)
     and (new.teacher_name is null or tg_op = 'UPDATE' and new.teacher_name is not distinct from old.teacher_name) then
    select full_name into tname from public.teachers where id = new.teacher_id;
    new.teacher_name := tname;
  end if;
  return new;
end $$;
drop trigger if exists classes_fill_teacher_trg on public.classes;
create trigger classes_fill_teacher_trg before insert or update on public.classes
  for each row execute function public.classes_fill_teacher();

-- ---------- 4. Attendance --------------------------------------------
create table if not exists public.attendance (
  id            uuid primary key default gen_random_uuid(),
  class_id      uuid not null references public.classes(id) on delete cascade,
  student_id    uuid not null references public.students(id) on delete cascade,
  status        text not null default 'present' check (status in ('present','absent','late','excused')),
  note          text,
  class_title   text,
  class_date    date,
  student_name  text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (class_id, student_id)
);
create index if not exists attendance_student_idx on public.attendance (student_id);
drop trigger if exists attendance_updated on public.attendance;
create trigger attendance_updated before update on public.attendance
  for each row execute function public.set_updated_at();

create or replace function public.attendance_fill() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  select c.title, c.class_date into new.class_title, new.class_date from public.classes c where c.id = new.class_id;
  select s.full_name into new.student_name from public.students s where s.id = new.student_id;
  return new;
end $$;
drop trigger if exists attendance_fill_trg on public.attendance;
create trigger attendance_fill_trg before insert or update of class_id, student_id on public.attendance
  for each row execute function public.attendance_fill();

-- sessions_completed on the student follows attendance automatically
create or replace function public.attendance_recount() returns trigger
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  for sid in select distinct x from unnest(array[
      case when tg_op <> 'DELETE' then new.student_id end,
      case when tg_op <> 'INSERT' then old.student_id end]) x where x is not null loop
    update public.students s set sessions_completed =
      (select count(*) from public.attendance a where a.student_id = sid and a.status in ('present','late'))
      where s.id = sid;
  end loop;
  return null;
end $$;
drop trigger if exists attendance_recount_trg on public.attendance;
create trigger attendance_recount_trg after insert or update or delete on public.attendance
  for each row execute function public.attendance_recount();

-- ---------- 5. Security rules ----------------------------------------
alter table public.tasks      enable row level security;
alter table public.materials  enable row level security;
alter table public.classes    enable row level security;
alter table public.attendance enable row level security;

-- tasks: admin everything; staff see tasks assigned to or created by them
drop policy if exists tasks_admin on public.tasks;
create policy tasks_admin on public.tasks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists tasks_staff on public.tasks;
create policy tasks_staff on public.tasks for all to authenticated
  using (public.my_role() in ('counselor','teacher')
         and (assignee_id = (select auth.uid()) or created_by = (select auth.uid())))
  with check (public.my_role() in ('counselor','teacher')
         and (assignee_id = (select auth.uid()) or created_by = (select auth.uid())));

-- materials: admin manages; staff read all; families read their own courses
drop policy if exists materials_admin on public.materials;
create policy materials_admin on public.materials for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists materials_read on public.materials;
create policy materials_read on public.materials for select to authenticated
  using (published and (
    public.my_role() in ('counselor','teacher')
    or course_name is null
    or course_name in (select s.course_name from public.students s
                       where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid()))));

-- classes
drop policy if exists classes_admin on public.classes;
create policy classes_admin on public.classes for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists classes_counselor_read on public.classes;
create policy classes_counselor_read on public.classes for select to authenticated
  using (public.my_role() = 'counselor');
drop policy if exists classes_teacher on public.classes;
create policy classes_teacher on public.classes for all to authenticated
  using (teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid())))
  with check (teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid())));
drop policy if exists classes_family_read on public.classes;
create policy classes_family_read on public.classes for select to authenticated
  using (kind in ('batch','workshop') and course_name in (
    select s.course_name from public.students s
    where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())));

-- attendance
drop policy if exists attendance_admin on public.attendance;
create policy attendance_admin on public.attendance for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists attendance_teacher on public.attendance;
create policy attendance_teacher on public.attendance for all to authenticated
  using (class_id in (select c.id from public.classes c
         where c.teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid()))))
  with check (class_id in (select c.id from public.classes c
         where c.teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid()))));
drop policy if exists attendance_family_read on public.attendance;
create policy attendance_family_read on public.attendance for select to authenticated
  using (student_id in (select s.id from public.students s
         where s.parent_id = (select auth.uid()) or s.profile_id = (select auth.uid())));

-- counselors may read teachers (to show who takes a demo)
drop policy if exists teachers_counselor_read on public.teachers;
create policy teachers_counselor_read on public.teachers for select to authenticated
  using (public.my_role() = 'counselor');

revoke all on function public.payments_fill_name()     from public, anon, authenticated;
revoke all on function public.tasks_fill()             from public, anon, authenticated;
revoke all on function public.classes_fill_teacher()   from public, anon, authenticated;
revoke all on function public.attendance_fill()        from public, anon, authenticated;
revoke all on function public.attendance_recount()     from public, anon, authenticated;

-- ---------- 6. Sheet sync engine (any listed table, both directions) --
-- Which columns the sheet may change, per table. Anything not listed
-- (ids, timestamps, parent contact details...) can never be written.
create or replace function private.sync_spec(p_table text, out cols text[], out can_insert boolean)
language plpgsql immutable set search_path = '' as $$
begin
  case p_table
    when 'students'   then cols := array['full_name','age','course_name','batch_timings','sessions_completed','total_sessions','progress_notes','status','joined_at']; can_insert := true;
    when 'teachers'   then cols := array['full_name','email','phone','subject','status']; can_insert := true;
    when 'tasks'      then cols := array['title','description','priority','status','due_date','assignee_name']; can_insert := true;
    when 'materials'  then cols := array['title','course_name','kind','url','age_group','language','description','published','sort_order']; can_insert := true;
    when 'classes'    then cols := array['title','course_name','teacher_name','kind','class_date','class_time','duration_min','meet_link','status','notes']; can_insert := true;
    when 'payments'   then cols := array['course_name','package','amount','due_date','paid_date','status']; can_insert := false;
    when 'attendance' then cols := array['status','note']; can_insert := false;
    else cols := null; can_insert := false;
  end case;
end $$;

create or replace function public.sheet_table_pull(p_secret text, p_table text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare res jsonb; spec record;
begin
  perform private.check_sync_secret(p_secret);
  select * into spec from private.sync_spec(p_table);
  if spec.cols is null then raise exception 'Unknown table %', p_table; end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc), ''[]''::jsonb) from public.%I t', p_table) into res;
  return res;
end $$;

create or replace function public.sheet_table_push(p_secret text, p_table text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  spec record; r jsonb; sub jsonb; rid uuid; cur jsonb; base timestamptz; curts timestamptz;
  use_cols text[]; collist text; n int; i int := 0;
  inserted int := 0; updated int := 0; unchanged int := 0;
  conflicts jsonb := '[]'; rejected jsonb := '[]';
begin
  perform private.check_sync_secret(p_secret);
  select * into spec from private.sync_spec(p_table);
  if spec.cols is null then raise exception 'Unknown table %', p_table; end if;

  for r in select value from jsonb_array_elements(coalesce(p_rows,'[]'::jsonb)) loop
    i := i + 1;
    begin
      -- keep only allowed columns; blank cells become null
      select coalesce(jsonb_object_agg(k, case when jsonb_typeof(v) = 'string' and (v #>> '{}') = '' then 'null'::jsonb else v end), '{}'::jsonb),
             coalesce(array_agg(k), array[]::text[])
        into sub, use_cols
        from jsonb_each(r) as e(k, v) where k = any (spec.cols);
      collist := (select string_agg(format('%I', c), ',') from unnest(use_cols) c);
      rid := nullif(r ->> 'id', '')::uuid;

      if rid is null then
        if not spec.can_insert then
          rejected := rejected || jsonb_build_object('row', i, 'why', 'New rows cannot be added to this tab from the sheet');
          continue;
        end if;
        if collist is null then continue; end if;
        execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1)',
                       p_table, collist, collist, p_table) using sub;
        inserted := inserted + 1;
      else
        execute format('select to_jsonb(t) from public.%I t where t.id = $1', p_table) into cur using rid;
        if cur is null then
          rejected := rejected || jsonb_build_object('row', i, 'why', 'Row no longer exists in the LMS');
          continue;
        end if;
        base := nullif(r ->> 'base_updated_at', '')::timestamptz;
        curts := (cur ->> 'updated_at')::timestamptz;
        if base is not null and curts > base + interval '2 seconds' then
          conflicts := conflicts || jsonb_build_object('row', i, 'id', rid);
          continue;
        end if;
        if collist is null then unchanged := unchanged + 1; continue; end if;
        execute format(
          'update public.%1$I t set (%2$s) = (select %2$s from jsonb_populate_record(null::public.%1$I, $2) x) '
          'where t.id = $1 and (select row(%3$s)) is distinct from '
          '(select row(%4$s) from jsonb_populate_record(null::public.%1$I, $2) x)',
          p_table, collist,
          (select string_agg(format('t.%I', c), ',') from unnest(use_cols) c),
          (select string_agg(format('x.%I', c), ',') from unnest(use_cols) c))
          using rid, sub;
        get diagnostics n = row_count;
        if n > 0 then updated := updated + 1; else unchanged := unchanged + 1; end if;
      end if;
    exception when others then
      rejected := rejected || jsonb_build_object('row', i, 'why', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('inserted', inserted, 'updated', updated, 'unchanged', unchanged,
                            'conflicts', conflicts, 'rejected', rejected);
end $$;

revoke all on function public.sheet_table_pull(text, text)        from public;
revoke all on function public.sheet_table_push(text, text, jsonb) from public;
grant execute on function public.sheet_table_pull(text, text)        to anon, authenticated;
grant execute on function public.sheet_table_push(text, text, jsonb) to anon, authenticated;
revoke all on function private.sync_spec(text) from public, anon, authenticated;

commit;
