begin;

create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.generate_family_invite_code()
returns text
language sql
volatile
set search_path = public, pg_temp
as $$
  select 'WE-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '나' check (char_length(display_name) between 1 and 30),
  avatar_key text not null default 'self',
  birth_date date,
  height_cm numeric(5, 1) check (height_cm is null or height_cm between 20 and 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.family_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null default '우리 가족' check (char_length(name) between 1 and 50),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.family_members (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.family_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'admin', 'member')),
  relation text not null default '기타 가족' check (char_length(relation) between 1 and 30),
  family_nickname text not null check (char_length(family_nickname) between 1 and 30),
  status text not null default 'active' check (status in ('active', 'left')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (family_id, user_id),
  unique (family_id, id)
);

create table public.family_invites (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.family_groups(id) on delete cascade,
  code text not null default public.generate_family_invite_code(),
  created_by uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null default (now() + interval '30 days'),
  max_uses integer not null default 20 check (max_uses between 1 and 100),
  use_count integer not null default 0 check (use_count >= 0),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique (code)
);

create table public.health_records (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.family_groups(id) on delete cascade,
  subject_member_id uuid not null,
  created_by uuid not null references auth.users(id) on delete cascade,
  record_type text not null default 'note' check (
    record_type in ('ai_summary', 'symptom', 'checkup', 'medication', 'vital', 'activity', 'note')
  ),
  title text not null check (char_length(title) between 1 and 100),
  summary text not null default '' check (char_length(summary) <= 2000),
  body_area text,
  severity smallint check (severity is null or severity between 0 and 10),
  source text not null default 'manual' check (
    source in ('manual', 'ai', 'apple_health', 'samsung_health', 'health_connect', 'import')
  ),
  visibility text not null default 'family' check (visibility in ('family', 'private')),
  occurred_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (family_id, id),
  foreign key (family_id, subject_member_id)
    references public.family_members(family_id, id) on delete cascade
);

create table public.care_actions (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.family_groups(id) on delete cascade,
  subject_member_id uuid not null,
  health_record_id uuid,
  sender_id uuid not null references auth.users(id) on delete cascade,
  action_type text not null check (action_type in ('check_in', 'cheer', 'help', 'acknowledge', 'message')),
  message text check (message is null or char_length(message) <= 500),
  created_at timestamptz not null default now(),
  foreign key (family_id, subject_member_id)
    references public.family_members(family_id, id) on delete cascade,
  foreign key (family_id, health_record_id)
    references public.health_records(family_id, id) on delete cascade
);

create index family_members_user_idx on public.family_members(user_id) where status = 'active';
create index family_invites_family_idx on public.family_invites(family_id);
create index health_records_family_time_idx on public.health_records(family_id, occurred_at desc);
create index health_records_subject_time_idx on public.health_records(subject_member_id, occurred_at desc);
create index care_actions_family_time_idx on public.care_actions(family_id, created_at desc);

create trigger profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger family_groups_updated_at
before update on public.family_groups
for each row execute function public.set_updated_at();

create trigger family_members_updated_at
before update on public.family_members
for each row execute function public.set_updated_at();

create trigger health_records_updated_at
before update on public.health_records
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id, display_name, avatar_key)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'name', ''),
      '나'
    ),
    'self'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

insert into public.profiles (id, display_name, avatar_key)
select
  u.id,
  coalesce(
    nullif(u.raw_user_meta_data ->> 'full_name', ''),
    nullif(u.raw_user_meta_data ->> 'name', ''),
    '나'
  ),
  'self'
from auth.users u
on conflict (id) do nothing;

create or replace function public.is_family_member(target_family_id uuid, target_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.family_members fm
    where fm.family_id = target_family_id
      and fm.user_id = target_user_id
      and fm.status = 'active'
  );
$$;

create or replace function public.is_family_admin(target_family_id uuid, target_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.family_members fm
    where fm.family_id = target_family_id
      and fm.user_id = target_user_id
      and fm.status = 'active'
      and fm.role in ('owner', 'admin')
  );
$$;

create or replace function public.shares_family_with(target_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.family_members mine
    join public.family_members theirs on theirs.family_id = mine.family_id
    where mine.user_id = auth.uid()
      and theirs.user_id = target_user_id
      and mine.status = 'active'
      and theirs.status = 'active'
  );
$$;

create or replace function public.create_family_group(
  group_name text default '우리 가족',
  owner_nickname text default '나'
)
returns table (family_id uuid, invite_code text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_family_id uuid;
  new_invite_code text;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  insert into public.family_groups (name, created_by)
  values (coalesce(nullif(trim(group_name), ''), '우리 가족'), auth.uid())
  returning id into new_family_id;

  insert into public.family_members (family_id, user_id, role, relation, family_nickname)
  values (
    new_family_id,
    auth.uid(),
    'owner',
    '나',
    coalesce(nullif(trim(owner_nickname), ''), '나')
  );

  insert into public.family_invites (family_id, created_by)
  values (new_family_id, auth.uid())
  returning code into new_invite_code;

  return query select new_family_id, new_invite_code;
end;
$$;

create or replace function public.join_family_by_code(
  invite_code text,
  member_relation text default '기타 가족',
  member_nickname text default '가족'
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  matched_invite public.family_invites%rowtype;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select *
  into matched_invite
  from public.family_invites fi
  where upper(fi.code) = upper(trim(invite_code))
    and fi.revoked_at is null
    and fi.expires_at > now()
    and fi.use_count < fi.max_uses
  for update;

  if matched_invite.id is null then
    raise exception '유효하지 않거나 만료된 초대 코드입니다.';
  end if;

  insert into public.family_members (
    family_id,
    user_id,
    role,
    relation,
    family_nickname,
    status,
    left_at
  )
  values (
    matched_invite.family_id,
    auth.uid(),
    'member',
    coalesce(nullif(trim(member_relation), ''), '기타 가족'),
    coalesce(nullif(trim(member_nickname), ''), '가족'),
    'active',
    null
  )
  on conflict (family_id, user_id) do update
  set relation = excluded.relation,
      family_nickname = excluded.family_nickname,
      status = 'active',
      left_at = null,
      updated_at = now();

  update public.family_invites
  set use_count = use_count + 1
  where id = matched_invite.id;

  return matched_invite.family_id;
end;
$$;

create or replace function public.leave_family_group(target_family_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_role text;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select role into current_role
  from public.family_members
  where family_id = target_family_id
    and user_id = auth.uid()
    and status = 'active';

  if current_role is null then
    raise exception '참여 중인 가족 그룹이 아닙니다.';
  end if;

  if current_role = 'owner' then
    raise exception '가족 그룹 소유자는 소유권을 넘기거나 그룹을 삭제한 뒤 나갈 수 있습니다.';
  end if;

  update public.family_members
  set status = 'left', left_at = now(), updated_at = now()
  where family_id = target_family_id and user_id = auth.uid();
end;
$$;

alter table public.profiles enable row level security;
alter table public.family_groups enable row level security;
alter table public.family_members enable row level security;
alter table public.family_invites enable row level security;
alter table public.health_records enable row level security;
alter table public.care_actions enable row level security;

create policy "profiles_select_self_or_family"
on public.profiles for select to authenticated
using (id = auth.uid() or public.shares_family_with(id));

create policy "profiles_insert_self"
on public.profiles for insert to authenticated
with check (id = auth.uid());

create policy "profiles_update_self"
on public.profiles for update to authenticated
using (id = auth.uid())
with check (id = auth.uid());

create policy "profiles_delete_self"
on public.profiles for delete to authenticated
using (id = auth.uid());

create policy "family_groups_select_member"
on public.family_groups for select to authenticated
using (public.is_family_member(id));

create policy "family_groups_insert_creator"
on public.family_groups for insert to authenticated
with check (created_by = auth.uid());

create policy "family_groups_update_admin"
on public.family_groups for update to authenticated
using (public.is_family_admin(id))
with check (public.is_family_admin(id));

create policy "family_groups_delete_owner"
on public.family_groups for delete to authenticated
using (created_by = auth.uid());

create policy "family_members_select_family"
on public.family_members for select to authenticated
using (public.is_family_member(family_id));

create policy "family_members_insert_admin"
on public.family_members for insert to authenticated
with check (public.is_family_admin(family_id));

create policy "family_members_update_self_or_admin"
on public.family_members for update to authenticated
using (user_id = auth.uid() or public.is_family_admin(family_id))
with check (user_id = auth.uid() or public.is_family_admin(family_id));

create policy "family_members_delete_self_or_admin"
on public.family_members for delete to authenticated
using (user_id = auth.uid() or public.is_family_admin(family_id));

create policy "family_invites_select_admin"
on public.family_invites for select to authenticated
using (public.is_family_admin(family_id));

create policy "family_invites_insert_admin"
on public.family_invites for insert to authenticated
with check (public.is_family_admin(family_id) and created_by = auth.uid());

create policy "family_invites_update_admin"
on public.family_invites for update to authenticated
using (public.is_family_admin(family_id))
with check (public.is_family_admin(family_id));

create policy "family_invites_delete_admin"
on public.family_invites for delete to authenticated
using (public.is_family_admin(family_id));

create policy "health_records_select_family"
on public.health_records for select to authenticated
using (
  public.is_family_member(family_id)
  and (
    visibility = 'family'
    or created_by = auth.uid()
    or exists (
      select 1 from public.family_members fm
      where fm.id = subject_member_id and fm.user_id = auth.uid()
    )
  )
);

create policy "health_records_insert_family"
on public.health_records for insert to authenticated
with check (public.is_family_member(family_id) and created_by = auth.uid());

create policy "health_records_update_author_or_admin"
on public.health_records for update to authenticated
using (created_by = auth.uid() or public.is_family_admin(family_id))
with check (public.is_family_member(family_id) and (created_by = auth.uid() or public.is_family_admin(family_id)));

create policy "health_records_delete_author_or_admin"
on public.health_records for delete to authenticated
using (created_by = auth.uid() or public.is_family_admin(family_id));

create policy "care_actions_select_family"
on public.care_actions for select to authenticated
using (public.is_family_member(family_id));

create policy "care_actions_insert_family"
on public.care_actions for insert to authenticated
with check (public.is_family_member(family_id) and sender_id = auth.uid());

create policy "care_actions_update_sender"
on public.care_actions for update to authenticated
using (sender_id = auth.uid())
with check (sender_id = auth.uid());

create policy "care_actions_delete_sender_or_admin"
on public.care_actions for delete to authenticated
using (sender_id = auth.uid() or public.is_family_admin(family_id));

revoke all on public.profiles, public.family_groups, public.family_members,
  public.family_invites, public.health_records, public.care_actions from anon;

grant select, insert, update, delete on public.profiles, public.family_groups,
  public.family_invites, public.health_records, public.care_actions to authenticated;
grant select, insert, delete on public.family_members to authenticated;
grant update (relation, family_nickname, updated_at) on public.family_members to authenticated;

revoke all on function public.create_family_group(text, text) from public;
revoke all on function public.join_family_by_code(text, text, text) from public;
revoke all on function public.leave_family_group(uuid) from public;
revoke all on function public.is_family_member(uuid, uuid) from public;
revoke all on function public.is_family_admin(uuid, uuid) from public;
revoke all on function public.shares_family_with(uuid) from public;
grant execute on function public.create_family_group(text, text) to authenticated;
grant execute on function public.join_family_by_code(text, text, text) to authenticated;
grant execute on function public.leave_family_group(uuid) to authenticated;
grant execute on function public.is_family_member(uuid, uuid) to authenticated;
grant execute on function public.is_family_admin(uuid, uuid) to authenticated;
grant execute on function public.shares_family_with(uuid) to authenticated;

commit;
