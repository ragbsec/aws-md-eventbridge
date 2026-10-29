###############################################################################
# application/ root — deploys the producer/consumer app in both regions,
# wiring targets onto the platform layer's rule. Reads the platform layer's
# outputs from its remote state (clean separation: platform and application
# are applied independently).
###############################################################################

provider "aws" {
  alias   = "primary"
  region  = var.primary_region
  profile = var.deployer_profile != "" ? var.deployer_profile : null
  default_tags { tags = var.tags }
}

provider "aws" {
  alias   = "secondary"
  region  = var.secondary_region
  profile = var.deployer_profile != "" ? var.deployer_profile : null
  default_tags { tags = var.tags }
}

# Option C: the platform is split into two independent per-region roots, each
# with its own state. Read BOTH to discover the regional bus/rule/kms
# coordinates. (The global-endpoint glue layer, platform-global, is not read
# here — the application attaches targets to the regional buses directly.)
data "terraform_remote_state" "platform_primary" {
  backend = "s3"
  config = {
    bucket       = var.state_bucket
    key          = "eventbridge-lab/platform-primary/terraform.tfstate"
    region       = var.primary_region
    profile      = var.deployer_profile != "" ? var.deployer_profile : null
    use_lockfile = true
  }
}

data "terraform_remote_state" "platform_secondary" {
  backend = "s3"
  config = {
    bucket       = var.state_bucket
    key          = "eventbridge-lab/platform-secondary/terraform.tfstate"
    region       = var.primary_region
    profile      = var.deployer_profile != "" ? var.deployer_profile : null
    use_lockfile = true
  }
}

locals {
  # Reassemble the {primary, secondary} shape the modules below expect from the
  # two independent roots' `platform` outputs.
  platform = {
    primary   = data.terraform_remote_state.platform_primary.outputs.platform
    secondary = data.terraform_remote_state.platform_secondary.outputs.platform
  }
  lambda_source_dir = "${path.module}/../src/lambda"
}

###############################################################################
# Application in the PRIMARY region
###############################################################################

module "app_primary" {
  source = "../modules/event-application"

  providers = { aws = aws.primary }

  name_prefix           = "${var.name_prefix}-pri"
  bus_name              = local.platform.primary.bus_name
  bus_arn               = local.platform.primary.bus_arn
  failover_bus_arns     = [local.platform.secondary.bus_arn]
  failover_kms_key_arns = [local.platform.secondary.kms_key_arn]
  rule_name             = local.platform.primary.rule_name
  rule_arn              = local.platform.primary.rule_arn
  audit_log_group_arn   = local.platform.primary.audit_log_arn
  alerts_topic_arn      = local.platform.primary.alerts_topic
  event_source          = var.event_source
  kms_key_arn           = local.platform.primary.kms_key_arn
  lambda_source_dir     = local.lambda_source_dir
  lambda_memory_mb      = var.lambda_memory_mb
  log_retention_days    = var.log_retention_days
  tags                  = var.tags
}

###############################################################################
# Application in the SECONDARY region
###############################################################################

module "app_secondary" {
  source = "../modules/event-application"

  providers = { aws = aws.secondary }

  name_prefix           = "${var.name_prefix}-sec"
  bus_name              = local.platform.secondary.bus_name
  bus_arn               = local.platform.secondary.bus_arn
  failover_bus_arns     = [local.platform.primary.bus_arn]
  failover_kms_key_arns = [local.platform.primary.kms_key_arn]
  rule_name             = local.platform.secondary.rule_name
  rule_arn              = local.platform.secondary.rule_arn
  audit_log_group_arn   = local.platform.secondary.audit_log_arn
  alerts_topic_arn      = local.platform.secondary.alerts_topic
  event_source          = var.event_source
  kms_key_arn           = local.platform.secondary.kms_key_arn
  lambda_source_dir     = local.lambda_source_dir
  lambda_memory_mb      = var.lambda_memory_mb
  log_retention_days    = var.log_retention_days
  tags                  = var.tags
}
