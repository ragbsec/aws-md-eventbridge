###############################################################################
# App layer — EventBridge reference lab
#
# Flow proven end to end:
#
#   [Scheduler]                                   +--> [Consumer Lambda] --(fail)--> [SQS DLQ]
#       |  rate(5m)                                |
#       v                                          +--> [CloudWatch Logs] (audit trail)
#   [Producer Lambda] --put_events--> [Custom Bus] --rule(pattern)-->
#       ^  (also on-demand)                        +--> [SNS Topic] (fan-out / notifications)
#                                                  |
#                                     [Archive] <--+  (replayable event store)
#
# Every arrow is a "critical function" of EventBridge: custom bus, content-based
# rule matching, multiple target types, DLQ, archive/replay, and Scheduler.
###############################################################################

provider "aws" {
  region  = var.region
  profile = var.deployer_profile

  default_tags {
    tags = var.tags
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id

  producer_name = "${var.name_prefix}-producer"
  consumer_name = "${var.name_prefix}-consumer"
}

###############################################################################
# Package the Lambda source into deployment zips
###############################################################################

data "archive_file" "producer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/producer"
  output_path = "${path.module}/.build/producer.zip"
}

data "archive_file" "consumer" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/consumer"
  output_path = "${path.module}/.build/consumer.zip"
}

###############################################################################
# Dead-letter queue for undeliverable / failed events
###############################################################################

module "dlq" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "~> 4.2"

  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

###############################################################################
# SNS topic — a second target type (fan-out / notifications)
###############################################################################

module "sns" {
  source  = "terraform-aws-modules/sns/aws"
  version = "~> 6.1"

  name = "${var.name_prefix}-notifications"

  tags = var.tags
}

###############################################################################
# CloudWatch Log group — an audit-trail target for every matched event
###############################################################################

resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/events/${var.name_prefix}/audit"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# EventBridge must be allowed to write to the audit log group.
data "aws_iam_policy_document" "audit_log_resource_policy" {
  statement {
    sid    = "AllowEventBridgeToLog"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.audit.arn}:*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "audit" {
  policy_name     = "${var.name_prefix}-audit-eb"
  policy_document = data.aws_iam_policy_document.audit_log_resource_policy.json
}

###############################################################################
# Producer Lambda — publishes OrderPlaced events onto the bus
###############################################################################

module "producer" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = local.producer_name
  description   = "Publishes synthetic OrderPlaced events to the custom EventBridge bus"
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = var.lambda_memory_mb

  create_package         = false
  local_existing_package = data.archive_file.producer.output_path

  cloudwatch_logs_retention_in_days = var.log_retention_days

  environment_variables = {
    EVENT_BUS_NAME = var.bus_name
    EVENT_SOURCE   = var.event_source
  }

  # Allow the producer to put events on the custom bus only.
  attach_policy_statements = true
  policy_statements = {
    put_events = {
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = [module.eventbridge.eventbridge_bus_arn]
    }
  }

  tags = var.tags
}

###############################################################################
# Consumer Lambda — invoked by the rule; processes matched events
###############################################################################

module "consumer" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = local.consumer_name
  description   = "Consumes OrderPlaced events routed by the EventBridge rule"
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = var.lambda_memory_mb

  create_package         = false
  local_existing_package = data.archive_file.consumer.output_path

  cloudwatch_logs_retention_in_days = var.log_retention_days

  # Let EventBridge invoke this function. Attach the permission to the
  # unqualified function ARN (not the $LATEST published version, which
  # AddPermission rejects).
  create_current_version_allowed_triggers = false
  allowed_triggers = {
    EventBridgeRule = {
      principal  = "events.amazonaws.com"
      source_arn = module.eventbridge.eventbridge_rule_arns["order_placed"]
    }
  }

  tags = var.tags
}

###############################################################################
# EventBridge — the star of the show (module v4.3.2)
###############################################################################

module "eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "4.3.2"

  # --- Custom bus ---------------------------------------------------------
  bus_name        = var.bus_name
  bus_description = "Custom bus for the EventBridge reference lab"

  # --- Rule: content-based routing of OrderPlaced events ------------------
  rules = {
    order_placed = {
      description = "Route OrderPlaced events to consumer, SNS, DLQ and audit log"
      event_pattern = jsonencode({
        source        = [var.event_source]
        "detail-type" = ["OrderPlaced"]
      })
    }
  }

  # --- Targets: one rule fans out to four target types --------------------
  targets = {
    order_placed = [
      {
        name = "send-to-consumer-lambda"
        arn  = module.consumer.lambda_function_arn
        # Undeliverable invocations land in the DLQ.
        dead_letter_arn = module.dlq.queue_arn
        retry_policy = {
          maximum_event_age_in_seconds = 3600
          maximum_retry_attempts       = 2
        }
      },
      {
        name = "fan-out-to-sns"
        arn  = module.sns.topic_arn
      },
      {
        name = "audit-to-cloudwatch-logs"
        arn  = aws_cloudwatch_log_group.audit.arn
      },
    ]
  }

  # --- Archive: replayable store of everything on the bus -----------------
  create_archives = true
  archives = {
    "${var.name_prefix}-archive" = {
      description    = "Archive of all events on the lab bus (supports replay)"
      retention_days = 3
      event_pattern = jsonencode({
        source = [var.event_source]
      })
    }
  }

  # --- Scheduler: recurring producer invocation (OFF by default) ----------
  # Disabled by default so a lab account has nothing running unattended.
  # Enable with -var enable_schedule=true to demonstrate scheduled production.
  create_schedule_groups = var.enable_schedule
  create_schedules       = var.enable_schedule
  schedule_groups = var.enable_schedule ? {
    "${var.name_prefix}-group" = {}
  } : {}
  schedules = var.enable_schedule ? {
    recurring_producer = {
      group_name          = "${var.name_prefix}-group"
      description         = "Invoke the producer Lambda on a recurring schedule"
      schedule_expression = var.schedule_expression
      timezone            = "UTC"

      flexible_time_window = {
        mode = "OFF"
      }

      arn      = module.producer.lambda_function_arn
      role_arn = aws_iam_role.scheduler[0].arn
      input = jsonencode({
        count = 3
      })
    }
  } : {}

  # --- IAM: let the module build the roles it needs for the targets -------
  attach_lambda_policy = true
  lambda_target_arns = [
    module.consumer.lambda_function_arn,
    module.producer.lambda_function_arn,
  ]

  attach_sns_policy = true
  sns_target_arns   = [module.sns.topic_arn]

  attach_sqs_policy = true
  sqs_target_arns   = [module.dlq.queue_arn]

  attach_cloudwatch_policy = true
  cloudwatch_target_arns   = ["${aws_cloudwatch_log_group.audit.arn}:*"]

  tags = var.tags
}
