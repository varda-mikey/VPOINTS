# V-POINTS 2.0 — Locked Build Specification

Status: Development foundation
Date: 2026-09-16

## Core principle
V-POINTS is a management-controlled recognition, policy-compliance, case-tracking, employee-standing and appraisal-evidence system. Employees do not need login accounts. The system records/supports approved company processes; it does not replace HR procedure or employee due process.

## Everyone has an employee/performance profile
All people whose performance can be appraised or whose V-Points can change have a profile record, including management users.

Examples:
- Staff profile — appraised/managed by authorized leaders.
- Branch/Admin profile — can also be appraised by appropriate higher authority.
- Regional Retail Head profile — National/authorized management can appraise and award approved merit.
- National Functional Head profile — appropriate National/Executive authority can appraise.
- National Retail Head profile — Executive can appraise the NRH.
- Executive may have a system user account; whether Executive participates in employee V-Points/appraisal is separately configurable.

A management user account and a performance profile are separate concepts. A user may link to one employee/profile record.

## Organization hierarchy
EXECUTIVE
→ NATIONAL RETAIL HEAD (solo top National operational leader)
→ National Functional Heads (HR, FSQA, Accounting, Marketing, etc.)
→ Regional Retail Heads
→ Branch Leaders / Admin
→ Staff

Hierarchy, function, scope and authority are stored separately.

## Visibility
- Executive: national/all visibility.
- NRH: all regions/branches/employees.
- National functional heads: national visibility appropriate to their function.
- Regional: ONLY their assigned region. Their ALL view means all branches/employees inside that region, never another region.
- Admin: only specifically assigned branch(es).
- Branch Leader: only assigned branch/team.

These restrictions must be enforced in the backend/database, not only hidden in UI.

## Employee record
Show full employee name everywhere appropriate. Store only data needed for V-POINTS: full name, employee ID, photo, position, branch/region, Company or Agency, employment status, hire/deployment date, V-Points history, merit history, policy/case history, acknowledgements and relevant appraisal/training evidence.

The full HR 201 File module is intentionally excluded. Official 201 files remain under the existing HR/manual process.

## Employee maintenance
- Admin is primary branch encoder/custodian and may add/fix/upload employee information in assigned branches.
- Regional may assist and maintain employees within their region.
- New employee remains PENDING ACTIVATION until validated by Regional OR HR OR NRH.
- Important changes are audited.
- Transfers move the existing employee/profile and preserve current points/history; never reset to 100.
- Inactive/separated/end-of-assignment records leave active leaderboards but history is retained according to approved retention rules.
- Agency employees are clearly identified; use END VARDA ASSIGNMENT where appropriate rather than assuming Varda terminates agency employment.

## V-Points ledger
Starting balance: 100.
Current score = 100 + posted merits - validated policy deductions + authorized reversals.
No direct balance editing. Corrections use reversal/void events with mandatory reason, actor and timestamp; original history remains.

## Merit
- No self-merit.
- Admin cannot approve merit.
- Admin/authorized branch users may submit merit evidence/request where permitted.
- Staff merit requires Regional approval according to the approved merit matrix/rules.
- Regional's own merit must come from legitimate documented sources and be approved by appropriate National authority; National appraisal may be a source.
- National/NRH merit/appraisal follows authority above the subject; NRH is appraised by Executive.
- Point values are controlled by the approved merit matrix, not freely typed.
- High points may flag REWARD ELIGIBLE / recognition candidate. Rewards are not automatically guaranteed unless a future approved rule explicitly makes them automatic.

## Incident / policy case
Never provide a direct DEMERIT action.
Flow: REPORT INCIDENT → select ACT/category → evidence/IR → required process/reviews → record HR/company outcome → required sign-offs → authorized policy result posting → ledger effect.

Reporting an incident does not itself deduct points. A point deduction occurs only after the applicable approved policy process/outcome and required authorization.

Case IDs use a company-wide unique sequence such as VP-2026-000001.

## Evidence
One evidence object is displayed once. Capture/upload → thumbnail → submit → compact Evidence 01 [VIEW] row. Do not duplicate full images on the page. Private storage, compressed phone uploads, thumbnails/lazy loading. Wrong finalized evidence is corrected by an audited replacement/correction, not silent overwrite.

## Privacy and security
Privacy by design and least-privilege access. Public GitHub frontend must never contain employee database records, evidence, PINs or confidential HR data. Structured records belong in protected backend/database; evidence/documents use private storage. Enforce scope with database authorization/RLS. Audit important access/changes/actions. PINs/credentials are never stored in plaintext. Use rate limiting/lockout and stronger re-verification for sensitive actions.

## Guidelines & Privacy Center
Permanent ⓘ GUIDELINES & PRIVACY entry accessible from login/menu. Include:
- How V-POINTS works
- starting points/standing
- merit rules
- policy deduction rules
- ACT-001–086 access
- evidence guidance
- review/sign-off/due-process explanation
- rewards/recognition
- privacy: what is collected, purpose, access, scope, retention, security, privacy concerns
- system responsibilities, account security, no self-merit, audit/reversal rules
- policy/guideline version and last-updated date

Contextual ⓘ help appears on Merit and Incident screens.

## Mobile navigation
Every workflow must visibly provide BACK and EXIT/X. BACK returns one step. EXIT warns before discarding unsaved data. No trapped screens and no dependency on browser/phone gesture navigation.

## UX
Phone-first. One screen = one purpose. One attachment = one card. Large thumb-friendly actions. Minimal typing. No horizontal scrolling. No repeated information. Leaderboard remains a central dashboard element.

## Build order
1. Database/schema, RLS/security, immutable audit/ledger foundation
2. Organization/users/login and scope assignments
3. Employee/performance profiles and activation
4. Dashboard/leaderboard
5. Merit submission + Regional/National approval routing
6. Incident/case/evidence workflow based on actual ACT-001–086 source
7. Guidelines & Privacy Center
8. Appraisal evidence/profile views including Executive → NRH appraisal chain
9. Pilot/testing before production migration
