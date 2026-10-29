###############################################################################
# platform/ root — versions + backend
###############################################################################

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = ">= 6.28"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }

  # ARCHIVED — backend intentionally DISABLED. This root is retired (see
  # docs/legacy/platform/README.md). Do not init/apply it. Restore from here
  # only if you deliberately revert to the single-root layout.
  # backend "s3" {
  #   key          = "eventbridge-lab/platform/terraform.tfstate"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}
