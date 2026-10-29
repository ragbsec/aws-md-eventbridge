###############################################################################
# platform-primary/ root — Option C: PRIMARY-region EventBridge platform.
#
# Owns the multi-region KMS PRIMARY key and the primary-region bus / rules /
# archive / logging / monitoring / schemas. This root has its OWN state, so it
# is applied and destroyed independently of the secondary region and of the
# global-endpoint glue layer.
#
# Apply order (Option C):
#   bootstrap -> platform-primary -> platform-secondary -> platform-global -> application
#
# Downstream roots read this root's outputs via terraform_remote_state:
#   - platform-secondary reads kms_key_arn (to create the KMS REPLICA)
#   - platform-global     reads bus_arn + kms_key_arn (endpoint + replication)
#   - application         reads the primary coordinates
###############################################################################

provider "aws" {
  region  = var.region
  profile = var.deployer_profile != "" ? var.deployer_profile : null
  default_tags { tags = var.tags }
}

data "aws_caller_identity" "deployer" {}

# Auto-load every per-team contract file under schemas_dir into a map the
# platform module registers. Onboarding a new app team = drop a *.json file in
# the schemas/ directory; no code change. '__' in a file name becomes '@'
# (the EventBridge source@DetailType convention).
locals {
  _schema_files = var.enable_schema_registry ? fileset("${path.module}/${var.schemas_dir}", "*.json") : []
  schemas = {
    for f in local._schema_files :
    replace(replace(f, ".json", ""), "__", "@") => file("${path.module}/${var.schemas_dir}/${f}")
  }

  # Optional cross-account / org-wide KMS statements, so foreign publishers
  # whose accounts/org are trusted on the bus can also use the CMK for their
  # encrypted PutEvents. Empty when sharing is not configured. Least privilege:
  # usable ONLY via the EventBridge service in the two platform regions.
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
        values   = ["events.${var.region}.amazonaws.com", "events.${var.secondary_region}.amazonaws.com"]
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
          values   = ["events.${var.region}.amazonaws.com", "events.${var.secondary_region}.amazonaws.com"]
        },
      ]
    }] : [],
  )
}

###############################################################################
# Multi-region KMS CMK — PRIMARY key (its replica lives in platform-secondary).
###############################################################################
module "kms_primary" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.1"

  description             = "${var.name_prefix} EventBridge platform CMK (primary)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  multi_region            = true

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
# Primary-region platform (bus / rule / archive / logging / monitoring).
###############################################################################
module "platform" {
  source = "../modules/eventbridge-platform"

  name_prefix              = "${var.name_prefix}-pri"
  bus_name                 = var.bus_name
  event_source             = var.event_source
  kms_key_arn              = module.kms_primary.key_arn
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

###############################################################################
# DETECTIVE CONTROL: IAM Access Analyzer (flag-gated, account-scoped).
#
# Analyzers are account-scoped and created ONCE. In Option C they live in the
# PRIMARY root (the first-applied platform layer). Two independent toggles:
#   external access  — flags resource policies granting access outside the org.
#   unused access    — flags unused IAM roles/permissions.
# Owned by the EventBridge platform owner via the flags below.
###############################################################################
resource "aws_accessanalyzer_analyzer" "external" {
  count         = var.enable_access_analyzer_external ? 1 : 0
  analyzer_name = "${var.name_prefix}-external-access"
  type          = var.access_analyzer_org_scope ? "ORGANIZATION" : "ACCOUNT"
  tags          = var.tags
}

resource "aws_accessanalyzer_analyzer" "unused" {
  count         = var.enable_access_analyzer_unused ? 1 : 0
  analyzer_name = "${var.name_prefix}-unused-access"
  type          = var.access_analyzer_org_scope ? "ORGANIZATION_UNUSED_ACCESS" : "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = var.access_analyzer_unused_age_days
    }
  }

  tags = var.tags
}
