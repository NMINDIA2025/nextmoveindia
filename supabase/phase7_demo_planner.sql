-- =====================================================================
-- Next Move India LMS | Phase 7 | Demo planner: materials per class + file upload
-- Run once in Supabase SQL Editor. Safe to re-run. Needs phases 1-6.
--
-- * Materials can be an uploaded file (PDF, slides, worksheet, short video)
--   kept privately in Supabase Storage, or a link.
-- * Each class (e.g. a demo) can have prep materials attached, so the
--   teacher gets everything in one place.
-- * Counselors may plan the demos of their own leads.
-- =====================================================================

alter table public.materials add column if not exists file_path text;
alter table public.materials add column if not exists file_name text;

create table if not exists public.class_materials (
  id          uuid primary key default gen_random_uuid(),
  class_id    uuid not null references public.classes(id) on delete cascade,
  material_id uuid not null references public.materials(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (class_id, material_id)
);
create index if not exists class_materials_class_idx on public.class_materials (class_id);
alter table public.class_materials enable row level security;

drop policy if exists class_materials_admin on public.class_materials;
create policy class_materials_admin on public.class_materials for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists class_materials_counselor on public.class_materials;
create policy class_materials_counselor on public.class_materials for all to authenticated
  using (public.my_role() = 'counselor' and exists (select 1 from public.classes c where c.id = class_id and c.kind = 'demo' and c.lead_id is not null))
  with check (public.my_role() = 'counselor' and exists (select 1 from public.classes c where c.id = class_id and c.kind = 'demo' and c.lead_id is not null));
drop policy if exists class_materials_teacher on public.class_materials;
create policy class_materials_teacher on public.class_materials for select to authenticated
  using (public.my_role() = 'teacher' and class_id in (select c.id from public.classes c
         where c.teacher_id in (select t.id from public.teachers t where t.profile_id = (select auth.uid()))));

-- counselors can plan the demo class of leads they can see
drop policy if exists classes_counselor_demo on public.classes;
create policy classes_counselor_demo on public.classes for update to authenticated
  using (public.my_role() = 'counselor' and kind = 'demo' and exists (select 1 from public.leads l where l.id = lead_id))
  with check (public.my_role() = 'counselor' and kind = 'demo' and exists (select 1 from public.leads l where l.id = lead_id));

-- staff can add materials (upload); only admin edits/deletes. Staff see hidden prep material too.
drop policy if exists materials_staff_insert on public.materials;
create policy materials_staff_insert on public.materials for insert to authenticated
  with check (public.my_role() in ('counselor','teacher'));
drop policy if exists materials_staff_read on public.materials;
create policy materials_staff_read on public.materials for select to authenticated
  using (public.my_role() in ('counselor','teacher'));

-- demo classes start with the key facts for the teacher (never parent contact details)
create or replace function public.lead_demo_class() returns trigger
language plpgsql security definer set search_path = '' as $$
declare cid uuid; d date; ttl text; nts text;
begin
  d := public.parse_demo_date(new.demo_date);
  ttl := 'Free demo – ' || coalesce(nullif(split_part(coalesce(new.child_name,''),' ',1),''), 'new student')
         || coalesce(' (' || nullif(new.interested_course,'') || ')', '');
  nts := 'Child: ' || coalesce(nullif(split_part(coalesce(new.child_name,''),' ',1),''), 'new student')
         || coalesce(', age ' || nullif(new.child_age,''), '')
         || coalesce('. Interested in: ' || nullif(new.interested_course,''), '') || '.';
  if new.status in ('demo_scheduled','demo_rescheduled') then
    select id into cid from public.classes where lead_id = new.id and kind = 'demo' and status = 'scheduled' limit 1;
    if cid is null then
      insert into public.classes (title, course_name, kind, class_date, class_time, duration_min, status, lead_id, notes)
      values (ttl, new.interested_course, 'demo', d, nullif(trim(coalesce(new.demo_time,'')),''), 30, 'scheduled', new.id, nts);
    else
      update public.classes set title = ttl, course_name = new.interested_course,
             class_date = coalesce(d, class_date), class_time = coalesce(nullif(trim(coalesce(new.demo_time,'')),''), class_time)
       where id = cid;
    end if;
  elsif new.status = 'demo_completed' then
    update public.classes set status = 'completed' where lead_id = new.id and kind = 'demo' and status = 'scheduled';
  elsif new.status in ('not_interested','not_reachable') then
    update public.classes set status = 'cancelled' where lead_id = new.id and kind = 'demo' and status = 'scheduled';
  end if;
  return null;
end $$;
revoke all on function public.lead_demo_class() from public, anon, authenticated;

-- ---------- private file storage for materials -----------------------
insert into storage.buckets (id, name, public, file_size_limit)
values ('materials', 'materials', false, 52428800)
on conflict (id) do update set file_size_limit = 52428800, public = false;

drop policy if exists "materials staff upload" on storage.objects;
create policy "materials staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'materials' and public.my_role() in ('admin','counselor','teacher'));
drop policy if exists "materials staff manage" on storage.objects;
create policy "materials staff manage" on storage.objects for update to authenticated
  using (bucket_id = 'materials' and public.is_admin()) with check (bucket_id = 'materials' and public.is_admin());
drop policy if exists "materials staff delete" on storage.objects;
create policy "materials staff delete" on storage.objects for delete to authenticated
  using (bucket_id = 'materials' and public.is_admin());
-- reading: staff always; families only files of materials they are allowed to see
drop policy if exists "materials read" on storage.objects;
create policy "materials read" on storage.objects for select to authenticated
  using (bucket_id = 'materials' and (
    public.my_role() in ('admin','counselor','teacher')
    or exists (select 1 from public.materials m where m.file_path = storage.objects.name and m.published)));
