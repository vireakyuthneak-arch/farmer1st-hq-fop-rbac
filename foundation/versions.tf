terraform {
  # Foundation is a SEPARATE state from the onboarding layer (terraform/). It owns
  # the org structure — the things that change rarely and blast wide if wrong. Give
  # it its own HCP workspace (e.g. "fop-foundation", manual apply, dual approval).
  # cloud {
  #   organization = "farmer1st"
  #   workspaces { name = "fop-foundation" }
  # }

  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Foundation runs from the Organization MANAGEMENT account — the only place with
# org powers. Nothing else ever assumes this provider.
#
# While var.offline = true (the default, until a real org account exists) we feed
# placeholder credentials and skip validation so `terraform validate` / `plan`
# run with no real account. Point AWS_ENDPOINT_URL at a local mock (moto) to see
# the plan resolve. Flip offline = false for a real apply.
provider "aws" {
  region                      = var.management_region
  access_key                  = var.offline ? "mock" : null
  secret_key                  = var.offline ? "mock" : null
  skip_credentials_validation = var.offline
  skip_requesting_account_id  = var.offline
  skip_metadata_api_check     = var.offline
}
