-- =====================================================================
-- Next Move India LMS | Phase 8 | Assign leads to counselors AND teachers
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-7.
--
-- * A lead assigned to a counselor or teacher is visible to THAT person only
--   (with parent name + phone, so they can call / WhatsApp).
-- * They can update status, notes, follow-up date and demo details.
--   They cannot reassign, delete, or see other people's leads.
-- * Assigning a lead automatically creates a "Call new lead" task for the assignee.
-- =====================================================================

-- teachers: see + update only the leads assigned to them
drop policy if exists leads_teacher_select on public.leads;
create policy leads_teacher_select on public.leads for select to authenticated
  using (public.my_role() = 'teacher' and assigned_to = (select auth.uid()));
drop policy if exists leads_teacher_update on public.leads;
create policy leads_teacher_update on public.leads for update to authenticated
  using (public.my_role() = 'teacher' and assigned_to = (select auth.uid()))
  with check (public.my_role() = 'teacher' and assigned_to = (select auth.uid()));

-- staff who are not admin cannot change system fields of a lead
create or replace function public.leads_protect() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if (select auth.uid()) is not null and not public.is_admin() then
    new.assigned_to := old.assigned_to;
    new.source := old.source;
    new.sheet_key := old.sheet_key;
    new.converted_student_id := old.converted_student_id;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
revoke all on function public.leads_protect() from public, anon, authenticated;
drop trigger if exists leads_protect on public.leads;
create trigger leads_protect before update on public.leads
  for each row execute function public.leads_protect();

-- assigning a lead creates a call task for the assignee
create or replace function public.leads_assign_task() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.assigned_to is not null
     and (tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to)
     and new.assigned_to is distinct from (select auth.uid())
     and new.status in ('new','contacted','interested','call_back_later','follow_up') then
    insert into public.tasks (title, due_date, priority, lead_id, assignee_id)
    values ('Call new lead: ' || coalesce(nullif(new.parent_name,''), nullif(new.phone,''), 'lead')
            || coalesce(' (' || nullif(new.child_name,'') || ')', ''),
            current_date, 'high', new.id, new.assigned_to);
  end if;
  return null;
end $$;
revoke all on function public.leads_assign_task() from public, anon, authenticated;
drop trigger if exists leads_assign_task on public.leads;
create trigger leads_assign_task after insert or update of assigned_to on public.leads
  for each row execute function public.leads_assign_task();

-- teachers with an assigned lead may plan its demo (same as counselors)
drop policy if exists class_materials_counselor on public.class_materials;
create policy class_materials_counselor on public.class_materials for all to authenticated
  using (public.my_role() in ('counselor','teacher') and exists (select 1 from public.classes c where c.id = class_id and c.kind = 'demo' and exists (select 1 from public.leads l where l.id = c.lead_id)))
  with check (public.my_role() in ('counselor','teacher') and exists (select 1 from public.classes c where c.id = class_id and c.kind = 'demo' and exists (select 1 from public.leads l where l.id = c.lead_id)));
drop policy if exists classes_counselor_demo on public.classes;
create policy classes_counselor_demo on public.classes for update to authenticated
  using (public.my_role() in ('counselor','teacher') and kind = 'demo' and exists (select 1 from public.leads l where l.id = lead_id))
  with check (public.my_role() in ('counselor','teacher') and kind = 'demo' and exists (select 1 from public.leads l where l.id = lead_id));
