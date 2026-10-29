###############################################################################
# platform-primary/ root — versions + backend
#
# Single-region root: ONE default aws provider (no primary/secondary aliases).
# Its own state key keeps it independent of platform-secondary / platform-global.
###############################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
  }

  backend "s3" {
    key          = "eventbridge-lab/platform-primary/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket, region, profile supplied via -backend-config=backend.hcl
  }
}
