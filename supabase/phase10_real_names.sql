-- =====================================================================
-- Next Move India LMS | Phase 10 | Show registered names, not email prefixes
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-9.
--
-- When someone signs up, their profile name is only the start of their email
-- (e.g. "maniumani1"). This looks up the name you registered them with:
--   teachers  -> the name in the Teachers list
--   parents   -> the parent name on the child's record / original lead
-- and keeps it up to date. It never overwrites a name a person typed.
-- =====================================================================

create or replace function public.registered_name(p_email text) returns text
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select nullif(trim(t.full_name),'') from public.teachers t where lower(trim(t.email)) = lower(trim(p_email)) limit 1),
    (select nullif(trim(g.parent_name),'') from public.guardian_contacts g
       join public.students s on s.id = g.student_id
       where lower(trim(s.parent_email)) = lower(trim(p_email)) and nullif(trim(g.parent_name),'') is not null limit 1),
    (select nullif(trim(g.parent_name),'') from public.guardian_contacts g
       where lower(trim(g.email)) = lower(trim(p_email)) and nullif(trim(g.parent_name),'') is not null limit 1),
    (select nullif(trim(l.parent_name),'') from public.leads l
       where lower(trim(l.email)) = lower(trim(p_email)) and nullif(trim(l.parent_name),'') is not null limit 1)
  )
$$;
revoke all on function public.registered_name(text) from public, anon, authenticated;

-- a name that is just the start of the email counts as "not set yet"
create or replace function public.name_is_placeholder(p_name text, p_email text) returns boolean
language sql immutable as $$
  select nullif(trim(coalesce(p_name,'')),'') is null
      or lower(trim(p_name)) = lower(split_part(coalesce(p_email,''),'@',1))
$$;

-- profile: fill the name when created or when the email changes
create or replace function public.profiles_real_name() returns trigger
language plpgsql security definer set search_path = '' as $$
declare nm text;
begin
  if public.name_is_placeholder(new.full_name, new.email) then
    nm := public.registered_name(new.email);
    if nm is not null then new.full_name := nm; end if;
  end if;
  return new;
end $$;
revoke all on function public.profiles_real_name() from public, anon, authenticated;
drop trigger if exists profiles_real_name on public.profiles;
create trigger profiles_real_name before insert or update of email, full_name on public.profiles
  for each row execute function public.profiles_real_name();

-- when a teacher / child record is added or its name / email changes, refresh the login's name
create or replace function public.refresh_profile_name() returns trigger
language plpgsql security definer set search_path = '' as $$
declare em text;
begin
  if tg_table_name = 'teachers' then em := new.email;
  elsif tg_table_name = 'students' then em := new.parent_email;
  elsif tg_table_name = 'guardian_contacts' then
    select s.parent_email into em from public.students s where s.id = new.student_id;
    update public.profiles p set full_name = public.registered_name(p.email)
      where lower(p.email) = lower(trim(coalesce(new.email,''))) and public.name_is_placeholder(p.full_name, p.email)
        and public.registered_name(p.email) is not null;
  end if;
  if nullif(trim(coalesce(em,'')),'') is not null then
    update public.profiles p set full_name = public.registered_name(p.email)
      where lower(p.email) = lower(trim(em)) and public.name_is_placeholder(p.full_name, p.email)
        and public.registered_name(p.email) is not null;
  end if;
  return null;
end $$;
revoke all on function public.refresh_profile_name() from public, anon, authenticated;
drop trigger if exists teachers_refresh_name on public.teachers;
create trigger teachers_refresh_name after insert or update of full_name, email on public.teachers
  for each row execute function public.refresh_profile_name();
drop trigger if exists students_refresh_name on public.students;
create trigger students_refresh_name after insert or update of parent_email on public.students
  for each row execute function public.refresh_profile_name();
drop trigger if exists guardian_refresh_name on public.guardian_contacts;
create trigger guardian_refresh_name after insert or update of parent_name, email on public.guardian_contacts
  for each row execute function public.refresh_profile_name();

-- fix everyone who already signed up
update public.profiles p set full_name = public.registered_name(p.email)
 where public.name_is_placeholder(p.full_name, p.email) and public.registered_name(p.email) is not null;
