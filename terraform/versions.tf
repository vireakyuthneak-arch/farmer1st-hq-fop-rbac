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

provider "aws" {
  region = var.aws_region
}

provider "github" {
  owner = var.github_org
  # auth: GITHUB_TOKEN env var (org-admin fine-grained token or GitHub App)
}

provider "cloudflare" {
  # auth: CLOUDFLARE_API_TOKEN env var (scoped token, never the Global API Key)
}
