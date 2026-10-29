###############################################################################
# platform-global/ root — Option C: the GLOBAL glue layer.
#
# Owns the cross-region resources that inherently span BOTH regions and so
# cannot live in either single-region root:
#   - the EventBridge global endpoint (references BOTH regional bus ARNs)
#   - the Route 53 health check + its public health Lambda (primary region)
#   - the replication IAM role EventBridge assumes (PutEvents on BOTH buses)
#   - the KMS grants authorizing that role on BOTH regional CMKs
#
# Its own state. Applied AFTER both regional roots exist, because it reads
# their bus ARNs and CMK ARNs from their remote state.
#
# Apply order: bootstrap -> platform-primary -> platform-secondary -> [platform-global] -> application
# Destroy FIRST among the platform roots (it depends on both regions).
###############################################################################

provider "aws" {
  # Default provider (primary region). Required because unqualified resources —
  # the IAM policy-document data sources and the lambda module's internal
  # client-side data sources — bind to the default aws provider, which must
  # exist even in a root that otherwise uses only aliases.
  region  = var.primary_region
  profile = var.deployer_profile != "" ? var.deployer_profile : null
  default_tags { tags = var.tags }
}

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

data "aws_caller_identity" "deployer" {
  provider = aws.primary
}

###############################################################################
# Read both regional roots' state for the bus ARNs + CMK ARNs.
###############################################################################
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

data "terraform_remote_state" "secondary" {
  backend = "s3"
  config = {
    bucket       = var.state_bucket
    key          = "eventbridge-lab/platform-secondary/terraform.tfstate"
    region       = var.state_region
    profile      = var.deployer_profile != "" ? var.deployer_profile : null
    use_lockfile = true
  }
}

locals {
  primary_bus_arn   = data.terraform_remote_state.primary.outputs.bus_arn
  secondary_bus_arn = data.terraform_remote_state.secondary.outputs.bus_arn
  primary_kms_arn   = data.terraform_remote_state.primary.outputs.kms_key_arn
  secondary_kms_arn = data.terraform_remote_state.secondary.outputs.kms_key_arn
}

###############################################################################
# Public health endpoint (Lambda Function URL) the Route 53 health check probes.
###############################################################################
module "health_endpoint" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  providers = { aws = aws.primary }

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

resource "aws_route53_health_check" "primary" {
  provider          = aws.primary
  fqdn              = replace(replace(module.health_endpoint.lambda_function_url, "https://", ""), "/", "")
  port              = 443
  type              = "HTTPS"
  resource_path     = "/"
  failure_threshold = 3
  request_interval  = 30

  tags = merge(var.tags, { Name = "${var.name_prefix}-primary-health" })
}

###############################################################################
# IAM role EventBridge assumes to REPLICATE events between the regional buses.
###############################################################################
data "aws_iam_policy_document" "replication_assume" {
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
  statement {
    sid       = "ReplicateEvents"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [local.primary_bus_arn, local.secondary_bus_arn]
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
    resources = [
      "arn:aws:events:${var.primary_region}:${data.aws_caller_identity.deployer.account_id}:rule/*",
      "arn:aws:events:${var.secondary_region}:${data.aws_caller_identity.deployer.account_id}:rule/*",
    ]
  }

  statement {
    sid       = "PassReplicationRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.deployer.account_id}:role/${var.name_prefix}-endpoint-replication"]
  }

  statement {
    sid    = "KmsForReplication"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [local.primary_kms_arn, local.secondary_kms_arn]
  }
}

resource "aws_iam_role" "replication" {
  provider           = aws.primary
  name               = "${var.name_prefix}-endpoint-replication"
  assume_role_policy = data.aws_iam_policy_document.replication_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "replication" {
  provider = aws.primary
  name     = "${var.name_prefix}-endpoint-replication"
  role     = aws_iam_role.replication.id
  policy   = data.aws_iam_policy_document.replication.json
}

# KMS grants authorize the replication ROLE on each regional CMK (the key
# policies grant the events SERVICE; replication authorizes against the role).
resource "aws_kms_grant" "replication_primary" {
  provider          = aws.primary
  name              = "${var.name_prefix}-endpoint-replication-pri"
  key_id            = local.primary_kms_arn
  grantee_principal = aws_iam_role.replication.arn
  operations        = ["Decrypt", "GenerateDataKey", "DescribeKey"]
}

resource "aws_kms_grant" "replication_secondary" {
  provider          = aws.secondary
  name              = "${var.name_prefix}-endpoint-replication-sec"
  key_id            = local.secondary_kms_arn
  grantee_principal = aws_iam_role.replication.arn
  operations        = ["Decrypt", "GenerateDataKey", "DescribeKey"]
}

###############################################################################
# The EventBridge global endpoint — references BOTH regional buses.
###############################################################################
resource "aws_cloudwatch_event_endpoint" "global" {
  provider = aws.primary
  name     = "${var.name_prefix}-endpoint"
  role_arn = aws_iam_role.replication.arn

  routing_config {
    failover_config {
      primary {
        health_check = aws_route53_health_check.primary.arn
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
    event_bus_arn = local.primary_bus_arn
  }
  event_bus {
    event_bus_arn = local.secondary_bus_arn
  }

  # The replication role's policy + the KMS grants must exist before the
  # endpoint create (IAM/KMS propagation); depend on them explicitly.
  depends_on = [
    aws_iam_role_policy.replication,
    aws_kms_grant.replication_primary,
    aws_kms_grant.replication_secondary,
  ]
}
