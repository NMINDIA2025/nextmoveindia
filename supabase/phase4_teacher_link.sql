-- Next Move India LMS | Phase 4 | Teacher accounts link automatically by email
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-3.
-- Rule: a teacher record and a login are linked when their emails match
-- (not case sensitive). Then the teacher sees only their own classes/students.

create or replace function public.link_teacher_profile() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'teachers' then
    if new.profile_id is null and nullif(trim(new.email),'') is not null then
      select p.id into new.profile_id from public.profiles p
        where lower(p.email) = lower(trim(new.email))
          and not exists (select 1 from public.teachers t where t.profile_id = p.id and t.id <> new.id)
        limit 1;
    end if;
    if new.profile_id is not null then
      update public.profiles set role = 'teacher' where id = new.profile_id and role = 'student';
    end if;
  else
    -- a login was created or changed: attach it to a teacher record with the same email
    update public.teachers t set profile_id = new.id
      where t.profile_id is null and lower(trim(coalesce(t.email,''))) = lower(coalesce(new.email,''));
    -- and make the login a teacher if it was linked and still a plain sign-up
    if new.role = 'student' and exists (select 1 from public.teachers t where t.profile_id = new.id) then
      update public.profiles set role = 'teacher' where id = new.id and role = 'student';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists teachers_link on public.teachers;
create trigger teachers_link before insert or update of email on public.teachers
  for each row execute function public.link_teacher_profile();
drop trigger if exists profiles_link_teacher on public.profiles;
create trigger profiles_link_teacher after insert or update of email on public.profiles
  for each row execute function public.link_teacher_profile();

revoke all on function public.link_teacher_profile() from public, anon, authenticated;

-- link anything that already matches
update public.teachers t set profile_id = p.id from public.profiles p
  where t.profile_id is null and lower(trim(coalesce(t.email,''))) = lower(coalesce(p.email,''))
    and not exists (select 1 from public.teachers x where x.profile_id = p.id);
update public.profiles p set role = 'teacher'
  where p.role = 'student' and exists (select 1 from public.teachers t where t.profile_id = p.id);
