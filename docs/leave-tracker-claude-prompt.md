# Leave Tracker → FOP RBAC — Claude prompt (handoff)

**How to use this file (for the leave-tracker owner):**

1. Get the **D1 database id** from the fop-rbac owner (it's printed by the
   `sync-rbac-d1` GitHub Action, or `wrangler d1 info fop-rbac`).
2. Replace `<FOP_RBAC_D1_DATABASE_ID>` below with it.
3. Open Claude Code in the **leave-tracker** repo and paste everything under
   the line. Review the diff before deploying, as usual.

---

You are working in the **leave-tracker** repo (a Cloudflare Worker: `src/worker.js`
JSON API over D1, static UI in `index.html`, config in `wrangler.jsonc`).

## Goal

Move role management out of this app and into the central **FOP RBAC** system.
FOP RBAC materializes each person's application role into a Cloudflare D1
database named `fop-rbac` that it owns and keeps in sync. This app must **read
that database read-only at runtime** to decide what the signed-in user may do —
so when a role changes centrally, this app picks it up on the next request
**without redeploying**.

Do not change how leave data works. Only identity/authorization changes.

## The RBAC contract

- Database: `fop-rbac`, id `<FOP_RBAC_D1_DATABASE_ID>`. Bind it as `FOP_RBAC_DB`.
- One table:

  ```sql
  app_role (
    email TEXT NOT NULL,   -- lowercased work email (matches the Access JWT email)
    app   TEXT NOT NULL,   -- this app is 'leave-tracker'
    role  TEXT NOT NULL,   -- 'employee' | 'approver' | 'admin'
    kind  TEXT NOT NULL,
    PRIMARY KEY (email, app)
  )
  ```

- Lookup: `SELECT role FROM app_role WHERE email = ?1 AND app = 'leave-tracker'`.
- **Read-only by contract.** Never INSERT/UPDATE/DELETE/CREATE on `FOP_RBAC_DB`.
  fop-rbac's CI is the sole writer. Only ever `SELECT`.
- **Fail closed.** Missing row, unknown role string, or query error ⇒ treat the
  user as `employee` (their own data only). Exception: a single hardcoded
  break-glass admin (below) so an RBAC outage can't lock everyone out.

## Role tiers (replaces today's binary admin/team)

| role | may do |
|---|---|
| `employee` (default) | own balances, own requests, own cancellations — today's `team` behavior |
| `approver` | everything `employee` can, **plus**: approve/reject pending requests, view everyone's log (`GET /api/log` unfiltered), view everyone's balances (`GET /api/summary`) |
| `admin` | everything `approver` can, **plus**: settings (`/api/settings`), public holidays (`/api/holidays*`), employee CRUD (`/api/employees*` writes + full roster read), add leave on another employee's behalf, edit any log entry (`PATCH /api/requests/:id`), delete any entry |

## Changes to make

1. **`wrangler.jsonc`** — add a second D1 binding (keep the existing `DB`):

   ```jsonc
   "d1_databases": [
     { "binding": "DB",          "database_name": "leave-tracker", "database_id": "6c8c4510-6cea-41b2-8329-65c53181103d" },
     { "binding": "FOP_RBAC_DB", "database_name": "fop-rbac",      "database_id": "<FOP_RBAC_D1_DATABASE_ID>" }
   ]
   ```

2. **`src/worker.js` — role source.** Identity stays exactly as-is
   (`identityEmail()` reading `Cf-Access-Authenticated-User-Email`, lowercased,
   with the `DEV_USER_EMAIL` fallback). Replace the role *source*
   (`ADMIN_EMAILS` / `roleForEmail()` / `employees.role`) with:

   ```js
   const RBAC_ROLES = ["employee", "approver", "admin"];
   const BREAKGLASS_ADMINS = ["damon.hase@farmer1st.org"]; // only if FOP_RBAC_DB is unreachable

   async function rbacRole(env, email) {
     if (!email) return "employee";
     try {
       const row = await env.FOP_RBAC_DB
         .prepare(`SELECT role FROM app_role WHERE email = ?1 AND app = 'leave-tracker'`)
         .bind(email).first();
       if (row && RBAC_ROLES.includes(row.role)) return row.role;
     } catch (e) {
       if (BREAKGLASS_ADMINS.includes(email)) return "admin";
     }
     return "employee"; // fail closed
   }
   ```

   In the fetch handler, derive both flags once and use them everywhere:

   ```js
   const role       = await rbacRole(env, user.email);
   const isAdmin    = role === "admin";
   const isApprover = role === "approver" || isAdmin;
   ```

3. **Route gating** — re-gate these routes (everything not listed keeps its
   current gate):
   - `POST /api/requests/:id/approve` and `/reject` → **`isApprover`** (was admin-only).
   - `GET /api/log` (the unfiltered all-employees view + `employeeId` filter) → **`isApprover`**; non-approvers still see only their own rows (current `team` branch).
   - `GET /api/summary` (everyone's balances) → **`isApprover`** (was admin-only).
   - Keep on **`isAdmin`**: `GET/PATCH /api/settings`, all `/api/holidays*`,
     `GET /api/employees`, `POST/PATCH/DELETE /api/employees*`, the
     add-on-behalf branch of `POST /api/requests`, `PATCH /api/requests/:id`,
     and admin-deletes of past-dated entries.
   - `GET /api/me` → return the **RBAC** role (`employee|approver|admin`) so the
     UI adapts from it.

4. **Stop managing roles in this app.**
   - `ensureInit()`: stop seeding/forcing roles (drop the `ADMIN_EMAILS` promote
     step and the `role` values in `SEED_EMPLOYEES` — seed everyone as plain
     records). Keep the `employees` table itself: it still owns names, emails,
     titles, start dates, and anchors `leave_log`. Only its `role` column stops
     mattering; you may leave the column in place (ignored) to avoid a migration.
   - `POST /api/employees` and `PATCH /api/employees/:id`: remove the `role`
     field from input/output (ignore it if sent). Remove the
     "can't remove/delete the last admin" checks — admin-ness no longer lives in
     this DB.
   - **`index.html`**: remove the role picker/editor from the Team page and any
     "Signed in as" role simulation; drive all conditional UI (tabs, approve
     buttons, settings) off `/api/me`'s `role`. Show approver UI (pending queue,
     team balances) when role is `approver` or `admin`; settings/team management
     only for `admin`.

5. **Local dev.** The remote `fop-rbac` D1 isn't available to Miniflare, so for
   local testing create the table in the *local* emulated `FOP_RBAC_DB` and seed
   a few rows, e.g. a `scripts/seed-rbac-local.sql` applied with
   `wrangler d1 execute fop-rbac --local --file scripts/seed-rbac-local.sql`:

   ```sql
   CREATE TABLE IF NOT EXISTS app_role (
     email TEXT NOT NULL, app TEXT NOT NULL, role TEXT NOT NULL, kind TEXT NOT NULL,
     PRIMARY KEY (email, app)
   );
   INSERT OR REPLACE INTO app_role VALUES
     ('norbert@farmer1st.org',       'leave-tracker', 'admin',    'internal-cf'),
     ('damon.hase@farmer1st.org',    'leave-tracker', 'admin',    'internal-cf'),
     ('test.approver@farmer1st.org', 'leave-tracker', 'approver', 'internal-cf'),  -- synthetic: tests the tier
     ('kana.ty@farmer1st.org',       'leave-tracker', 'employee', 'internal-cf');
   ```

## Acceptance tests (verify before deploying)

Using `DEV_USER_EMAIL` to switch identities locally:

1. `norbert@farmer1st.org` and `damon.hase@farmer1st.org` (admins): see Settings +
   Team management; can approve/reject; can add leave on someone's behalf.
2. `test.approver@farmer1st.org` (approver, from the local seed): **can**
   approve/reject and see all logs/balances; **cannot** open Settings, holidays,
   or Team management (403 from the API and hidden in the UI). No one holds this
   tier in production yet, but the gating must work for when someone does.
3. `kana.ty@farmer1st.org` (employee): sees only their own balances/requests;
   approve endpoints return 403.
4. An email with **no row** in `app_role`: behaves as `employee` (fail closed).
5. Break the `FOP_RBAC_DB` binding locally: everyone degrades to `employee`
   except `damon.hase@farmer1st.org`, who still gets `admin` (break-glass).
6. Role data changes in the RBAC DB take effect on the next request **without
   redeploying** (edit a local row and re-request to prove it).

## Do NOT

- Write to `FOP_RBAC_DB` (SELECT only — fop-rbac CI owns the rows).
- Drop or migrate the `employees`/`leave_log`/`holidays`/`settings` tables —
  leave data stays exactly as it is.
- Rename the existing `DB` binding or change business rules (proration,
  auto-approval, balances).
- Cache a role beyond a single request (no cross-request memoization; the
  no-redeploy guarantee depends on fresh reads).
