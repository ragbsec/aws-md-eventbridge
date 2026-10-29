###############################################################################
# Bootstrap layer — pinned versions
#
# This layer is applied ONCE by the privileged operator (cloud_user). It creates
# the remote-state backend (S3 + DynamoDB lock) and a dedicated, least-privilege
# IAM deployer user. Its OWN state is kept locally (terraform.tfstate) and then
# mirrored into S3 by the create script, because you cannot store a backend's
# state in the very bucket the same apply is creating.
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
  }
}
