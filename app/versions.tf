###############################################################################
# App layer — pinned versions + S3 remote backend
#
# The backend is PARTIAL on purpose: the bucket / region / profile are injected
# at `terraform init` time via `-backend-config=backend.hcl`, which the create
# script renders from the bootstrap layer's outputs. This lets the same code
# point at a freshly-created bucket OR an existing one you already own. State
# locking is S3-NATIVE (use_lockfile), so no DynamoDB table is needed (requires
# AWS provider >= 6.28, which the eventbridge module v4.3.2 also requires).
###############################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    key          = "eventbridge-lab/app/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket, region, profile supplied via -backend-config=backend.hcl
  }
}
