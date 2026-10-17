-- =====================================================================
-- Next Move India LMS  |  Phase 1 foundation  |  Learn • Lead • Rise
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- Safe to re-run: it only creates what is missing.
-- Privacy by design: children's data is minimal (first name, age, course,
-- progress). Parent phone/email live in a separate, locked-down table.
-- =====================================================================
begin;

-- ---------- 1. Profiles (one row per login) -------------------------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  email       text,
  phone       text,
  role        text not null default 'student'
              check (role in ('admin','counselor','teacher','parent','student')),
  language    text not null default 'en' check (language in ('en','hi')),
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------- 2. Helper functions (used by the security rules) --------
create or replace function public.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = '' as $$
  select role from public.profiles where id = (select auth.uid()) and active
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.my_role() = 'admin', false)
$$;

-- A new sign-up ALWAYS starts as 'student'. Roles are never taken from the
-- sign-up form, so nobody can make themselves an admin.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email,
          coalesce(nullif(new.raw_user_meta_data->>'full_name',''), split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

drop trigger if exists profiles_updated on public.profiles;
create trigger profiles_updated before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------- 3. Courses ----------------------------------------------
create table if not exists public.courses (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,
  name        text not null,
  name_hi     text,
  description text,
  age_min     int,
  age_max     int,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

insert into public.courses (slug, name) values
  ('tiny-talkers-club',        'Tiny Talkers Club'),
  ('elite-anchors-club',       'Elite Anchors Club'),
  ('young-orators',            'Young Orators'),
  ('public-speaking-debating', 'Public Speaking & Debating'),
  ('creative-writing-storytelling', 'Creative Writing & Storytelling'),
  ('phonetics-reading',        'Phonetics & Reading')
on conflict (slug) do nothing;

-- ---------- 4. Teachers ---------------------------------------------
create table if not exists public.teachers (
  id          uuid primary key default gen_random_uuid(),
  profile_id  uuid unique references public.profiles(id) on delete set null,
  full_name   text not null,
  email       text,
  phone       text,
  subject     text,
  status      text not null default 'active' check (status in ('active','inactive')),
  created_at  timestamptz not null default now()
);

-- ---------- 5. Leads (website enquiries -> enrolment) ---------------
create table if not exists public.leads (
  id                   uuid primary key default gen_random_uuid(),
  parent_name          text,
  phone                text,
  email                text,
  child_name           text,
  child_age            text,           -- text on purpose: sheet has "7 Y", "5Y", "12"
  city                 text,
  interested_course    text,
  source               text not null default 'website',
  status               text not null default 'new' check (status in (
      'new','contacted','interested','call_back_later',
      'demo_scheduled','demo_rescheduled','demo_completed',
      'follow_up','enrolled','not_interested','not_reachable')),
  demo_date            text,
  demo_time            text,
  next_follow_up       date,
  assigned_to          uuid references public.profiles(id) on delete set null,
  lost_reason          text,
  notes                text,           -- private: admin + assigned counselor only
  converted_student_id uuid,
  phone_norm           text generated always as
                         (right(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 10)) stored,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists leads_assigned_idx on public.leads (assigned_to);
create index if not exists leads_status_idx   on public.leads (status);
create index if not exists leads_phone_idx    on public.leads (phone_norm);

drop trigger if exists leads_updated on public.leads;
create trigger leads_updated before update on public.leads
  for each row execute function public.set_updated_at();

-- ---------- 6. Lead history (who changed what, when) ----------------
create table if not exists public.lead_events (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.leads(id) on delete cascade,
  actor_id    uuid references public.profiles(id) on delete set null,
  from_status text,
  to_status   text,
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists lead_events_lead_idx on public.lead_events (lead_id, created_at desc);

create or replace function public.log_lead_status() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    insert into public.lead_events (lead_id, actor_id, from_status, to_status)
    values (new.id, (select auth.uid()), old.status, new.status);
  end if;
  return new;
end $$;

drop trigger if exists leads_log_status on public.leads;
create trigger leads_log_status after update on public.leads
  for each row execute function public.log_lead_status();

-- ---------- 7. Demo classes (free; group or one-to-one) -------------
create table if not exists public.demos (
  id                uuid primary key default gen_random_uuid(),
  lead_id           uuid not null references public.leads(id) on delete cascade,
  teacher_id        uuid references public.teachers(id) on delete set null,
  demo_type         text not null default 'group' check (demo_type in ('group','one_to_one')),
  scheduled_at      timestamptz,
  meet_link         text,
  status            text not null default 'scheduled' check (status in
                      ('pending','scheduled','completed','rescheduled','no_show','cancelled')),
  feedback          text,
  -- what the teacher is allowed to see (no parent contact details):
  child_first_name  text,
  child_age         text,
  interested_course text,
  created_by        uuid references public.profiles(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists demos_lead_idx    on public.demos (lead_id);
create index if not exists demos_teacher_idx on public.demos (teacher_id);

create or replace function public.demos_fill_from_lead() returns trigger
language plpgsql security definer set search_path = '' as $$
declare l public.leads;
begin
  select * into l from public.leads where id = new.lead_id;
  if found then
    new.child_first_name  := coalesce(new.child_first_name, split_part(coalesce(l.child_name,''), ' ', 1));
    new.child_age         := coalesce(new.child_age, l.child_age);
    new.interested_course := coalesce(new.interested_course, l.interested_course);
  end if;
  new.created_by := coalesce(new.created_by, (select auth.uid()));
  return new;
end $$;

drop trigger if exists demos_fill on public.demos;
create trigger demos_fill before insert on public.demos
  for each row execute function public.demos_fill_from_lead();
drop trigger if exists demos_updated on public.demos;
create trigger demos_updated before update on public.demos
  for each row execute function public.set_updated_at();

-- ---------- 8. Students (minimal child data) ------------------------
create sequence if not exists public.student_code_seq;

create table if not exists public.students (
  id                 uuid primary key default gen_random_uuid(),
  student_code       text unique not null default
                       ('NMI-' || extract(year from now())::int || '-' ||
                        lpad(nextval('public.student_code_seq')::text, 3, '0')),
  full_name          text not null,
  age                int,
  course_id          uuid references public.courses(id) on delete set null,
  course_name        text,
  teacher_id         uuid references public.teachers(id) on delete set null,
  parent_id          uuid references public.profiles(id) on delete set null,
  profile_id         uuid references public.profiles(id) on delete set null,  -- the child's own login (13+ only)
  lead_id            uuid references public.leads(id) on delete set null,
  batch_timings      text,
  sessions_completed int not null default 0,
  total_sessions     int,
  progress_percent   int generated always as (
                       case when coalesce(total_sessions,0) > 0
                            then least(100, round(100.0 * sessions_completed / total_sessions)::int)
                       end) stored,
  progress_notes     text,
  status             text not null default 'active'
                       check (status in ('active','on_hold','completed','discontinued')),
  joined_at          date not null default current_date,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists students_parent_idx  on public.students (parent_id);
create index if not exists students_teacher_idx on public.students (teacher_id);

drop trigger if exists students_updated on public.students;
create trigger students_updated before update on public.students
  for each row execute function public.set_updated_at();

-- Parent contact details, kept apart so teachers never see them.
create table if not exists public.guardian_contacts (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students(id) on delete cascade,
  parent_name text,
  phone       text,
  email       text,
  relation    text,
  created_at  timestamptz not null default now()
);

-- ---------- 9. Parental consent (DPDP-style record) -----------------
create table if not exists public.consents (
  id             uuid primary key default gen_random_uuid(),
  parent_id      uuid not null references public.profiles(id) on delete cascade,
  student_id     uuid references public.students(id) on delete cascade,
  consent_type   text not null check (consent_type in ('data_processing','recordings','communications')),
  policy_version text not null,
  granted_at     timestamptz not null default now(),
  withdrawn_at   timestamptz
);

-- A consent record can only ever be withdrawn, never rewritten.
create or replace function public.consents_lock() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.parent_id is distinct from old.parent_id
     or new.student_id is distinct from old.student_id
     or new.consent_type is distinct from old.consent_type
     or new.policy_version is distinct from old.policy_version
     or new.granted_at is distinct from old.granted_at then
    raise exception 'A consent record can only be withdrawn, not changed';
  end if;
  return new;
end $$;
drop trigger if exists consents_lock_trg on public.consents;
create trigger consents_lock_trg before update on public.consents
  for each row execute function public.consents_lock();

-- ---------- 10. Payments (recorded manually for now) ----------------
create table if not exists public.payments (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.students(id) on delete cascade,
  course_name text,
  package     text,
  amount      numeric(10,2),
  due_date    date,
  paid_date   date,
  status      text not null default 'pending' check (status in ('pending','paid','overdue','cancelled')),
  created_at  timestamptz not null default now()
);

-- ---------- 11. Lead -> student, in one safe step -------------------
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
                               lead_id, batch_timings, total_sessions)
  values (coalesce(nullif(l.child_name,''), 'Student'),
          case when age_txt ~ '^\d{1,2}$' then age_txt::int end,
          p_course, c.name, p_teacher, l.id, p_batch, p_total_sessions)
  returning id into sid;

  insert into public.guardian_contacts (student_id, parent_name, phone, email)
  values (sid, l.parent_name, l.phone, l.email);

  update public.leads set status = 'enrolled', converted_student_id = sid where id = p_lead;
  return sid;
end $$;

-- ---------- 12. Security rules (Row Level Security) -----------------
alter table public.profiles          enable row level security;
alter table public.courses           enable row level security;
alter table public.teachers          enable row level security;
alter table public.leads             enable row level security;
alter table public.lead_events       enable row level security;
alter table public.demos             enable row level security;
alter table public.students          enable row level security;
alter table public.guardian_contacts enable row level security;
alter table public.consents          enable row level security;
alter table public.payments          enable row level security;

-- profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or public.is_admin());
drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()) and role = public.my_role());   -- cannot change own role
drop policy if exists profiles_admin_all on public.profiles;
create policy profiles_admin_all on public.profiles for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- courses: everyone signed in can read; admin manages
drop policy if exists courses_read on public.courses;
create policy courses_read on public.courses for select to authenticated using (true);
drop policy if exists courses_admin on public.courses;
create policy courses_admin on public.courses for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- teachers
drop policy if exists teachers_admin on public.teachers;
create policy teachers_admin on public.teachers for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists teachers_self on public.teachers;
create policy teachers_self on public.teachers for select to authenticated
  using (profile_id = (select auth.uid()));

-- leads: admin sees all; a counselor sees only leads assigned to them
drop policy if exists leads_admin on public.leads;
create policy leads_admin on public.leads for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists leads_counselor_select on public.leads;
create policy leads_counselor_select on public.leads for select to authenticated
  using (public.my_role() = 'counselor' and assigned_to = (select auth.uid()));
drop policy if exists leads_counselor_update on public.leads;
create policy leads_counselor_update on public.leads for update to authenticated
  using (public.my_role() = 'counselor' and assigned_to = (select auth.uid()))
  with check (public.my_role() = 'counselor' and assigned_to = (select auth.uid()));
drop policy if exists leads_counselor_insert on public.leads;
create policy leads_counselor_insert on public.leads for insert to authenticated
  with check (public.my_role() = 'counselor' and assigned_to = (select auth.uid()));

-- lead history follows lead visibility
drop policy if exists lead_events_select on public.lead_events;
create policy lead_events_select on public.lead_events for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id));
drop policy if exists lead_events_insert on public.lead_events;
create policy lead_events_insert on public.lead_events for insert to authenticated
  with check (actor_id = (select auth.uid())
              and exists (select 1 from public.leads l where l.id = lead_id));

-- demos
drop policy if exists demos_admin on public.demos;
create policy demos_admin on public.demos for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists demos_counselor on public.demos;
create policy demos_counselor on public.demos for all to authenticated
  using (public.my_role() = 'counselor' and exists (select 1 from public.leads l where l.id = lead_id))
  with check (public.my_role() = 'counselor' and exists (select 1 from public.leads l where l.id = lead_id));
drop policy if exists demos_teacher_select on public.demos;
create policy demos_teacher_select on public.demos for select to authenticated
  using (teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid())));
drop policy if exists demos_teacher_update on public.demos;
create policy demos_teacher_update on public.demos for update to authenticated
  using (teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid())))
  with check (teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid())));

-- students
drop policy if exists students_admin on public.students;
create policy students_admin on public.students for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists students_parent on public.students;
create policy students_parent on public.students for select to authenticated
  using (parent_id = (select auth.uid()));
drop policy if exists students_self on public.students;
create policy students_self on public.students for select to authenticated
  using (profile_id = (select auth.uid()));
drop policy if exists students_teacher on public.students;
create policy students_teacher on public.students for select to authenticated
  using (teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid())));

-- guardian contacts: admin and the parent only (never teachers or the child)
drop policy if exists guardian_admin on public.guardian_contacts;
create policy guardian_admin on public.guardian_contacts for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists guardian_parent on public.guardian_contacts;
create policy guardian_parent on public.guardian_contacts for select to authenticated
  using (exists (select 1 from public.students s
                 where s.id = student_id and s.parent_id = (select auth.uid())));

-- consents
drop policy if exists consents_parent_select on public.consents;
create policy consents_parent_select on public.consents for select to authenticated
  using (parent_id = (select auth.uid()) or public.is_admin());
drop policy if exists consents_parent_insert on public.consents;
create policy consents_parent_insert on public.consents for insert to authenticated
  with check (parent_id = (select auth.uid()));
drop policy if exists consents_parent_withdraw on public.consents;
create policy consents_parent_withdraw on public.consents for update to authenticated
  using (parent_id = (select auth.uid())) with check (parent_id = (select auth.uid()));

-- payments
drop policy if exists payments_admin on public.payments;
create policy payments_admin on public.payments for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists payments_parent on public.payments;
create policy payments_parent on public.payments for select to authenticated
  using (exists (select 1 from public.students s
                 where s.id = student_id and s.parent_id = (select auth.uid())));

-- ---------- 13. Lock down who can call the functions ----------------
revoke all on function public.my_role()           from public, anon;
revoke all on function public.is_admin()          from public, anon;
revoke all on function public.handle_new_user()   from public, anon, authenticated;
revoke all on function public.log_lead_status()   from public, anon, authenticated;
revoke all on function public.demos_fill_from_lead() from public, anon, authenticated;
revoke all on function public.convert_lead_to_student(uuid,uuid,uuid,text,int) from public, anon;
grant execute on function public.my_role()  to authenticated;
grant execute on function public.is_admin() to authenticated;
grant execute on function public.convert_lead_to_student(uuid,uuid,uuid,text,int) to authenticated;

commit;

-- =====================================================================
-- AFTER you create your own login on the LMS page, run this ONE line
-- (separately) to make yourself the admin:
--
--   update public.profiles set role = 'admin' where email = 'info@nextmoveindia.org';
-- =====================================================================
