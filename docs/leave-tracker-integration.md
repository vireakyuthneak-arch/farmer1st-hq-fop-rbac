# Leave Tracker → FOP RBAC integration (handoff)

**For:** whoever owns the `leave-tracker` repo.
**Goal:** stop managing roles inside the Leave Tracker. Roles now come from the
central **FOP RBAC** system, materialized into a **Cloudflare D1 database that
fop-rbac owns**. The Leave Tracker **reads it read-only** at runtime, so **role
changes never require a redeploy** — when someone's role changes in fop-rbac, CI
re-syncs the D1 and your next request sees the new role.

You do **not** manage the RBAC D1, its schema, or its rows. fop-rbac does. You
only *read* it.

---

## What fop-rbac gives you

A D1 database named **`fop-rbac`** with one table:

```sql
CREATE TABLE app_role (
  email TEXT NOT NULL,   -- lowercased work email (matches the Access JWT email)
  app   TEXT NOT NULL,   -- e.g. 'leave-tracker'
  role  TEXT NOT NULL,   -- for leave-tracker: 'employee' | 'approver' | 'admin'
  kind  TEXT NOT NULL,
  PRIMARY KEY (email, app)
);
```

The Leave Tracker's role vocabulary is **`employee < approver < admin`**:

| RBAC role | Can do | (was)  |
|-----------|--------|--------|
| `employee` (default) | own balances + own requests | `team` |
| `approver` | **+ approve/reject requests, see all logs & balances** | *(new tier)* |
| `admin` | + settings, public holidays, member management, add-on-behalf | `admin` |

The database id to bind is the fop-rbac Terraform output **`app_rbac_d1_database_id`**
(ask the fop-rbac owner for it).

---

## The changes to make

### 1. Bind the RBAC D1 (read-only by contract)

`wrangler.jsonc` — add a **second** `d1_databases` entry (keep your existing `DB`):

```jsonc
"d1_databases": [
  { "binding": "DB",          "database_name": "leave-tracker", "database_id": "6c8c4510-…" },
  { "binding": "FOP_RBAC_DB", "database_name": "fop-rbac",      "database_id": "<app_rbac_d1_database_id>" }
]
```

> Read-only is a **contract**, not a platform lock: a D1 binding *can* write.
> Only ever `SELECT` from `FOP_RBAC_DB`. Never INSERT/UPDATE/DELETE/CREATE there —
> fop-rbac's CI is the sole writer.

### 2. Read the role from RBAC instead of your own DB

Identity is already correct — keep `identityEmail()` (the `Cf-Access-Authenticated-User-Email`
header, lowercased). Replace the **role source** (`roleForEmail`, `ADMIN_EMAILS`,
and `employees.role` for authorization) with a lookup against `FOP_RBAC_DB`:

```js
const RBAC_ROLES = ["employee", "approver", "admin"];
const BREAKGLASS_ADMINS = ["damon.hase@farmer1st.org"]; // fallback if RBAC is unreachable

async function rbacRole(env, email) {
  if (!email) return "employee";
  try {
    const row = await env.FOP_RBAC_DB
      .prepare(`SELECT role FROM app_role WHERE email = ?1 AND app = 'leave-tracker'`)
      .bind(email).first();
    const role = row?.role;
    if (RBAC_ROLES.includes(role)) return role;              // trust only known roles
  } catch (e) {
    if (BREAKGLASS_ADMINS.includes(email)) return "admin";   // never lock admins out
  }
  return "employee";                                         // fail closed
}
```

Then in the request handler, replace the single admin check:

```js
const role       = await rbacRole(env, user.email);
const isAdmin    = role === "admin";
const isApprover = role === "approver" || isAdmin;
```

### 3. Apply the approver tier

- **Approve / reject** (`POST /api/requests/:id/approve|reject`): gate on **`isApprover`**, not `isAdmin`.
- **Seeing everyone's data to make approval decisions** — `GET /api/log` (all), `GET /api/summary` (all balances), the pending queue: allow **`isApprover`**.
- **Everything else stays admin-only**: `PATCH/GET /api/settings`, `/api/holidays`, all
  `/api/employees` writes, add-leave-on-behalf. Keep those on `isAdmin`.
- **`employee`** keeps today's `team` behavior (own data + own requests).

### 4. Stop managing roles in the app

- Remove the **Team page role editor** and the `role` field from the create/edit
  employee endpoints — roles are managed in fop-rbac now (via PR), not here.
- The `employees` table **stays** — it still holds names, start dates, emails,
  titles, and drives balances. Just don't use its `role` column for authorization.
- You can drop the `ADMIN_EMAILS` bootstrap **except** the single break-glass entry
  above (kept only for the "RBAC unreachable" fallback).

---

## Why no redeploy on role changes

`FOP_RBAC_DB` is read at request time. When a role changes in fop-rbac, its CI
re-runs the sync (`wrangler d1 execute` against the `fop-rbac` D1) and the rows
update. Your Worker reads the new value on the very next request — no build, no
deploy, no restart.

---

## Test it

Local dev uses `DEV_USER_EMAIL`. Point your local `FOP_RBAC_DB` at a seeded local
D1 (or the remote one) and verify:

1. `norbert@farmer1st.org` and `damon.hase@farmer1st.org` → full admin: Settings,
   team management, approve/reject (both hold `admin`).
2. The `approver` tier has no holders yet — verify its gating with a locally
   seeded row (can approve/see all, cannot open Settings), so future approvers
   work without app changes.
3. Anyone else → sees **only their own** balances and requests (employee).
4. Simulate `FOP_RBAC_DB` failing → non-break-glass users degrade to `employee`
   (fail closed); the break-glass admin still gets in.

---

## Not your job (handled in fop-rbac)

- The D1 database, its schema, and every row (synced from the Profiles).
- Who is `employee` / `approver` / `admin` — changed by editing roles in fop-rbac.
- Adding a new admin/approver — a fop-rbac PR, not a Team-page click.
