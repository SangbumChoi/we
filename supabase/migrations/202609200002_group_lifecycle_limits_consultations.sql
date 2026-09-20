begin;

alter table public.family_groups
  add column status text not null default 'activated',
  add column member_limit smallint not null default 6,
  add column deprecated_at timestamptz,
  add constraint family_groups_status_check
    check (status in ('activated', 'deprecated')),
  add constraint family_groups_member_limit_check
    check (member_limit between 1 and 100);

alter table public.family_members
  drop constraint family_members_status_check,
  drop constraint family_members_user_id_fkey,
  alter column user_id drop not null,
  alter column joined_at drop not null,
  alter column joined_at drop default;

alter table public.family_members
  rename column left_at to exited_at;

update public.family_members
set status = case status
  when 'active' then 'activated'
  when 'left' then 'exited'
  else status
end;

alter table public.family_members
  alter column status set default 'invited',
  add column invited_at timestamptz,
  add column no_user_found_at timestamptz,
  add column status_changed_at timestamptz not null default now(),
  add column invited_by uuid references auth.users(id) on delete set null,
  add column invite_id uuid references public.family_invites(id) on delete set null,
  add constraint family_members_status_check
    check (status in ('invited', 'activated', 'exited', 'no_user_found')),
  add constraint family_members_user_id_fkey
    foreign key (user_id) references auth.users(id) on delete set null;

update public.family_members
set invited_at = coalesce(invited_at, created_at),
    joined_at = coalesce(joined_at, created_at),
    status_changed_at = now()
where status = 'activated';

drop index if exists public.family_members_user_idx;
create index family_members_user_idx
  on public.family_members(user_id)
  where status = 'activated';
create index family_members_family_status_idx
  on public.family_members(family_id, status);

alter table public.family_invites
  drop constraint family_invites_created_by_fkey,
  alter column created_by drop not null,
  add column status text not null default 'invited',
  add constraint family_invites_status_check
    check (status in ('invited', 'activated', 'expired', 'revoked', 'exhausted')),
  add constraint family_invites_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete set null;

alter table public.family_groups
  drop constraint family_groups_created_by_fkey,
  alter column created_by drop not null,
  add constraint family_groups_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete set null;

alter table public.health_records
  drop constraint health_records_created_by_fkey,
  alter column created_by drop not null,
  add constraint health_records_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete set null;

alter table public.care_actions
  drop constraint care_actions_sender_id_fkey,
  alter column sender_id drop not null,
  add constraint care_actions_sender_id_fkey
    foreign key (sender_id) references auth.users(id) on delete set null;

create table public.billing_purchases (
  id uuid primary key default gen_random_uuid(),
  purchaser_user_id uuid references auth.users(id) on delete set null,
  target_family_id uuid references public.family_groups(id) on delete set null,
  product_code text not null check (char_length(product_code) between 1 and 80),
  product_type text not null check (product_type in ('group_slot', 'member_slot')),
  quantity smallint not null default 1 check (quantity between 1 and 100),
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'refunded', 'revoked')),
  provider text not null default 'manual' check (char_length(provider) between 1 and 40),
  provider_reference text,
  amount numeric(12, 2) check (amount is null or amount >= 0),
  currency char(3),
  purchased_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (provider, provider_reference)
);

create table public.lifetime_entitlements (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  family_id uuid references public.family_groups(id) on delete cascade,
  entitlement_type text not null check (entitlement_type in ('group_slot', 'member_slot')),
  quantity smallint not null check (quantity between 1 and 100),
  status text not null default 'activated' check (status in ('activated', 'revoked')),
  is_lifetime boolean not null default true check (is_lifetime = true),
  purchase_id uuid unique references public.billing_purchases(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lifetime_entitlements_scope_check check (
    (entitlement_type = 'group_slot' and user_id is not null and family_id is null)
    or
    (entitlement_type = 'member_slot' and family_id is not null)
  )
);

create table public.membership_status_history (
  id bigint generated by default as identity primary key,
  family_id uuid not null references public.family_groups(id) on delete cascade,
  family_member_id uuid not null,
  previous_status text,
  new_status text not null,
  changed_by uuid references auth.users(id) on delete set null,
  reason text check (reason is null or char_length(reason) <= 300),
  created_at timestamptz not null default now(),
  foreign key (family_id, family_member_id)
    references public.family_members(family_id, id) on delete cascade
);

create table public.consultation_sessions (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.family_groups(id) on delete cascade,
  subject_member_id uuid not null,
  created_by uuid references auth.users(id) on delete set null,
  consultation_type text not null default 'ai'
    check (consultation_type in ('ai', 'family', 'doctor', 'expert')),
  status text not null default 'started'
    check (status in ('started', 'completed', 'cancelled')),
  title text not null check (char_length(title) between 1 and 120),
  initial_concern text check (initial_concern is null or char_length(initial_concern) <= 4000),
  summary text check (summary is null or char_length(summary) <= 4000),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (family_id, id),
  foreign key (family_id, subject_member_id)
    references public.family_members(family_id, id) on delete cascade
);

create table public.consultation_messages (
  id bigint generated by default as identity primary key,
  consultation_id uuid not null references public.consultation_sessions(id) on delete cascade,
  author_user_id uuid references auth.users(id) on delete set null,
  author_role text not null check (author_role in ('user', 'family', 'assistant', 'clinician', 'system')),
  content text not null check (char_length(content) between 1 and 10000),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.health_records
  add column consultation_session_id uuid,
  add constraint health_records_consultation_session_fkey
    foreign key (consultation_session_id)
    references public.consultation_sessions(id) on delete set null;

create index billing_purchases_user_time_idx
  on public.billing_purchases(purchaser_user_id, created_at desc);
create index lifetime_entitlements_user_idx
  on public.lifetime_entitlements(user_id)
  where status = 'activated';
create index lifetime_entitlements_family_idx
  on public.lifetime_entitlements(family_id)
  where status = 'activated';
create index membership_status_history_member_idx
  on public.membership_status_history(family_member_id, created_at desc);
create index consultation_sessions_family_time_idx
  on public.consultation_sessions(family_id, started_at desc);
create index consultation_sessions_subject_time_idx
  on public.consultation_sessions(subject_member_id, started_at desc);
create index consultation_messages_session_time_idx
  on public.consultation_messages(consultation_id, created_at);

create trigger billing_purchases_updated_at
before update on public.billing_purchases
for each row execute function public.set_updated_at();

create trigger lifetime_entitlements_updated_at
before update on public.lifetime_entitlements
for each row execute function public.set_updated_at();

create trigger consultation_sessions_updated_at
before update on public.consultation_sessions
for each row execute function public.set_updated_at();

create or replace function public.validate_health_record_consultation()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.consultation_session_id is not null and not exists (
    select 1
    from public.consultation_sessions cs
    where cs.id = new.consultation_session_id
      and cs.family_id = new.family_id
      and cs.subject_member_id = new.subject_member_id
  ) then
    raise exception '상담 이력은 같은 가족 그룹과 대상 구성원의 건강 기록에만 연결할 수 있습니다.';
  end if;
  return new;
end;
$$;

create trigger validate_health_record_consultation
before insert or update of consultation_session_id, family_id, subject_member_id
on public.health_records
for each row execute function public.validate_health_record_consultation();

create or replace function public.allowed_group_count(target_user_id uuid default auth.uid())
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select 2 + coalesce(sum(le.quantity), 0)::integer
  from public.lifetime_entitlements le
  where le.user_id = target_user_id
    and le.entitlement_type = 'group_slot'
    and le.status = 'activated';
$$;

create or replace function public.allowed_member_count(target_family_id uuid)
returns integer
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select fg.member_limit::integer
  from public.family_groups fg
  where fg.id = target_family_id;
$$;

create or replace function public.sync_family_member_limit(target_family_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.family_groups fg
  set member_limit = 6 + coalesce((
        select sum(le.quantity)
        from public.lifetime_entitlements le
        where le.family_id = target_family_id
          and le.entitlement_type = 'member_slot'
          and le.status = 'activated'
      ), 0),
      updated_at = now()
  where fg.id = target_family_id;
end;
$$;

create or replace function public.on_entitlement_changed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if old.entitlement_type = 'member_slot' and old.family_id is not null then
      perform public.sync_family_member_limit(old.family_id);
    end if;
    return old;
  end if;

  if new.entitlement_type = 'member_slot' and new.family_id is not null then
    perform public.sync_family_member_limit(new.family_id);
  end if;

  if tg_op = 'UPDATE'
    and old.entitlement_type = 'member_slot'
    and old.family_id is not null
    and old.family_id is distinct from new.family_id then
    perform public.sync_family_member_limit(old.family_id);
  end if;

  return new;
end;
$$;

create trigger on_lifetime_entitlement_changed
after insert or update or delete on public.lifetime_entitlements
for each row execute function public.on_entitlement_changed();

create or replace function public.enforce_family_member_limit()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  active_members integer;
  allowed_members integer;
begin
  if new.status <> 'activated' then
    return new;
  end if;

  if tg_op = 'UPDATE'
    and old.status = 'activated'
    and old.family_id = new.family_id then
    return new;
  end if;

  select fg.member_limit into allowed_members
  from public.family_groups fg
  where fg.id = new.family_id
  for update;

  select count(*) into active_members
  from public.family_members fm
  where fm.family_id = new.family_id
    and fm.status = 'activated'
    and fm.id is distinct from new.id;

  if active_members >= allowed_members then
    raise exception '가족 그룹의 최대 인원은 %명입니다. 평생 인원 확장이 필요합니다.', allowed_members;
  end if;

  return new;
end;
$$;

create trigger enforce_family_member_limit
before insert or update of status, family_id on public.family_members
for each row execute function public.enforce_family_member_limit();

create or replace function public.mark_deleted_user_membership()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if old.user_id is not null and new.user_id is null then
    new.status = 'no_user_found';
    new.no_user_found_at = now();
    new.status_changed_at = now();
  end if;
  return new;
end;
$$;

create trigger mark_deleted_user_membership
before update of user_id on public.family_members
for each row execute function public.mark_deleted_user_membership();

create or replace function public.sync_family_group_status(target_family_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  active_members integer;
  active_owners integer;
begin
  select count(*) into active_members
  from public.family_members fm
  where fm.family_id = target_family_id and fm.status = 'activated';

  if active_members = 0 then
    update public.family_groups
    set status = 'deprecated', deprecated_at = coalesce(deprecated_at, now()), updated_at = now()
    where id = target_family_id;

    update public.family_invites
    set status = 'revoked', revoked_at = coalesce(revoked_at, now())
    where family_id = target_family_id
      and status in ('invited', 'activated');
    return;
  end if;

  select count(*) into active_owners
  from public.family_members fm
  where fm.family_id = target_family_id
    and fm.status = 'activated'
    and fm.role = 'owner';

  if active_owners = 0 then
    update public.family_members
    set role = 'owner', updated_at = now()
    where id = (
      select fm.id
      from public.family_members fm
      where fm.family_id = target_family_id and fm.status = 'activated'
      order by case when fm.role = 'admin' then 0 else 1 end, fm.joined_at nulls last, fm.created_at
      limit 1
    );
  end if;

  update public.family_groups
  set status = 'activated', deprecated_at = null, updated_at = now()
  where id = target_family_id and status <> 'deprecated';
end;
$$;

create or replace function public.audit_membership_status_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  affected_family_id uuid;
begin
  if tg_op = 'INSERT' then
    affected_family_id = new.family_id;
    insert into public.membership_status_history (
      family_id, family_member_id, previous_status, new_status, changed_by, reason
    ) values (
      new.family_id, new.id, null, new.status, auth.uid(), 'membership_created'
    );
  else
    affected_family_id = coalesce(new.family_id, old.family_id);
    if old.status is distinct from new.status then
      insert into public.membership_status_history (
        family_id, family_member_id, previous_status, new_status, changed_by, reason
      ) values (
        new.family_id, new.id, old.status, new.status, auth.uid(), 'status_changed'
      );
    end if;
  end if;

  perform public.sync_family_group_status(affected_family_id);
  return new;
end;
$$;

create trigger audit_membership_status_change
after insert or update of status, user_id, family_id on public.family_members
for each row execute function public.audit_membership_status_change();

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
    join public.family_groups fg on fg.id = fm.family_id
    where fm.family_id = target_family_id
      and fm.user_id = target_user_id
      and fm.status = 'activated'
      and fg.status = 'activated'
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
    join public.family_groups fg on fg.id = fm.family_id
    where fm.family_id = target_family_id
      and fm.user_id = target_user_id
      and fm.status = 'activated'
      and fm.role in ('owner', 'admin')
      and fg.status = 'activated'
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
    join public.family_groups fg on fg.id = mine.family_id
    where mine.user_id = auth.uid()
      and theirs.user_id = target_user_id
      and mine.status = 'activated'
      and theirs.status = 'activated'
      and fg.status = 'activated'
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
  current_group_count integer;
  group_limit integer;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  perform 1
  from public.profiles p
  where p.id = auth.uid()
  for update;

  select count(*) into current_group_count
  from public.family_groups fg
  where fg.created_by = auth.uid() and fg.status = 'activated';

  group_limit = public.allowed_group_count(auth.uid());
  if current_group_count >= group_limit then
    raise exception '만들 수 있는 활성 가족 그룹은 %개입니다. 평생 그룹 확장이 필요합니다.', group_limit;
  end if;

  insert into public.family_groups (name, created_by, status, member_limit)
  values (coalesce(nullif(trim(group_name), ''), '우리 가족'), auth.uid(), 'activated', 6)
  returning id into new_family_id;

  insert into public.family_members (
    family_id, user_id, role, relation, family_nickname, status, invited_at, joined_at, status_changed_at
  ) values (
    new_family_id, auth.uid(), 'owner', '나',
    coalesce(nullif(trim(owner_nickname), ''), '나'),
    'activated', now(), now(), now()
  );

  insert into public.family_invites (family_id, created_by, status)
  values (new_family_id, auth.uid(), 'invited')
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

  select fi.*
  into matched_invite
  from public.family_invites fi
  join public.family_groups fg on fg.id = fi.family_id
  where upper(fi.code) = upper(trim(invite_code))
    and fi.status in ('invited', 'activated')
    and fi.revoked_at is null
    and fi.expires_at > now()
    and fi.use_count < fi.max_uses
    and fg.status = 'activated'
  for update of fi;

  if matched_invite.id is null then
    raise exception '유효하지 않거나 만료되었거나 종료된 가족 그룹의 초대 코드입니다.';
  end if;

  insert into public.family_members (
    family_id, user_id, role, relation, family_nickname, status,
    invited_at, invited_by, invite_id, joined_at, exited_at,
    no_user_found_at, status_changed_at
  ) values (
    matched_invite.family_id, auth.uid(), 'member',
    coalesce(nullif(trim(member_relation), ''), '기타 가족'),
    coalesce(nullif(trim(member_nickname), ''), '가족'),
    'activated', matched_invite.created_at, matched_invite.created_by,
    matched_invite.id, now(), null, null, now()
  )
  on conflict (family_id, user_id) do update
  set relation = excluded.relation,
      family_nickname = excluded.family_nickname,
      status = 'activated',
      invited_at = excluded.invited_at,
      invited_by = excluded.invited_by,
      invite_id = excluded.invite_id,
      joined_at = now(),
      exited_at = null,
      no_user_found_at = null,
      status_changed_at = now(),
      updated_at = now();

  update public.family_invites
  set use_count = use_count + 1,
      status = case
        when use_count + 1 >= max_uses then 'exhausted'
        else 'activated'
      end
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
  member_id uuid;
begin
  if auth.uid() is null then
    raise exception '로그인이 필요합니다.';
  end if;

  select id into member_id
  from public.family_members
  where family_id = target_family_id
    and user_id = auth.uid()
    and status = 'activated'
  for update;

  if member_id is null then
    raise exception '참여 중인 가족 그룹이 아닙니다.';
  end if;

  update public.family_members
  set status = 'exited',
      exited_at = now(),
      status_changed_at = now(),
      updated_at = now()
  where id = member_id;
end;
$$;

create or replace function public.can_access_consultation(target_consultation_id uuid, target_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.consultation_sessions cs
    where cs.id = target_consultation_id
      and public.is_family_member(cs.family_id, target_user_id)
  );
$$;

alter table public.billing_purchases enable row level security;
alter table public.lifetime_entitlements enable row level security;
alter table public.membership_status_history enable row level security;
alter table public.consultation_sessions enable row level security;
alter table public.consultation_messages enable row level security;

create policy "billing_purchases_select_owner_or_family_admin"
on public.billing_purchases for select to authenticated
using (
  purchaser_user_id = auth.uid()
  or (target_family_id is not null and public.is_family_admin(target_family_id))
);

create policy "lifetime_entitlements_select_beneficiary"
on public.lifetime_entitlements for select to authenticated
using (
  user_id = auth.uid()
  or (family_id is not null and public.is_family_member(family_id))
);

create policy "membership_status_history_select_family"
on public.membership_status_history for select to authenticated
using (public.is_family_member(family_id));

create policy "consultation_sessions_select_family"
on public.consultation_sessions for select to authenticated
using (public.is_family_member(family_id));

create policy "consultation_sessions_insert_family"
on public.consultation_sessions for insert to authenticated
with check (public.is_family_member(family_id) and created_by = auth.uid());

create policy "consultation_sessions_update_creator_or_admin"
on public.consultation_sessions for update to authenticated
using (created_by = auth.uid() or public.is_family_admin(family_id))
with check (public.is_family_member(family_id) and (created_by = auth.uid() or public.is_family_admin(family_id)));

create policy "consultation_messages_select_family"
on public.consultation_messages for select to authenticated
using (public.can_access_consultation(consultation_id));

create policy "consultation_messages_insert_self"
on public.consultation_messages for insert to authenticated
with check (
  public.can_access_consultation(consultation_id)
  and author_user_id = auth.uid()
  and author_role in ('user', 'family')
);

drop policy if exists "family_groups_delete_owner" on public.family_groups;
drop policy if exists "family_members_delete_self_or_admin" on public.family_members;

revoke delete on public.family_groups from authenticated;
revoke delete on public.family_members from authenticated;
revoke insert on public.family_groups from authenticated;
revoke update on public.family_groups from authenticated;
grant update (name, updated_at) on public.family_groups to authenticated;

revoke all on public.billing_purchases, public.lifetime_entitlements,
  public.membership_status_history, public.consultation_sessions,
  public.consultation_messages from anon;

grant select on public.billing_purchases, public.lifetime_entitlements,
  public.membership_status_history to authenticated;
grant select, insert, update on public.consultation_sessions to authenticated;
grant select, insert on public.consultation_messages to authenticated;

revoke all on function public.allowed_group_count(uuid) from public;
revoke all on function public.allowed_member_count(uuid) from public;
revoke all on function public.can_access_consultation(uuid, uuid) from public;
grant execute on function public.allowed_group_count(uuid) to authenticated;
grant execute on function public.allowed_member_count(uuid) to authenticated;
grant execute on function public.can_access_consultation(uuid, uuid) to authenticated;

commit;
