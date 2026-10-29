###############################################################################
# platform/ root — multi-region EventBridge platform
#
# Deploys the EventBridge platform in a PRIMARY and SECONDARY region with an
# identically-named custom bus, a multi-region KMS key, and (optionally) an
# EventBridge global endpoint + Route 53 health check for automatic failover.
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

###############################################################################
# Multi-region KMS CMK (primary key in primary region, replica in secondary)
###############################################################################

# The deployer identity administers the CMKs.
data "aws_caller_identity" "deployer" {
  provider = aws.primary
}

# Optional cross-account / org-wide KMS statements, so foreign publishers whose
# accounts/org are trusted on the bus can also use the CMK for their encrypted
# PutEvents. Empty list when sharing is not configured.
locals {
  kms_cross_account_statements = concat(
    length(var.trusted_account_ids) > 0 ? [{
      sid       = "AllowTrustedAccountsKmsUse"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
      resources = ["*"]
      principals = [{
        type        = "AWS"
        identifiers = [for a in var.trusted_account_ids : "arn:aws:iam::${a}:root"]
      }]
      # Least privilege: the trusted account may use this key ONLY via the
      # EventBridge service in these regions — not for arbitrary KMS ops.
      conditions = [{
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["events.${var.primary_region}.amazonaws.com", "events.${var.secondary_region}.amazonaws.com"]
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
          values   = ["events.${var.primary_region}.amazonaws.com", "events.${var.secondary_region}.amazonaws.com"]
        },
      ]
    }] : [],
  )
}

# Auto-load every per-team contract file under schemas_dir into a map the
# platform module registers. Onboarding a new app team = drop a *.json file in
# the schemas/ directory; no code change. The schema NAME is derived from the
# file name: 'order-placed.v1.json' -> 'order-placed.v1', and a '__' in a file
# name becomes '@' so a team can name it 'prod.orders__OrderPlaced.json' ->
# 'prod.orders@OrderPlaced' (the EventBridge source@DetailType convention).
locals {
  _schema_files = var.enable_schema_registry ? fileset("${path.module}/${var.schemas_dir}", "*.json") : []
  schemas = {
    for f in local._schema_files :
    replace(replace(f, ".json", ""), "__", "@") => file("${path.module}/${var.schemas_dir}/${f}")
  }
}


module "kms_primary" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.1"

  providers = { aws = aws.primary }

  description             = "${var.name_prefix} EventBridge platform CMK (primary)"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  multi_region            = true

  # The deployer user administers the key.
  key_administrators = [data.aws_caller_identity.deployer.arn]

  # Grant the AWS services that must use the key for encrypt/decrypt.
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
          "logs.${var.primary_region}.amazonaws.com",
        ]
      }]
    }
  ], local.kms_cross_account_statements)

  aliases = ["${var.name_prefix}/eventbridge"]
  tags    = var.tags
}

module "kms_secondary" {
  source  = "terraform-aws-modules/kms/aws"
  version = "~> 3.1"

  providers = { aws = aws.secondary }

  description     = "${var.name_prefix} EventBridge platform CMK (replica)"
  create_replica  = true
  primary_key_arn = module.kms_primary.key_arn

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
          "logs.${var.secondary_region}.amazonaws.com",
        ]
      }]
    }
  ], local.kms_cross_account_statements)

  aliases = ["${var.name_prefix}/eventbridge"]
  tags    = var.tags
}

###############################################################################
# Platform in each region (same bus name — required for global endpoint)
###############################################################################

module "platform_primary" {
  source = "../modules/eventbridge-platform"

  providers = { aws = aws.primary }

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

module "platform_secondary" {
  source = "../modules/eventbridge-platform"

  providers = { aws = aws.secondary }

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

###############################################################################
# EventBridge global endpoint + Route 53 health check (optional)
###############################################################################

# A real public HTTPS /health target for the Route 53 health check: a Lambda
# Function URL in the PRIMARY region. Its on.aws hostname is public HTTPS with a
# valid cert, so Route 53 can probe it with no custom domain. Flip the function's
# HEALTHY env var to "false" to simulate a primary outage and trigger failover.
module "health_endpoint" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  providers = { aws = aws.primary }

  count = var.enable_global_endpoint ? 1 : 0

  function_name = "${var.name_prefix}-health"
  description   = "Public health endpoint for the EventBridge global-endpoint Route 53 health check"
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 5
  memory_size   = 128

  source_path = "${path.module}/../src/lambda/health"

  create_lambda_function_url = true
  authorization_type         = "NONE"

  environment_variables = {
    HEALTHY = "true"
  }

  tags = var.tags
}

# Route 53 health check watches the primary region's health endpoint. When it
# goes unhealthy, the global endpoint fails custom events over to the secondary.
resource "aws_route53_health_check" "primary" {
  count    = var.enable_global_endpoint ? 1 : 0
  provider = aws.primary
  # Strip scheme + trailing slash from the Function URL to get the bare FQDN.
  fqdn              = replace(replace(module.health_endpoint[0].lambda_function_url, "https://", ""), "/", "")
  port              = 443
  type              = "HTTPS"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = merge(var.tags, { Name = "${var.name_prefix}-primary-health" })
}

resource "aws_cloudwatch_event_endpoint" "global" {
  count    = var.enable_global_endpoint ? 1 : 0
  provider = aws.primary
  name     = "${var.name_prefix}-endpoint"
  role_arn = aws_iam_role.replication[0].arn

  routing_config {
    failover_config {
      primary {
        health_check = aws_route53_health_check.primary[0].arn
      }
      secondary {
        route = var.secondary_region
      }
    }
  }

  replication_config {
    state = "ENABLED"
  }

  event_bus {
    event_bus_arn = module.platform_primary.bus_arn
  }
  event_bus {
    event_bus_arn = module.platform_secondary.bus_arn
  }
}

###############################################################################
# IAM role EventBridge assumes to REPLICATE events between the regional buses.
# Required by the global endpoint whenever replication_config.state = ENABLED.
###############################################################################
data "aws_iam_policy_document" "replication_assume" {
  count = var.enable_global_endpoint ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "replication" {
  count = var.enable_global_endpoint ? 1 : 0

  # Allow replicating (PutEvents) onto both regional buses, and managing the
  # managed rules EventBridge creates for global-endpoint replication.
  statement {
    sid       = "ReplicateEvents"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [module.platform_primary.bus_arn, module.platform_secondary.bus_arn]
  }

  statement {
    sid    = "ManageReplicationRules"
    effect = "Allow"
    actions = [
      "events:PutRule",
      "events:PutTargets",
      "events:DeleteRule",
      "events:RemoveTargets",
      "events:DescribeRule",
      "events:ListTargetsByRule",
    ]
    # The managed replication rules EventBridge creates are not under the custom
    # bus path, so this must cover all rules in both regions for this account.
    resources = [
      "arn:aws:events:${var.primary_region}:${data.aws_caller_identity.deployer.account_id}:rule/*",
      "arn:aws:events:${var.secondary_region}:${data.aws_caller_identity.deployer.account_id}:rule/*",
    ]
  }

  # EventBridge must pass this replication role to the managed rules it creates.
  statement {
    sid       = "PassReplicationRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.deployer.account_id}:role/${var.name_prefix}-endpoint-replication"]
  }

  # Buses are KMS-encrypted, so EventBridge (as this role) must decrypt/encrypt
  # with both regional CMKs to replicate events between them.
  statement {
    sid    = "KmsForReplication"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [module.kms_primary.key_arn, module.kms_secondary.key_arn]
  }
}

resource "aws_iam_role" "replication" {
  count              = var.enable_global_endpoint ? 1 : 0
  provider           = aws.primary
  name               = "${var.name_prefix}-endpoint-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "replication" {
  count    = var.enable_global_endpoint ? 1 : 0
  provider = aws.primary
  name     = "${var.name_prefix}-endpoint-replication"
  role     = aws_iam_role.replication[0].id
  policy   = data.aws_iam_policy_document.replication[0].json
}

# The regional CMKs' key policies grant the events.amazonaws.com SERVICE, but
# global-endpoint replication authorizes against the assumed REPLICATION ROLE.
# A KMS grant on each key authorizes that role to decrypt/encrypt for replication
# without editing the key policy (which would create a key<->role dependency cycle).
resource "aws_kms_grant" "replication_primary" {
  count             = var.enable_global_endpoint ? 1 : 0
  provider          = aws.primary
  name              = "${var.name_prefix}-endpoint-replication-pri"
  key_id            = module.kms_primary.key_arn
  grantee_principal = aws_iam_role.replication[0].arn
  operations        = ["Decrypt", "GenerateDataKey", "DescribeKey"]
}

resource "aws_kms_grant" "replication_secondary" {
  count             = var.enable_global_endpoint ? 1 : 0
  provider          = aws.secondary
  name              = "${var.name_prefix}-endpoint-replication-sec"
  key_id            = module.kms_secondary.key_arn
  grantee_principal = aws_iam_role.replication[0].arn
  operations        = ["Decrypt", "GenerateDataKey", "DescribeKey"]
}

###############################################################################
# DETECTIVE CONTROL: IAM Access Analyzer (flag-gated, account-scoped).
#
# Analyzers are account/region-scoped, so they are created ONCE in the primary
# region (not per-region in the module). Two independent toggles:
#   - external access : flags any resource policy (EventBridge bus, SQS, SNS,
#     KMS, IAM roles) that grants access OUTSIDE the account/org — catches an
#     over-broad cross-account bus policy before it becomes an incident.
#   - unused access   : flags IAM roles/permissions that go unused — catches a
#     producer/consumer role granted more than it needs.
# Findings are emitted as EventBridge events (detail-type "... Finding ..."),
# so they can be routed to the alerting topic or a security bus.
#
# Owned by the EventBridge platform owner: enable/disable via the flags below.
###############################################################################

resource "aws_accessanalyzer_analyzer" "external" {
  count         = var.enable_access_analyzer_external ? 1 : 0
  provider      = aws.primary
  analyzer_name = "${var.name_prefix}-external-access"
  type          = var.access_analyzer_org_scope ? "ORGANIZATION" : "ACCOUNT"
  tags          = var.tags
}

resource "aws_accessanalyzer_analyzer" "unused" {
  count         = var.enable_access_analyzer_unused ? 1 : 0
  provider      = aws.primary
  analyzer_name = "${var.name_prefix}-unused-access"
  type          = var.access_analyzer_org_scope ? "ORGANIZATION_UNUSED_ACCESS" : "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = var.access_analyzer_unused_age_days
    }
  }

  tags = var.tags
}
