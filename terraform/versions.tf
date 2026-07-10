terraform {
  # HCP Terraform (app.terraform.io): uncomment once the org + workspace exist.
  # Then `terraform login` + `terraform init` — state migrates automatically and
  # local CLI runs stream to the same workspace as VCS-triggered ones.
  # cloud {
  #   organization = "farmer1st"
  #   workspaces { name = "fop-onboarding" }
  # }

  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# The AWS provider initializes even when every AWS resource is gated off, and
# errors if it can't find credentials. While enable_aws=false we feed it inert
# placeholder credentials and skip all validation — zero AWS API calls happen
# because no AWS resources/data sources exist. Flipping enable_aws=true makes
# everything null/false again, restoring the normal credential chain.
provider "aws" {
  region                      = var.aws_region
  access_key                  = var.enable_aws ? null : "gated-off"
  secret_key                  = var.enable_aws ? null : "gated-off"
  skip_credentials_validation = !var.enable_aws
  skip_requesting_account_id  = !var.enable_aws
  skip_metadata_api_check     = !var.enable_aws
}

provider "github" {
  owner = var.github_org
  # auth: GITHUB_TOKEN env var (org-admin fine-grained token or GitHub App)
}

provider "cloudflare" {
  # auth: the CLOUDFLARE_API_TOKEN workspace Terraform variable; when unset
  # (local runs), falls back to the CLOUDFLARE_API_TOKEN environment variable.
  api_token = var.CLOUDFLARE_API_TOKEN
}
