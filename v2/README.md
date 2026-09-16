# V-POINTS 2.0 — Development Build

This folder is the isolated V-POINTS 2.0 build area. The current production app on `main` is not replaced by this work.

## Current foundation

- `v2/index.html` — phone-first dashboard prototype.
- `supabase/v2_schema.sql` — isolated `vp2_*` database foundation.
- `VPOINTS2_SPEC.md` — frozen V2 product/permission/process specification.

## Locked operating rules

1. Staff are employee/performance profiles, not V-POINTS login accounts.
2. Management login accounts can link to their own performance profile, including the National Retail Head.
3. Executive can appraise the National Retail Head; self-merit is never allowed.
4. Employee point balance is calculated from an immutable ledger. No direct balance editing.
5. Incident reporting does not automatically deduct points. Due process and required review/sign-off come first.
6. Regional access is limited to the assigned region; Admin access is limited to assigned branch(es).
7. Visibility does not automatically grant approval or final-posting authority.
8. Evidence will use private storage and backend authorization; no employee evidence belongs in public GitHub files.
9. Existing production data is not migrated until V2 is tested and approved.

## Next implementation gates

1. Complete database tables for policies, merits, cases, evidence, approvals, acknowledgements, appraisals, notifications, and audit events.
2. Add reviewed RLS helper functions and policies for Executive/National/Functional/Regional/Branch scope.
3. Import the official ACT-001–086 policy source into a V2 policy master without changing policy substance.
4. Connect the mobile UI to the isolated backend.
5. Pilot before any production cutover.
