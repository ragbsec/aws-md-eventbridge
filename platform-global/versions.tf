###############################################################################
# platform-global/ root — versions + backend
#
# Two-region glue root: needs BOTH provider aliases (the secondary KMS grant is
# a secondary-region resource). Its own state key.
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
    key          = "eventbridge-lab/platform-global/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket, region, profile supplied via -backend-config=backend.hcl
  }
}
