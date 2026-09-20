# Supabase family data model

`migrations/202609200001_family_core.sql` creates the first production data model for **we**.

## Core relationships

- `profiles`: one profile per authenticated account
- `family_groups`: a family room/group
- `family_members`: membership between accounts and family groups, including a group-specific nickname and relationship
- `family_invites`: expiring, revocable invitation codes
- `health_records`: symptoms, checkups, vitals, medication notes, and AI summaries
- `care_actions`: check-ins, encouragement, acknowledgements, and messages

A user may belong to more than one family group. Health records are always scoped to one family group and one member.

## Security

Every table has Row Level Security enabled. The publishable key can be used by the web/mobile client, while access is limited by the signed-in user's active family memberships. Invitation codes are redeemed only through the `join_family_by_code` database function.

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
