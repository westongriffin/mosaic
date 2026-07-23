# Mosaic — Phase 2 Blueprint: from single file to real stack

The demo app keeps every record in one `DB` object persisted to localStorage, and **every read/write already flows through one seam** (`Store` + the `ACT` action registry). Phase 2 swaps that seam for a real backend without rewriting the views.

## Target architecture

```
Browser (the existing UI, ported to React or kept as-is initially)
   │  HTTPS / supabase-js
   ▼
Supabase project
   ├─ Postgres (schema.sql — all tables + RLS policies)
   ├─ Auth (email/SSO; app_users.role drives row-level security)
   ├─ Storage (generated PDFs, uploaded docs)
   ├─ RPCs (SECURITY DEFINER functions for multi-table workflows)
   └─ Realtime (notifications, inbox badges)
```

Why Supabase: Postgres + auth + storage + realtime with a generous free tier, no server to run, and RLS means the demo's permission model (`canSee`, `canSeeComp`) becomes *database-enforced* instead of UI-enforced.

## The migration path (in order)

1. **Create accounts** — Supabase project + GitHub repo. *(Only step Claude can't do for you.)*
2. **Apply `schema.sql`** in the Supabase SQL editor.
3. **Seed script** — port `buildSeed()` to a Node script that inserts the same fictional world (the demo already proves the data shapes).
4. **Adapter swap** — implement `RemoteStore` with the same surface the views use today:
   - `DB.employees` reads → `from('employees').select(...)` (cached in memory, invalidated by Realtime)
   - every `ACT.*` mutation → one RPC or table write (map below)
   - `Store.save()` → no-op (writes are per-action now)
5. **Auth** — replace the persona switcher with real sign-in; keep the switcher in "demo mode" builds.
6. **Move workflows server-side** — the golden threads become `SECURITY DEFINER` RPCs so they're atomic:
   - `hire_candidate(candidate_id, overrides)` → employee + journey + enrollments + goals + benefits shell + req close, in one transaction
   - `start_offboarding(employee_id, last_day, reason, regret)`
   - `promote(employee_id, new_level, new_title, new_base, effective)`
   - `decide_timeoff(request_id, decision)` / `advance_chain(chain_id)`
   - `process_life_event(kind, event_date, changes)`
7. **PDFs** — keep the in-browser generator (it's dependency-free) but store outputs in Supabase Storage and log them in `documents`.
8. **Ask Mosaic** — swap the rule-based engine for the Claude API behind a thin edge function (`/assist` with tool-use over the same RPCs). The chip UI doesn't change.

## Endpoint / action map

| Demo action (`ACT.*`)        | Production call |
|------------------------------|-----------------|
| directory, profiles          | `select` on `employees` (+ joins), RLS-filtered |
| `confirmHire`                | `rpc('hire_candidate', …)` |
| `moveCand` / `rejectCand`    | `update candidates set stage…` + `candidate_activity` insert |
| `sendOffer` / `approveOfferStep` | `offers` update + `approval_steps` update via `rpc('advance_chain')` |
| `submitTimeReq`              | `insert timeoff_requests` (+ chain rows when days > 5) |
| `decideTO`                   | `rpc('decide_timeoff')` — updates balances atomically |
| `toggleObTask`/`toggleOffbTask` | `update journey_tasks`; trigger flips employee status when all done |
| `confirmPromote`             | `rpc('promote')` |
| `enrollCourse`/`continueCourse` | `enrollments` upsert; trigger issues cert rows |
| `submitReview`               | `update reviews` |
| `submitPraise`               | `insert feedback` (+ notification via trigger) |
| `openSurvey`/`submitSurvey`  | `survey_receipts` insert + `survey_answers` insert (unlinked — anonymity preserved) |
| `submitCase`/`replyCase`/`solveCase` | `cases` + `case_messages` |
| `lifeSubmit`                 | `rpc('process_life_event')` |
| flight risk, insights        | SQL views / materialized views (`mv_headcount_monthly`, `mv_attrition`, `v_flight_signals`) |
| `exportData`                 | `pg_dump` or per-org export edge function |

## Multi-tenancy

Every table carries `org_id`; every policy starts from `app_users.org_id`. One deployment serves many companies — Meridian Labs becomes seed tenant #1.

## What stays exactly the same

The design system, the views, the module structure, the golden-thread UX, the receipts modals, the PDF engine, the seeded demo world (as a "demo org"). That was the point of the Store seam.
