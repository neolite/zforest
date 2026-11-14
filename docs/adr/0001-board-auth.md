# Board auth: phased identity — tripcodes first, accounts second

**Status:** proposed

zboard today is purely anonymous: the `users` table stores only
`zfxu` cookie tokens and `anonName(rownum)` derives display names.
Adding real authorization forces a framework-level decision because
of one non-obvious constraint: **render groups share Dom/history/rev
across sessions on the same route** (docs/meta-framework.md §4.1), so
the moment a view depends on *who is looking* (identity chip, own-post
delete button, "posting as" label), grouped sessions diverge and the
group key must carry an auth dimension.

## Decision

Ship auth in two phases:

1. **Tripcodes (4chan-style)** — an optional `#trip` field on the
   post/comment form. The trip is a per-post secret: HMAC-derived
   `!code` suffix on the display name, stored as a hash on the row.
   Zero auth state, zero session changes, zero group-key changes —
   the trip renders identically for every viewer because it is post
   *content*, not viewer state.

2. **Accounts (optional)** — `accounts` table (`name UNIQUE`,
   `pass_hash` via PBKDF2-HMAC-SHA256 + per-user salt — Zig std has no
   argon2; `zfxa` auth cookie → `auth_token` → account), login/logout/
   register as ordinary file-routed pages (`pages/login.zig`,
   `pages/register.zig` — the codegen makes this free), posts gain
   `acct INTEGER NULL`, and the first gated action lands:
   delete-own-post. This phase REQUIRES `groupKey += auth class`
   (`home:anon` vs `home:acct:7`) in `groups.zig` — sessions of the
   same account share a group, different auth states fragment.

## Considered options

- **Accounts only, skip tripcodes** — viable, but tripcodes are ~half
  the work and are the idiomatic imageboard identity; doing them
  first de-risks the identity-display plumbing (`!code` formatting,
  author resolution) that accounts reuse.
- **Per-user UI via live islands inside groups** — rejected:
  `bindTree`/`bindIslands` emit ops into the *session's* PatchLog,
  while render groups publish one shared batch to all members. A
  per-session binder op reaches only that session's subscribers —
  other group members' DOMs diverge silently. Live bindings are
  correct only in per-session archetypes (or whole live pages).
- **Auth as framework-provided Deps hooks** (login/session plumbing
  in `zmeta/session.zig`) — deferred: one app doesn't justify
  generalizing; the app owns `readCookies`/`out_cookie`/dispatch
  hooks already. Revisit if a second app needs accounts.
- **Mutating the session's route key on login** — impossible by
  construction (Dom/history/graph/rev/CSRF are per-`(token, route)`);
  login is an action + cookie, not a route change.

## Consequences

- Phase 1 touches only `model.zig` (column + HMAC verify), the post/
  comment forms, and name formatting — no session, group, or client
  changes.
- Phase 2 adds a schema migration path (first `ALTER TABLE` need —
  current schema is `CREATE TABLE IF NOT EXISTS` only), an auth
  cookie alongside `zfxu`, and the group-key auth dimension. Session
  cap accounting is unchanged (auth rides the existing session).
- PBKDF2 iteration count is a demo-grade trade-off; if zboard ever
  holds real accounts, swap the KDF — the `pass_hash` column format
  (`salt$iterations$hash`) leaves room.
