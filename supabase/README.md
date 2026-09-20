# Supabase family data model

`migrations/202609200001_family_core.sql` creates the first production data model for **we**.

## Core relationships

- `profiles`: one profile per authenticated account
- `family_groups`: a family room/group
- `family_members`: membership between accounts and family groups, including a group-specific nickname and relationship
- `family_invites`: expiring, revocable invitation codes
- `health_records`: symptoms, checkups, vitals, medication notes, and AI summaries
- `care_actions`: check-ins, encouragement, acknowledgements, and messages
- `membership_status_history`: an append-only history of membership changes
- `consultation_sessions` / `consultation_messages`: AI, family, doctor, and expert consultation history
- `billing_purchases` / `lifetime_entitlements`: permanent room and member-capacity upgrades

A user may belong to more than one family group. Health records are always scoped to one family group and one member.

## Lifecycle and limits

- Each account may create 2 active family groups by default.
- Each family group may have 6 active members by default.
- A user may join any number of groups, subject to each group's member limit.
- Paid `group_slot` and `member_slot` entitlements are permanent and increase these limits.
- Membership status follows `invited → activated → exited`; deleted accounts remain as `no_user_found` so history is not lost.
- A group automatically becomes `deprecated` when it has no `activated` members. Its invitation codes are revoked and it cannot be rejoined.
- If an owner exits while other members remain, ownership moves to the oldest active admin or member.

## Security

Every table has Row Level Security enabled. The publishable key can be used by the web/mobile client, while access is limited by the signed-in user's active family memberships. Invitation codes are redeemed only through the `join_family_by_code` database function.

Capacity checks run in database triggers and functions, so they cannot be bypassed by changing the app UI. Purchase and entitlement rows are read-only to normal users and are intended to be written only by a trusted payment webhook or administrator.

Never expose a Supabase secret key, service-role key, database password, or personal access token in client code or GitHub.

## Client operations

Create a group:

```js
await supabase.rpc('create_family_group', {
  group_name: '우리 가족',
  owner_nickname: '나'
})
```

Join with an invitation:

```js
await supabase.rpc('join_family_by_code', {
  invite_code: 'WE-1234ABCD',
  member_relation: '자녀',
  member_nickname: '막내'
})
```

Leave a group:

```js
await supabase.rpc('leave_family_group', { target_family_id: familyId })
```
