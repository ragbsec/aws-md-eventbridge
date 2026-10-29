###############################################################################
# platform-secondary/ root — versions + backend
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
    key          = "eventbridge-lab/platform-secondary/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket, region, profile supplied via -backend-config=backend.hcl
  }
}
