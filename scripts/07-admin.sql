-- ============================================================
-- Admin role + student overview
-- Run once in Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- 1. Add is_admin flag to profiles
alter table public.profiles
  add column if not exists is_admin boolean not null default false;

-- 2. Promote Darcy to admin (run again any time to re-apply)
update public.profiles
  set is_admin = true
  where id = (select id from auth.users where email = 'darcy.hu0714@hotmail.com');

-- 3. Admin RPC: per-student overview across listening + reading
-- SECURITY DEFINER so it can read auth.users and bypass RLS on scores,
-- but we guard with an explicit is_admin check at the top.
create or replace function public.get_admin_student_overview()
returns table (
  user_id           uuid,
  email             text,
  display_name      text,
  signed_up_at      timestamptz,
  listening_done    bigint,
  reading_done      bigint,
  total_attempts    bigint,
  total_time_secs   bigint,
  avg_score_pct     numeric,
  last_activity_at  timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from public.profiles where id = auth.uid() and is_admin = true
  ) then
    raise exception 'admin only';
  end if;

  return query
  with best as (
    select s.user_id, s.test_id, max(s.score) as best_score, max(s.total) as test_total
    from public.scores s
    group by s.user_id, s.test_id
  ),
  done_split as (
    select b.user_id,
           count(*) filter (where b.test_id <  10000)::bigint as listening_done,
           count(*) filter (where b.test_id >= 10000)::bigint as reading_done,
           round(sum(b.best_score)::numeric / nullif(sum(b.test_total), 0) * 100, 1) as avg_score_pct
    from best b
    group by b.user_id
  ),
  activity as (
    select s.user_id,
           count(*)::bigint as total_attempts,
           sum(s.duration_secs)::bigint as total_time_secs,
           max(s.finished_at) as last_activity_at
    from public.scores s
    group by s.user_id
  )
  select u.id,
         u.email::text,
         p.display_name,
         u.created_at,
         coalesce(ds.listening_done, 0),
         coalesce(ds.reading_done, 0),
         coalesce(ac.total_attempts, 0),
         coalesce(ac.total_time_secs, 0),
         ds.avg_score_pct,
         ac.last_activity_at
  from auth.users u
  left join public.profiles p on p.id = u.id
  left join done_split ds      on ds.user_id = u.id
  left join activity ac        on ac.user_id = u.id
  order by ac.last_activity_at desc nulls last, u.created_at desc;
end;
$$;

grant execute on function public.get_admin_student_overview() to authenticated;
