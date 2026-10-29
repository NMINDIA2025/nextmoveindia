-- =====================================================================
-- Next Move India LMS | Phase 12 | Demo Desk: teachers pick demos, call, confirm, conduct
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-11.
--
-- * Teachers see an anonymous "demo queue" (child first name, age, course, date).
--   NO parent phone / email is visible until a teacher picks a demo.
-- * A teacher who picks (or is given) a demo can see THAT lead only, call the
--   parent, confirm the time and record the demo result. Access ends 7 days
--   after the demo is done.
-- * A teacher can hold at most 5 open demos at a time (stops hoarding / scraping).
-- * Finishing a demo records feedback, moves the lead to "Demo completed" and
--   creates a fee follow-up task for the lead's owner.
-- =====================================================================

alter table public.classes add column if not exists parent_confirmed boolean not null default false;
alter table public.classes add column if not exists claimed_at timestamptz;

-- ---- allow trusted functions to change protected lead fields -----------
create or replace function public.leads_protect() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null and not public.is_admin()
     and coalesce(current_setting('nmi.bypass', true), '') <> '1' then
    new.assigned_to := old.assigned_to;
    new.source := old.source;
    new.sheet_key := old.sheet_key;
    new.converted_student_id := old.converted_student_id;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
revoke all on function public.leads_protect() from public, anon, authenticated;

-- ---- a teacher can see/update the lead of a demo they are teaching -----
create or replace function public._lead_in_my_demo(p_lead uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.classes c
      join public.teachers t on t.id = c.teacher_id
     where c.lead_id = p_lead and c.kind = 'demo' and t.profile_id = (select auth.uid())
       and (c.status = 'scheduled' or (c.status = 'completed' and c.updated_at > now() - interval '7 days')))
$$;
revoke all on function public._lead_in_my_demo(uuid) from public, anon;
grant execute on function public._lead_in_my_demo(uuid) to authenticated;

drop policy if exists leads_teacher_demo_select on public.leads;
create policy leads_teacher_demo_select on public.leads for select to authenticated
  using (public.my_role() = 'teacher' and public._lead_in_my_demo(id));
drop policy if exists leads_teacher_demo_update on public.leads;
create policy leads_teacher_demo_update on public.leads for update to authenticated
  using (public.my_role() = 'teacher' and public._lead_in_my_demo(id))
  with check (public.my_role() = 'teacher' and public._lead_in_my_demo(id));

-- ---- anonymous demo queue (no contact details) --------------------------
create or replace function public.demo_queue() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if public.my_role() not in ('admin','counselor','teacher') then raise exception 'Not allowed'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'class_id', c.id, 'course', c.course_name, 'class_date', c.class_date, 'class_time', c.class_time,
      'child', nullif(split_part(coalesce(l.child_name,''),' ',1),''), 'age', l.child_age, 'city', l.city)
      order by c.class_date nulls last, c.class_time)
    from public.classes c join public.leads l on l.id = c.lead_id
    where c.kind = 'demo' and c.status = 'scheduled' and c.teacher_id is null
      and l.status in ('demo_scheduled','demo_rescheduled')), '[]'::jsonb);
end $$;
revoke all on function public.demo_queue() from public, anon;
grant execute on function public.demo_queue() to authenticated;

-- ---- pick / release -----------------------------------------------------
create or replace function public.claim_demo(p_class uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare tid uuid; held int; c public.classes;
begin
  if public.my_role() <> 'teacher' then raise exception 'Only teachers can pick a demo'; end if;
  select id into tid from public.teachers where profile_id = (select auth.uid()) limit 1;
  if tid is null then raise exception 'Your login is not linked to a teacher record'; end if;
  select count(*) into held from public.classes
    where teacher_id = tid and kind = 'demo' and status = 'scheduled';
  if held >= 5 then raise exception 'You already hold 5 open demos — finish one first'; end if;
  select * into c from public.classes where id = p_class and kind = 'demo' and status = 'scheduled' for update;
  if not found then raise exception 'This demo is no longer available'; end if;
  if c.teacher_id is not null then raise exception 'Another teacher has just picked this demo'; end if;
  update public.classes set teacher_id = tid, claimed_at = now() where id = p_class;
end $$;
revoke all on function public.claim_demo(uuid) from public, anon;
grant execute on function public.claim_demo(uuid) to authenticated;

create or replace function public.release_demo(p_class uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare tid uuid;
begin
  select id into tid from public.teachers where profile_id = (select auth.uid()) limit 1;
  if not (public.is_admin() or (tid is not null and exists (select 1 from public.classes where id = p_class and teacher_id = tid))) then
    raise exception 'Not allowed';
  end if;
  update public.classes set teacher_id = null, teacher_name = null, claimed_at = null, parent_confirmed = false
   where id = p_class and kind = 'demo' and status = 'scheduled';
end $$;
revoke all on function public.release_demo(uuid) from public, anon;
grant execute on function public.release_demo(uuid) to authenticated;

-- ---- parent confirmed the time ----------------------------------------------
create or replace function public.confirm_demo(p_class uuid, p_ok boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.classes; ok boolean;
begin
  select * into c from public.classes where id = p_class and kind = 'demo';
  if not found then raise exception 'Demo not found'; end if;
  ok := public.is_admin()
     or exists (select 1 from public.leads l where l.id = c.lead_id and l.assigned_to = (select auth.uid()))
     or public._lead_in_my_demo(c.lead_id);
  if not ok then raise exception 'Not allowed'; end if;
  update public.classes set parent_confirmed = coalesce(p_ok, true) where id = p_class;
  insert into public.lead_activities (lead_id, actor_id, kind, outcome, note)
  values (c.lead_id, (select auth.uid()), 'note', 'note',
          case when coalesce(p_ok,true) then 'Parent confirmed the demo: ' || coalesce(to_char(c.class_date,'DD Mon YYYY'),'date TBC') || ' ' || coalesce(c.class_time,'')
               else 'Demo confirmation removed' end);
end $$;
revoke all on function public.confirm_demo(uuid,boolean) from public, anon;
grant execute on function public.confirm_demo(uuid,boolean) to authenticated;

-- ---- demo conducted: feedback + status + follow-up task ----------------------
create or replace function public.complete_demo(
  p_class uuid, p_rating int, p_level text, p_interest text, p_course text, p_notes text, p_next date
) returns void
language plpgsql security definer set search_path = '' as $$
declare c public.classes; l public.leads; ok boolean; summary text;
begin
  select * into c from public.classes where id = p_class and kind = 'demo';
  if not found then raise exception 'Demo not found'; end if;
  select * into l from public.leads where id = c.lead_id;
  ok := public.is_admin()
     or l.assigned_to = (select auth.uid())
     or public._lead_in_my_demo(c.lead_id);
  if not ok then raise exception 'Not allowed'; end if;
  summary := 'Demo conducted. Rating ' || coalesce(p_rating::text,'-') || '/5'
    || coalesce(' · level: ' || nullif(p_level,''), '')
    || coalesce(' · parent: ' || nullif(p_interest,''), '')
    || coalesce(' · suggested: ' || nullif(p_course,''), '')
    || coalesce(E'\n' || nullif(trim(p_notes),''), '');
  update public.classes set status = 'completed' where id = p_class;
  perform set_config('nmi.bypass', '1', true);
  update public.leads set status = 'demo_completed',
         next_follow_up = coalesce(p_next, next_follow_up),
         interested_course = coalesce(nullif(p_course,''), interested_course)
   where id = c.lead_id;
  insert into public.lead_activities (lead_id, actor_id, kind, outcome, note, next_follow_up)
  values (c.lead_id, (select auth.uid()), 'note', 'note', summary, p_next);
  if l.assigned_to is not null and l.assigned_to is distinct from (select auth.uid()) then
    insert into public.tasks (title, due_date, priority, lead_id, assignee_id)
    values ('Demo done — share fee & follow up: ' || coalesce(nullif(l.parent_name,''), nullif(l.phone,''), 'lead')
            || coalesce(' (' || nullif(l.child_name,'') || ')', ''), coalesce(p_next, current_date + 1), 'high', c.lead_id, l.assigned_to);
  end if;
end $$;
revoke all on function public.complete_demo(uuid,int,text,text,text,text,date) from public, anon;
grant execute on function public.complete_demo(uuid,int,text,text,text,text,date) to authenticated;
