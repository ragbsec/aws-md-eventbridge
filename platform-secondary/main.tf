###############################################################################
# platform-secondary/ root — Option C: SECONDARY-region EventBridge platform.
#
# Owns the KMS REPLICA of the primary multi-region key and the secondary-region
# bus / rules / archive / logging / monitoring / schemas. Its own state.
#
# DEPENDS ON platform-primary: it reads the primary CMK ARN from the primary
# root's remote state to create the replica (create_replica + primary_key_arn).
# This is the ONLY cross-root coupling — a deploy-time read of one ARN, not
# runtime access. Primary's runtime (bus, consumers) can be fully down while
# this region runs; the replica shares key material so it decrypts primary-
# origin events locally with no cross-region KMS call (zero-downtime failover).
#
# Apply order: bootstrap -> platform-primary -> [platform-secondary] -> platform-global -> application
###############################################################################

provider "aws" {
  region  = var.region
  profile = var.deployer_profile != "" ? var.deployer_profile : null
  default_tags { tags = var.tags }
}

data "aws_caller_identity" "deployer" {}

# Read the PRIMARY root's outputs for the multi-region key's primary ARN.
data "terraform_remote_state" "primary" {
  backend = "s3"
  config = {
    bucket       = var.state_bucket
    key          = "eventbridge-lab/platform-primary/terraform.tfstate"
    region       = var.state_region
    profile      = var.deployer_profile != "" ? var.deployer_profile : null
    use_lockfile = true
  }
}

locals {
  primary_kms_key_arn = data.terraform_remote_state.primary.outputs.kms_key_arn
  primary_region      = data.terraform_remote_state.primary.outputs.region

  _schema_files = var.enable_schema_registry ? fileset("${path.module}/${var.schemas_dir}", "*.json") : []
  schemas = {
    for f in local._schema_files :
    replace(replace(f, ".json", ""), "__", "@") => file("${path.module}/${var.schemas_dir}/${f}")
  }

  # Cross-account / org KMS statements, scoped via kms:ViaService to BOTH
  # platform regions (kept identical to the primary root for symmetric sharing).
  kms_cross_account_statements = concat(
    length(var.trusted_account_ids) > 0 ? [{
      sid       = "AllowTrustedAccountsKmsUse"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = ["*"]
      principals = [{
        type        = "AWS"
        identifiers = [for a in var.trusted_account_ids : "arn:aws:iam::${a}:root"]
      }]
      conditions = [{
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["events.${local.primary_region}.amazonaws.com", "events.${var.region}.amazonaws.com"]
      }]
    }] : [],
    var.organization_id != "" ? [{
      sid       = "AllowOrgKmsUse"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = ["*"]
      principals = [{
        type        = "AWS"
        identifiers = ["*"]
      }]
      conditions = [
        {
          test     = "StringEquals"
          variable = "aws:PrincipalOrgID"
          values   = [var.organization_id]
        },
        {
          test     = "StringEquals"
          variable = "kms:ViaService"
          values   = ["events.${local.primary_region}.amazonaws.com", "events.${var.region}.amazonaws.com"]
        },
      ]
    }] : [],
  )
}

###############################################################################
# Multi-region KMS CMK — REPLICA of the primary key (shared key material).
###############################################################################
module "kms_secondary" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.1"

  description     = "${var.name_prefix} EventBridge platform CMK (replica)"
  create_replica  = true
  primary_key_arn = local.primary_kms_key_arn

  key_administrators = [data.aws_caller_identity.deployer.arn]

  key_statements = concat([
    {
      sid       = "AllowServiceUse"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
      resources = ["*"]
      principals = [{
        type = "Service"
        identifiers = [
          "events.amazonaws.com",
          "sns.amazonaws.com",
          "sqs.amazonaws.com",
          "lambda.amazonaws.com",
          "logs.${var.region}.amazonaws.com",
        ]
      }]
    }
  ], local.kms_cross_account_statements)

  aliases = ["${var.name_prefix}/eventbridge"]
  tags    = var.tags
}

###############################################################################
# Secondary-region platform (bus / rule / archive / logging / monitoring).
###############################################################################
module "platform" {
  source = "../modules/eventbridge-platform"

  name_prefix              = "${var.name_prefix}-sec"
  bus_name                 = var.bus_name
  event_source             = var.event_source
  kms_key_arn              = module.kms_secondary.key_arn
  log_retention_days       = var.log_retention_days
  archive_retention_days   = var.archive_retention_days
  alert_email              = var.alert_email
  trusted_account_ids      = var.trusted_account_ids
  organization_id          = var.organization_id
  forward_to_bus_arns      = var.forward_to_bus_arns
  enable_schema_registry   = var.enable_schema_registry
  enable_schema_discoverer = var.enable_schema_discoverer
  schemas                  = local.schemas
  enable_scheduler         = var.enable_scheduler
  schedule_expression      = var.schedule_expression
  schedule_target_arn      = var.schedule_target_arn
  enable_pipe              = var.enable_pipe
  pipe_source_arn          = var.pipe_source_arn
  tags                     = var.tags
}
