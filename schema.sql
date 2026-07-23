-- ============================================================
-- MOSAIC — Production schema (Postgres / Supabase)
-- Phase 2 blueprint: every entity the demo keeps in localStorage,
-- normalized, multi-tenant, with row-level security sketches.
-- Apply with: psql -f schema.sql  (or the Supabase SQL editor)
-- ============================================================

create extension if not exists "uuid-ossp";

-- ---------- tenancy & identity ----------
create table orgs (
  id          uuid primary key default uuid_generate_v4(),
  name        text not null,
  domain      text unique not null,
  tagline     text,
  settings    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

-- app users map 1:1 to auth.users in Supabase; role drives RLS
create table app_users (
  id          uuid primary key,                          -- = auth.users.id
  org_id      uuid not null references orgs(id),
  employee_id uuid,                                      -- fk added after employees
  role        text not null default 'employee'
              check (role in ('employee','manager','admin')),
  created_at  timestamptz not null default now()
);

-- ---------- HRIS core ----------
create table departments (
  id      uuid primary key default uuid_generate_v4(),
  org_id  uuid not null references orgs(id),
  key     text not null,            -- 'eng', 'people', ...
  name    text not null,
  color   text,
  unique (org_id, key)
);

create table employees (
  id           uuid primary key default uuid_generate_v4(),
  org_id       uuid not null references orgs(id),
  name         text not null,
  pronouns     text,
  email        citext unique not null,
  phone        text,
  title        text not null,
  level        text not null,       -- IC1..IC6, M1..M3, E
  dept_id      uuid references departments(id),
  team         text,
  manager_id   uuid references employees(id),
  location     text,
  hire_date    date not null,
  last_day     date,
  birthday     text,                -- MM-DD; year never stored
  status       text not null default 'active'
               check (status in ('active','onboarding','offboarding','terminated')),
  employment   text not null default 'FT' check (employment in ('FT','PT','CT')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table app_users
  add constraint app_users_employee_fk foreign key (employee_id) references employees(id);
create index on employees (org_id, status);
create index on employees (manager_id);

-- compensation is its own table: tighter RLS than the profile
create table compensation (
  employee_id  uuid primary key references employees(id) on delete cascade,
  base_cents   bigint not null,
  bonus_pct    numeric(5,2) not null default 0,
  equity_units integer not null default 0,
  currency     text not null default 'USD'
);

create table comp_events (        -- history: hires, merit, promotions
  id           uuid primary key default uuid_generate_v4(),
  employee_id  uuid not null references employees(id) on delete cascade,
  event_date   date not null,
  kind         text not null check (kind in ('hire','merit','promotion','adjustment')),
  base_cents   bigint not null,
  note         text
);

create table comp_bands (
  org_id     uuid not null references orgs(id),
  level      text not null,
  family     text not null check (family in ('tech','core')),
  min_cents  bigint not null, mid_cents bigint not null, max_cents bigint not null,
  primary key (org_id, level, family)
);

create table documents (
  id           uuid primary key default uuid_generate_v4(),
  employee_id  uuid not null references employees(id) on delete cascade,
  name         text not null,
  kind         text not null,          -- Offer / Compliance / Letter / Benefits ...
  storage_path text,                   -- Supabase Storage object
  created_at   timestamptz not null default now()
);

-- ---------- recruiting (ATS) ----------
create table requisitions (
  id            uuid primary key default uuid_generate_v4(),
  org_id        uuid not null references orgs(id),
  ref           text not null,                 -- 'R-104' display id
  title         text not null,
  dept_id       uuid references departments(id),
  team          text,
  level         text,
  location      text,
  hm_id         uuid references employees(id),
  recruiter_id  uuid references employees(id),
  status        text not null default 'open' check (status in ('open','filled','closed')),
  req_type      text,                          -- new headcount / backfill
  salary_min    bigint, salary_max bigint,
  priority      text check (priority in ('low','medium','high')),
  opened_at     date not null default current_date,
  target_date   date,
  filled_at     date,
  unique (org_id, ref)
);

create table candidates (
  id          uuid primary key default uuid_generate_v4(),
  org_id      uuid not null references orgs(id),
  req_id      uuid not null references requisitions(id) on delete cascade,
  name        text not null,
  email       citext,
  phone       text,
  source      text,
  company     text,
  years_exp   int,
  location    text,
  stage       text not null default 'applied'
              check (stage in ('applied','screening','interview','offer','hired','rejected')),
  applied_at  date not null default current_date,
  hired_employee_id uuid references employees(id)
);
create index on candidates (req_id, stage);

create table scorecards (
  id            uuid primary key default uuid_generate_v4(),
  candidate_id  uuid not null references candidates(id) on delete cascade,
  interviewer_id uuid references employees(id),
  dims          jsonb not null,        -- {"Technical":4,...}
  overall       int check (overall between 1 and 5),
  recommendation text,
  notes         text,
  created_at    timestamptz not null default now()
);

create table offers (
  candidate_id uuid primary key references candidates(id) on delete cascade,
  base_cents   bigint not null,
  bonus_pct    numeric(5,2),
  equity_units int,
  start_date   date,
  status       text not null default 'draft'
               check (status in ('draft','extended','accepted','declined')),
  sent_at      date
);

create table candidate_activity (
  id            uuid primary key default uuid_generate_v4(),
  candidate_id  uuid not null references candidates(id) on delete cascade,
  actor         text,
  body          text not null,
  created_at    timestamptz not null default now()
);

-- ---------- approval chains (generic: PTO, offers, comp, ...) ----------
create table approval_chains (
  id           uuid primary key default uuid_generate_v4(),
  org_id       uuid not null references orgs(id),
  subject_type text not null,        -- 'timeoff' | 'offer' | 'merit'
  subject_id   uuid not null,
  created_at   timestamptz not null default now()
);
create table approval_steps (
  id          uuid primary key default uuid_generate_v4(),
  chain_id    uuid not null references approval_chains(id) on delete cascade,
  position    int not null,
  label       text not null,         -- Manager / Finance / CPO
  approver_id uuid references employees(id),
  status      text not null default 'pending' check (status in ('pending','approved','denied')),
  decided_at  timestamptz,
  unique (chain_id, position)
);

-- ---------- journeys (onboarding & offboarding) ----------
create table journey_templates (
  id       uuid primary key default uuid_generate_v4(),
  org_id   uuid not null references orgs(id),
  kind     text not null check (kind in ('onboarding','offboarding')),
  name     text not null,
  tasks    jsonb not null            -- [{title, owner, offset_days, category}]
);

create table journeys (
  id           uuid primary key default uuid_generate_v4(),
  org_id       uuid not null references orgs(id),
  employee_id  uuid not null references employees(id) on delete cascade,
  kind         text not null check (kind in ('onboarding','offboarding')),
  anchor_date  date not null,        -- start date or last day
  reason       text,                 -- offboarding only
  regretted    boolean,
  buddy_id     uuid references employees(id)
);

create table journey_tasks (
  id          uuid primary key default uuid_generate_v4(),
  journey_id  uuid not null references journeys(id) on delete cascade,
  title       text not null,
  owner_role  text not null check (owner_role in ('employee','manager','hr','it')),
  due_date    date,
  category    text,
  done        boolean not null default false,
  done_at     timestamptz
);
create index on journey_tasks (journey_id, done);

-- ---------- learning (LMS) ----------
create table courses (
  id          uuid primary key default uuid_generate_v4(),
  org_id      uuid not null references orgs(id),
  title       text not null,
  category    text,
  minutes     int,
  format      text,
  required_for text,                 -- null | 'all' | 'managers' | dept key
  recert_months int,
  blurb       text,
  rating      numeric(3,2),
  skills      text[]
);

create table enrollments (
  id           uuid primary key default uuid_generate_v4(),
  employee_id  uuid not null references employees(id) on delete cascade,
  course_id    uuid not null references courses(id) on delete cascade,
  assigned_at  date not null default current_date,
  due_date     date,
  progress     int not null default 0 check (progress between 0 and 100),
  completed_at date,
  score        int,
  cert_expires date,
  self_enrolled boolean not null default false,
  unique (employee_id, course_id)
);
create index on enrollments (course_id);
create index on enrollments (employee_id, progress);

-- ---------- performance ----------
create table review_cycles (
  id        uuid primary key default uuid_generate_v4(),
  org_id    uuid not null references orgs(id),
  name      text not null,
  stage     text not null check (stage in ('self','manager','calibration','done')),
  self_due  date, manager_due date,
  opened_at date, closed_at date
);

create table reviews (
  id           uuid primary key default uuid_generate_v4(),
  cycle_id     uuid not null references review_cycles(id) on delete cascade,
  employee_id  uuid not null references employees(id) on delete cascade,
  reviewer_id  uuid references employees(id),
  kind         text not null check (kind in ('self','manager','peer')),
  status       text not null default 'open' check (status in ('open','submitted')),
  rating       int check (rating between 1 and 5),
  potential    text check (potential in ('Low','Medium','High')),
  strengths    text,
  growth       text,
  submitted_at timestamptz
);

create table goals (
  id          uuid primary key default uuid_generate_v4(),
  org_id      uuid not null references orgs(id),
  scope       text not null check (scope in ('company','dept','individual')),
  owner_id    uuid references employees(id),
  parent_id   uuid references goals(id),
  title       text not null,
  description text,
  due_date    date,
  status      text not null default 'on-track'
              check (status in ('on-track','at-risk','behind','done')),
  progress    int not null default 0,
  key_results jsonb not null default '[]'::jsonb
);
create index on goals (parent_id);

create table feedback (
  id         uuid primary key default uuid_generate_v4(),
  org_id     uuid not null references orgs(id),
  from_id    uuid not null references employees(id),
  to_id      uuid not null references employees(id),
  kind       text not null check (kind in ('praise','feedback')),
  visibility text not null default 'public' check (visibility in ('public','private')),
  body       text not null,
  values_tags text[],
  created_at timestamptz not null default now()
);

create table one_on_ones (
  id         uuid primary key default uuid_generate_v4(),
  manager_id uuid not null references employees(id),
  report_id  uuid not null references employees(id),
  scheduled  timestamptz not null,
  recurring  text,
  agenda     jsonb not null default '[]'::jsonb,
  notes      text
);

-- ---------- time off ----------
create table timeoff_requests (
  id           uuid primary key default uuid_generate_v4(),
  employee_id  uuid not null references employees(id) on delete cascade,
  kind         text not null check (kind in ('vacation','sick','parental','bereavement','jury')),
  start_date   date not null,
  end_date     date not null,
  days         numeric(4,1) not null,
  note         text,
  status       text not null default 'pending' check (status in ('pending','approved','denied','cancelled')),
  approver_id  uuid references employees(id),
  decided_at   timestamptz,
  decision_note text,
  created_at   timestamptz not null default now()
);
create index on timeoff_requests (employee_id, status);

create table pto_balances (
  employee_id uuid primary key references employees(id) on delete cascade,
  vac_balance numeric(4,1) not null default 20,
  vac_used    numeric(4,1) not null default 0,
  sick_balance numeric(4,1) not null default 10,
  sick_used   numeric(4,1) not null default 0
);

create table holidays (
  org_id  uuid not null references orgs(id),
  the_day date not null,
  name    text not null,
  primary key (org_id, the_day)
);

-- ---------- benefits ----------
create table benefit_plans (
  id        uuid primary key default uuid_generate_v4(),
  org_id    uuid not null references orgs(id),
  plan_type text not null,            -- Medical / Dental / Vision / Retirement ...
  name      text not null,
  provider  text,
  premium_cents  bigint not null default 0,
  employer_cents bigint not null default 0,
  blurb     text
);

create table benefit_elections (
  employee_id uuid primary key references employees(id) on delete cascade,
  medical_id  uuid references benefit_plans(id),
  dental_id   uuid references benefit_plans(id),
  vision_id   uuid references benefit_plans(id),
  k401_pct    numeric(4,1) not null default 0,
  dependents  int not null default 0,
  updated_at  timestamptz not null default now()
);

create table life_events (
  id          uuid primary key default uuid_generate_v4(),
  employee_id uuid not null references employees(id) on delete cascade,
  kind        text not null,
  event_date  date not null,
  window_ends date not null,
  changes     jsonb not null,
  created_at  timestamptz not null default now()
);

-- ---------- engagement ----------
create table surveys (
  id        uuid primary key default uuid_generate_v4(),
  org_id    uuid not null references orgs(id),
  name      text not null,
  status    text not null check (status in ('draft','live','closed')),
  anonymous boolean not null default true,
  sent_at   date, closes_at date,
  questions jsonb not null default '[]'::jsonb
);

-- responses keep employee_id ONLY for dedupe in a separate table;
-- answers are stored unlinked to preserve anonymity
create table survey_receipts (
  survey_id   uuid not null references surveys(id) on delete cascade,
  employee_id uuid not null references employees(id) on delete cascade,
  primary key (survey_id, employee_id)
);
create table survey_answers (
  id        uuid primary key default uuid_generate_v4(),
  survey_id uuid not null references surveys(id) on delete cascade,
  enps      int,
  drivers   jsonb,
  comment   text,
  theme     text,
  created_at timestamptz not null default now()
);

-- ---------- helpdesk ----------
create table kb_articles (
  id         uuid primary key default uuid_generate_v4(),
  org_id     uuid not null references orgs(id),
  category   text,
  title      text not null,
  body       text not null,
  views      int not null default 0,
  updated_at timestamptz not null default now()
);

create table cases (
  id          uuid primary key default uuid_generate_v4(),
  org_id      uuid not null references orgs(id),
  ref         text not null,          -- 'HD-101'
  employee_id uuid not null references employees(id),
  subject     text not null,
  category    text,
  priority    text check (priority in ('low','medium','high','urgent')),
  status      text not null default 'open' check (status in ('open','waiting','solved')),
  assignee_id uuid references employees(id),
  csat        int check (csat between 1 and 5),
  created_at  timestamptz not null default now(),
  unique (org_id, ref)
);
create table case_messages (
  id        uuid primary key default uuid_generate_v4(),
  case_id   uuid not null references cases(id) on delete cascade,
  author_id uuid references employees(id),
  body      text not null,
  created_at timestamptz not null default now()
);

-- ---------- platform ----------
create table notifications (
  id        uuid primary key default uuid_generate_v4(),
  for_id    uuid not null references employees(id) on delete cascade,
  icon      text, body text not null, link text,
  read      boolean not null default false,
  created_at timestamptz not null default now()
);
create index on notifications (for_id, read);

create table audit_log (
  id        bigserial primary key,
  org_id    uuid not null references orgs(id),
  actor_id  uuid references employees(id),
  action    text not null,
  detail    text,
  created_at timestamptz not null default now()
);

-- ============================================================
-- ROW-LEVEL SECURITY (Supabase) — the demo's canSee()/canSeeComp()
-- expressed as policies. Helper functions first.
-- ============================================================
create or replace function current_employee_id() returns uuid
language sql stable as $$
  select employee_id from app_users where id = auth.uid()
$$;

create or replace function current_role() returns text
language sql stable as $$
  select role from app_users where id = auth.uid()
$$;

-- is `target` somewhere under `mgr` in the reporting tree?
create or replace function in_mgmt_chain(target uuid, mgr uuid) returns boolean
language sql stable as $$
  with recursive chain as (
    select id, manager_id from employees where id = target
    union all
    select e.id, e.manager_id from employees e join chain c on e.id = c.manager_id
  )
  select exists (select 1 from chain where manager_id = mgr)
$$;

alter table employees    enable row level security;
alter table compensation enable row level security;
alter table reviews      enable row level security;
-- (enable on every table; representative policies below)

-- everyone in the org can see the directory
create policy emp_read on employees for select
  using (org_id = (select org_id from app_users where id = auth.uid()));

-- comp: self, management chain, or admin — mirrors canSeeComp()
create policy comp_read on compensation for select using (
  employee_id = current_employee_id()
  or current_role() = 'admin'
  or in_mgmt_chain(employee_id, current_employee_id())
);

-- reviews: subject sees delivered ones; reviewer & admin see their queue
create policy review_read on reviews for select using (
  current_role() = 'admin'
  or reviewer_id = current_employee_id()
  or (employee_id = current_employee_id() and status = 'submitted')
);

-- mutations go through SECURITY DEFINER RPCs (hire_candidate(), etc.)
-- so multi-table workflows stay atomic — see API.md.
