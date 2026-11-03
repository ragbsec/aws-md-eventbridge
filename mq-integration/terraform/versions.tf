terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Remote state in the lab's S3 state bucket. Partial config: scripts/_common.sh
  # (mq_tf_init) supplies bucket/region/key/profile via -backend-config.
  # verify.sh uses `init -backend=false`, so no bucket is needed offline.
  backend "s3" {
    key          = "eventbridge-lab/mq-integration/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}
