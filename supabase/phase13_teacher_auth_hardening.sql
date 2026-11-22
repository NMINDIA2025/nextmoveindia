-- Next Move India LMS | Phase 13 | Teacher account identity hardening
-- Run after phases 1-12 in Supabase SQL Editor.
-- Protects teacher auto-linking from users changing their own profile email/role.
-- Safe to re-run.

begin;

-- A signed-in user may edit their own display/contact details, but their
-- identity email and role must be controlled through Auth/admin workflows.
create or replace function public.protect_profile_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.id is distinct from old.id then
    raise exception 'Profile identity cannot be changed.';
  end if;

  if auth.uid() = old.id and not coalesce(public.is_admin(), false) then
    if new.email is distinct from old.email then
      raise exception 'Email is managed by Supabase Auth. Use the account email-change flow.';
    end if;
    if new.role is distinct from old.role then
      raise exception 'Only an administrator can change account roles.';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_protect_identity on public.profiles;
create trigger profiles_protect_identity
before update on public.profiles
for each row execute function public.protect_profile_identity();

-- Keep the profile email synchronized when the verified Auth email changes.
-- This allows the existing teacher-link trigger to run from a trusted Auth
-- update rather than from an editable profile field.
create or replace function public.sync_profile_email_from_auth()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is distinct from old.email then
    update public.profiles
       set email = new.email
     where id = new.id
       and email is distinct from new.email;
  end if;
  return new;
end;
$$;

drop trigger if exists auth_user_email_to_profile on auth.users;
create trigger auth_user_email_to_profile
after update of email on auth.users
for each row execute function public.sync_profile_email_from_auth();

revoke all on function public.protect_profile_identity() from public, anon, authenticated;
revoke all on function public.sync_profile_email_from_auth() from public, anon, authenticated;

commit;
