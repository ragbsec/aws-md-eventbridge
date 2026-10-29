###############################################################################
# application/ root — versions + backend
###############################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.28"
      configuration_aliases = [aws.primary, aws.secondary]
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  backend "s3" {
    key          = "eventbridge-lab/application/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
    # bucket, region, profile supplied via -backend-config=backend.hcl
  }
}
