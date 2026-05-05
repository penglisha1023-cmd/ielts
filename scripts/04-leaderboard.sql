-- ============================================================
-- Leaderboard function
-- Aggregates scores across all users; uses SECURITY DEFINER to
-- bypass RLS so the leaderboard sees everyone's data.
-- Returned columns are aggregates only — no individual scores
-- or test ids are exposed for other users.
-- ============================================================

create or replace function public.get_leaderboard(
  p_subject text default 'listening',
  p_limit int default 100
)
returns table (
  user_id          uuid,
  display_name     text,
  tests_completed  bigint,
  avg_score_pct    numeric,
  total_time_secs  bigint,
  is_me            boolean
)
language sql
security definer
set search_path = public
as $$
  with best as (
    -- best score per (user, test) — counted once per test even if re-attempted
    select user_id, test_id, max(score) as best_score, max(total) as test_total
    from public.scores
    group by user_id, test_id
  ),
  agg as (
    select b.user_id,
           count(*)::bigint as tests_completed,
           round(sum(b.best_score)::numeric / nullif(sum(b.test_total), 0) * 100, 1) as avg_score_pct,
           (select sum(duration_secs) from public.scores s where s.user_id = b.user_id)::bigint as total_time_secs
    from best b
    group by b.user_id
  )
  select a.user_id,
         coalesce(p.display_name, '匿名用户') as display_name,
         a.tests_completed,
         a.avg_score_pct,
         a.total_time_secs,
         (a.user_id = auth.uid()) as is_me
  from agg a
  left join public.profiles p on p.id = a.user_id
  order by a.tests_completed desc, a.avg_score_pct desc nulls last
  limit p_limit;
$$;

grant execute on function public.get_leaderboard(text, int) to anon, authenticated;
