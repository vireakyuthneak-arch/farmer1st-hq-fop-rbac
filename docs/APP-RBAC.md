# App RBAC ↔ the `fop-rbac` KV namespace (consumer contract)

How internal applications (roadmap, leave-tracker, …) consume per-user roles
from FOP instead of managing their own users. Peer of
[ABRA-CONTRACT.md](ABRA-CONTRACT.md): this page is the complete interface — an
app that follows it needs nothing else from this repo.

## The pipeline

```
profiles/ (roles' appRoles + applications.yml registry)
    │  terraform apply (HCP, on merge — plan diff shows every access change)
    ▼
Cloudflare KV namespace "fop-rbac"  ──read-only binding──▶  your Worker
```

- **Registry** ([`profiles/applications.yml`](../profiles/applications.yml)):
  every app, its `kind` (`internal-cf` = enforced here | `external` = recorded
  only), and its ORDERED role vocabulary (weakest → strongest).
- **Grants**: role files carry `appRoles: {<app-id>: <role>}`. A user holding
  several FOP roles gets the **strongest** role per app; a registry
  `defaultRole` is the floor every user receives.
- **Materialization**: Terraform writes one KV document per user and deletes
  it on offboarding — absence IS the revocation signal. No tombstones.

## The document

Key: `user:<email>` — email **lowercased**. All other key shapes are reserved
by FOP; future key classes are additive.

```json
{
  "schema": "fop.rbac/v1",
  "user": "vireakyuth",
  "email": "vireakyuth.neak@farmer1st.org",
  "roles": ["backend-engineer", "devops-engineer"],
  "apps":     { "roadmap": { "role": "editor" }, "leave-tracker": { "role": "employee" } },
  "external": { "slack": { "role": "member" } }
}
```

- `apps.<app-id>.role` — the ONLY authorization input for your app.
- `roles[]` — provenance/debugging only. Org role names refactor freely;
  coupling to them is the anti-pattern per-app vocabularies exist to kill.
- `external.*` — declared, **not enforced by FOP** (a human configures the
  target system to match). NEVER an authorization input.
- No timestamps by design: a document changes iff the person's entitlements
  change, so Terraform plan diffs read as access diffs. A month-old doc is a
  valid doc.

## The reference read (this is the whole integration)

```js
// wrangler.toml / wrangler.jsonc: bind the namespace READ-ONLY as FOP_RBAC
// (namespace id = terraform output `app_rbac_namespace_id`)
const email = accessJwt.email.toLowerCase();   // from the VERIFIED Cf-Access-Jwt-Assertion
const doc   = await env.FOP_RBAC.get(`user:${email}`, { type: "json", cacheTtl: 60 });
const role  = doc?.schema === "fop.rbac/v1" ? doc?.apps?.["<your-app-id>"]?.role : undefined;
if (!role) return deny();                      // fail closed on EVERY branch
```

## The MUSTs (fail-open is the one unforgivable bug)

1. **Identity comes from the verified Cloudflare Access JWT** — signature and
   audience checked, email lowercased. Never a client-supplied header, cookie,
   or query parameter.
2. **Missing key = NO ACCESS.** Not an error fallback, not a default role.
3. **Your app id absent under `apps` = NO ACCESS.** Defaults are already
   resolved into the doc — no default logic in consumers.
4. **Unknown role string = NO ACCESS** (lets vocabularies grow without
   breaking you). Unknown *fields*: ignore — never strict-parse.
5. **Wrong/unknown `schema` = NO ACCESS.** Accept exactly `fop.rbac/v1`;
   breaking changes ship as a parallel v2 namespace, never in-place.
6. **KV exception / JSON parse failure = deny** (403/503). Every error path
   fails closed.
7. **`external` is never an authorization input.**
8. **Caching:** `cacheTtl` ≤ 60; no memoization beyond one request; never copy
   docs into your app's own storage. This bounds revocation at
   apply + ~2 minutes (KV edge ≤60s + cache ≤60s).
9. **Read-only:** exact-key `get` of your caller's `user:<email>` only. Never
   `put`/`delete`/`list` (Terraform drift detection will revert you and the
   audit log will name you).

### Conformance checklist (test before you get the binding)

| Case | Expected |
|---|---|
| Key missing | deny |
| Malformed JSON | deny |
| `schema: "something-else"` | deny |
| KV binding throws | deny |
| Email from a spoofed header (not the JWT) | request rejected before lookup |

## Onboarding a new app (zero FOP code changes)

1. PR to this repo: one entry in `profiles/applications.yml`
   (`kind: internal-cf`, ordered `roles`) + `appRoles` lines in the granting
   roles. The HCP plan shows every user-doc diff before merge.
2. After apply: bind the namespace (id from the `app_rbac_namespace_id`
   output) read-only as `FOP_RBAC` in your wrangler config.
3. Implement the reference read + pass the conformance checklist.

Vocabulary changes: appending a role is safe (consumers deny unknown values);
renaming/removing hard-fails validation on every stale grant, forcing one
atomic PR.

## Operational notes

- Namespace `fop-rbac` carries `prevent_destroy` — recreating it changes the
  id and breaks every binding (fleet-wide deny, by design fail-closed).
  Recreation is a coordinated event.
- Writes ride a dedicated KV-only Cloudflare token (`CLOUDFLARE_KV_API_TOKEN`
  HCP variable) — the Access/members token cannot touch KV and vice versa.
- Email changes self-heal: apps key off the Access JWT email; Terraform
  deletes the old key and writes the new one in the same apply.
