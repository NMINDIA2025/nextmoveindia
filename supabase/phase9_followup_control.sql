-- =====================================================================
-- Next Move India LMS | Phase 9 | Follow-up call log + control panel support
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-8.
--
-- * Every call / WhatsApp / note on a lead is recorded (who, when, outcome,
--   note, next follow-up) and shown as a timeline on the lead.
-- * Logging a call updates the lead's "last contact" and next follow-up date,
--   so the admin dashboard can show leads nobody has touched for 3+ days.
-- =====================================================================

alter table public.leads add column if not exists last_contact_at timestamptz;

create table if not exists public.lead_activities (
  id             uuid primary key default gen_random_uuid(),
  lead_id        uuid not null references public.leads(id) on delete cascade,
  actor_id       uuid references public.profiles(id) on delete set null,
  actor_name     text,
  kind           text not null default 'call' check (kind in ('call','whatsapp','note')),
  outcome        text check (outcome in ('spoke_interested','spoke_callback','no_answer','wrong_number','not_interested','sent_message','note')),
  note           text,
  next_follow_up date,
  created_at     timestamptz not null default now()
);
create index if not exists lead_activities_lead_idx on public.lead_activities (lead_id, created_at desc);
alter table public.lead_activities enable row level security;

-- same visibility as the lead itself (admin: all; counselor/teacher: assigned only)
drop policy if exists lead_activities_select on public.lead_activities;
create policy lead_activities_select on public.lead_activities for select to authenticated
  using (exists (select 1 from public.leads l where l.id = lead_id));
drop policy if exists lead_activities_insert on public.lead_activities;
create policy lead_activities_insert on public.lead_activities for insert to authenticated
  with check (actor_id = (select auth.uid()) and exists (select 1 from public.leads l where l.id = lead_id));
drop policy if exists lead_activities_admin_delete on public.lead_activities;
create policy lead_activities_admin_delete on public.lead_activities for delete to authenticated
  using (public.is_admin());

-- fill actor name, then update the lead
create or replace function public.lead_activity_after() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.leads
     set last_contact_at = new.created_at,
         next_follow_up  = coalesce(new.next_follow_up, next_follow_up),
         status = case when status = 'new' and new.kind in ('call','whatsapp') then 'contacted' else status end
   where id = new.lead_id;
  return null;
end $$;
create or replace function public.lead_activity_before() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.actor_name is null then
    select coalesce(nullif(full_name,''), email) into new.actor_name from public.profiles where id = new.actor_id;
  end if;
  return new;
end $$;
revoke all on function public.lead_activity_after() from public, anon, authenticated;
revoke all on function public.lead_activity_before() from public, anon, authenticated;
drop trigger if exists lead_activity_before on public.lead_activities;
create trigger lead_activity_before before insert on public.lead_activities
  for each row execute function public.lead_activity_before();
drop trigger if exists lead_activity_after on public.lead_activities;
create trigger lead_activity_after after insert on public.lead_activities
  for each row execute function public.lead_activity_after();
