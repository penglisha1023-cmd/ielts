-- ============================================================
-- Fix: 学生缺少 profiles 行
-- 现象: auth.users 里有 12 个用户, 但 public.profiles 只有 1 行(darcy)。
--       说明注册自动建档触发器在生产库没生效。
-- 处理: (1) 重新建好触发器(幂等, 与 03-schema.sql 一致);
--       (2) 给所有现存、缺 profiles 行的用户回填。
-- 用法: 在 Supabase Dashboard → SQL Editor → New query 里整段粘贴运行一次。
-- ============================================================

-- 1. (重新)创建注册自动建 profiles 行的触发器(幂等)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 2. 回填: 给每个还没有 profiles 行的现存用户补一行
insert into public.profiles (id, display_name)
select u.id,
       coalesce(u.raw_user_meta_data ->> 'display_name', split_part(u.email, '@', 1))
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null
on conflict (id) do nothing;

-- 3. 校验: 下面这句应当返回 0(没有缺 profiles 行的用户了)
-- select count(*) as missing
-- from auth.users u left join public.profiles p on p.id = u.id
-- where p.id is null;
