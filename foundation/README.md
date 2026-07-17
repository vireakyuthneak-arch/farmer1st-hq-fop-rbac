# foundation/ — the org-structure Terraform layer

**Phase 1** of the FOP cloud plan. This layer owns the things that change rarely
and blast wide if wrong: the **AWS Organization, OUs, member accounts, and SCPs**.
It is a **separate state** from the onboarding layer in [`../terraform`](../terraform)
— give it its own HCP workspace (`fop-foundation`), manual apply, dual approval.

It runs from the **management account** — the only account with org powers. Nothing
else assumes its role.

```
root
├── Security      log-archive, audit
├── Workloads
│   ├── SDLC      sit, staging
│   └── Prod      production
└── Sandbox       sandbox
```

## What it creates

| File | Manages |
|------|---------|
| `organization.tf` | the Organization (feature_set ALL, SCPs enabled) |
| `ous.tf` | the OU tree above |
| `accounts.tf` | one member account per environment/function (guarded with `prevent_destroy`) |
| `scps.tf` | baseline guardrails, region lock, sandbox limits, prod protection + attachments |
| `outputs.tf` | `account_ids` etc. — the bridge into the onboarding layer's `var.account_ids` |

## Validate offline (no AWS account, no credentials)

`var.offline = true` (the default) feeds placeholder creds and skips validation so
the code checks without a real org:

```bash
terraform -chdir=foundation init -backend=false
terraform -chdir=foundation validate
terraform -chdir=foundation fmt -check
```

### See the plan against a local mock (moto)

```bash
# with moto running on :5099 (see ../ tooling) and AWS_ENDPOINT_URL exported:
AWS_ENDPOINT_URL=http://127.0.0.1:5099 \
AWS_ACCESS_KEY_ID=testing AWS_SECRET_ACCESS_KEY=testing AWS_DEFAULT_REGION=ap-southeast-1 \
terraform -chdir=foundation plan -input=false
```

## Going live (later)

1. Create/bootstrap the management account and an admin you can `aws sso login` with.
2. If an org already exists: `terraform import aws_organizations_organization.this o-xxxxxxxxxx`.
3. Set real values in `terraform.tfvars` (unique deliverable root emails) and `offline = false`.
4. Wire the `fop-foundation` HCP workspace; apply with dual approval.
5. Feed `output.account_ids` into the onboarding layer's `var.account_ids`.

> Account creation is asynchronous and rate-limited by AWS — expect the first apply
> to take a few minutes and possibly need re-runs as accounts finish provisioning.
