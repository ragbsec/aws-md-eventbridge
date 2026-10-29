###############################################################################
# event-application module
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id    = data.aws_caller_identity.current.account_id
  region        = data.aws_region.current.region
  producer_name = "${var.name_prefix}-producer"
  consumer_name = "${var.name_prefix}-consumer"
}

data "archive_file" "producer" {
  type        = "zip"
  source_dir  = "${path.module}/.build/${var.name_prefix}-producer-stage"
  output_path = "${path.module}/.build/${var.name_prefix}-producer.zip"
  depends_on  = [null_resource.producer_build]
}

# Stage the producer package WITH awscrt (manylinux x86_64) so PutEvents with an
# EndpointId can SigV4a-sign for the global endpoint. Rebuilds when the handler
# or its requirements change.
resource "null_resource" "producer_build" {
  triggers = {
    handler = filesha256("${var.lambda_source_dir}/producer/handler.py")
    reqs    = fileexists("${var.lambda_source_dir}/producer/requirements.txt") ? filesha256("${var.lambda_source_dir}/producer/requirements.txt") : "none"
    script  = filesha256("${path.module}/../../scripts/build-producer.sh")
  }

  provisioner "local-exec" {
    command = "bash ${path.module}/../../scripts/build-producer.sh ${var.lambda_source_dir}/producer ${path.module}/.build/${var.name_prefix}-producer-stage"
  }
}

data "archive_file" "consumer" {
  type        = "zip"
  source_dir  = "${var.lambda_source_dir}/consumer"
  output_path = "${path.module}/.build/${var.name_prefix}-consumer.zip"
}

###############################################################################
# Dead-letter queue (KMS-encrypted, TLS-enforced)
###############################################################################

module "dlq" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "~> 4.2"

  name                              = "${var.name_prefix}-dlq"
  message_retention_seconds         = 1209600 # 14 days
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  # Enforce TLS 1.2+ transport on the queue, and allow EventBridge to DLQ.
  create_queue_policy = true
  queue_policy_statements = {
    deny_insecure = {
      sid        = "DenyInsecureTransport"
      effect     = "Deny"
      actions    = ["sqs:*"]
      principals = [{ type = "*", identifiers = ["*"] }]
      conditions = [{
        test     = "Bool"
        variable = "aws:SecureTransport"
        values   = ["false"]
      }]
    }
    allow_eventbridge_dlq = {
      sid        = "AllowEventBridgeDLQ"
      effect     = "Allow"
      actions    = ["sqs:SendMessage"]
      principals = [{ type = "Service", identifiers = ["events.amazonaws.com"] }]
      conditions = [{
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }]
    }
  }

  tags = var.tags
}

###############################################################################
# Application SNS topic — fan-out/notifications (KMS-encrypted, TLS-enforced)
###############################################################################

resource "aws_sns_topic" "notifications" {
  name              = "${var.name_prefix}-notifications"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "sns" {
  # EventBridge may publish.
  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
  # Deny any non-TLS access.
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.notifications.arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sns_topic_policy" "notifications" {
  arn    = aws_sns_topic.notifications.arn
  policy = data.aws_iam_policy_document.sns.json
}

###############################################################################
# Producer Lambda
###############################################################################

module "producer" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = local.producer_name
  description   = "Publishes OrderPlaced events to ${var.bus_name}"
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_mb

  create_package         = false
  local_existing_package = data.archive_file.producer.output_path

  cloudwatch_logs_retention_in_days = var.log_retention_days
  cloudwatch_logs_kms_key_id        = var.kms_key_arn

  environment_variables = {
    EVENT_BUS_NAME = var.bus_name
    EVENT_SOURCE   = var.event_source
  }

  attach_policy_statements = true
  policy_statements = {
    put_events = {
      effect  = "Allow"
      actions = ["events:PutEvents"]
      # Include the failover region's bus so a global-endpoint failover (which
      # redirects PutEvents to the secondary region) is still authorized.
      resources = concat([var.bus_arn], var.failover_bus_arns)
    }
    kms = {
      effect    = "Allow"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = concat([var.kms_key_arn], var.failover_kms_key_arns)
    }
  }

  tags = var.tags
}

###############################################################################
# Consumer Lambda
###############################################################################

module "consumer" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 7.20"

  function_name = local.consumer_name
  description   = "Consumes OrderPlaced events routed from ${var.bus_name}"
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = var.lambda_timeout
  memory_size   = var.lambda_memory_mb

  create_package         = false
  local_existing_package = data.archive_file.consumer.output_path

  cloudwatch_logs_retention_in_days = var.log_retention_days
  cloudwatch_logs_kms_key_id        = var.kms_key_arn

  create_current_version_allowed_triggers = false
  allowed_triggers = {
    EventBridgeRule = {
      principal  = "events.amazonaws.com"
      source_arn = var.rule_arn
    }
  }

  tags = var.tags
}

###############################################################################
# Consumer PROCESSING-FAILURE dead-letter (platform default)
#
# Distinct from the EventBridge target DLQ above: this captures events the
# consumer was INVOKED with but whose HANDLER threw (after the Lambda async
# retries). Without it those events are dropped silently. Keeping it a SEPARATE
# queue lets operators tell a DELIVERY failure (target DLQ) from a PROCESSING
# failure (this queue) at a glance.
###############################################################################

module "consumer_failures" {
  source  = "terraform-aws-modules/sqs/aws"
  version = "~> 4.2"

  count = var.enable_consumer_on_failure ? 1 : 0

  name                              = "${var.name_prefix}-consumer-failures"
  message_retention_seconds         = 1209600 # 14 days
  kms_master_key_id                 = var.kms_key_arn
  kms_data_key_reuse_period_seconds = 300

  create_queue_policy = true
  queue_policy_statements = {
    deny_insecure = {
      sid        = "DenyInsecureTransport"
      effect     = "Deny"
      actions    = ["sqs:*"]
      principals = [{ type = "*", identifiers = ["*"] }]
      conditions = [{
        test     = "Bool"
        variable = "aws:SecureTransport"
        values   = ["false"]
      }]
    }
    # Lambda async on-failure destinations deliver as the FUNCTION'S role, so
    # allow this account's Lambda to send the failed event here.
    allow_lambda_on_failure = {
      sid        = "AllowLambdaOnFailure"
      effect     = "Allow"
      actions    = ["sqs:SendMessage"]
      principals = [{ type = "Service", identifiers = ["lambda.amazonaws.com"] }]
      conditions = [{
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }]
    }
  }

  tags = var.tags
}

# The consumer's role must be allowed to SendMessage to the failure queue
# (the on-failure destination is written by the invoking function's role).
resource "aws_iam_role_policy" "consumer_on_failure" {
  count = var.enable_consumer_on_failure ? 1 : 0
  name  = "${var.name_prefix}-consumer-on-failure"
  role  = module.consumer.lambda_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SendToFailureQueue"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = module.consumer_failures[0].queue_arn
      },
      {
        Sid      = "KmsForFailureQueue"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_key_arn
      },
    ]
  })
}

# Async-invocation config: retries, then route the failed event + error
# metadata to the failure queue instead of dropping it.
resource "aws_lambda_function_event_invoke_config" "consumer" {
  count                        = var.enable_consumer_on_failure ? 1 : 0
  function_name                = module.consumer.lambda_function_name
  maximum_retry_attempts       = var.consumer_max_retry_attempts
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      destination = module.consumer_failures[0].queue_arn
    }
  }

  depends_on = [aws_iam_role_policy.consumer_on_failure]
}

# Alarm: any processing-failure in the queue is a real signal (a consumer bug,
# bad data, or a downstream outage) — publish to the platform alerting topic.
resource "aws_cloudwatch_metric_alarm" "consumer_failures_not_empty" {
  count               = var.enable_consumer_on_failure ? 1 : 0
  alarm_name          = "${var.name_prefix}-${local.region}-consumer-failures-not-empty"
  alarm_description   = "Consumer PROCESSING failures (handler threw) dead-lettered for ${var.name_prefix}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = module.consumer_failures[0].queue_name
  }

  alarm_actions = var.alerts_topic_arn != "" ? [var.alerts_topic_arn] : []
  ok_actions    = var.alerts_topic_arn != "" ? [var.alerts_topic_arn] : []

  tags = var.tags
}

###############################################################################
# Rule targets — wire the app to the platform rule (fan-out to 3 target types)
###############################################################################

resource "aws_cloudwatch_event_target" "consumer" {
  event_bus_name = var.bus_name
  rule           = var.rule_name
  target_id      = "send-to-consumer-lambda"
  arn            = module.consumer.lambda_function_arn

  dead_letter_config {
    arn = module.dlq.queue_arn
  }
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 2
  }
}

resource "aws_cloudwatch_event_target" "sns" {
  event_bus_name = var.bus_name
  rule           = var.rule_name
  target_id      = "fan-out-to-sns"
  arn            = aws_sns_topic.notifications.arn
}

resource "aws_cloudwatch_event_target" "audit_logs" {
  event_bus_name = var.bus_name
  rule           = var.rule_name
  target_id      = "audit-to-cloudwatch-logs"
  arn            = var.audit_log_group_arn
}

###############################################################################
# DLQ depth alarm
###############################################################################

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.name_prefix}-${local.region}-dlq-not-empty"
  alarm_description   = "Messages present in the ${var.name_prefix} DLQ (undeliverable events)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = module.dlq.queue_name
  }

  # Wire the DLQ alarm to the platform's alerting SNS topic so undeliverable
  # events actually notify. Empty list when no topic is supplied.
  alarm_actions = var.alerts_topic_arn != "" ? [var.alerts_topic_arn] : []
  ok_actions    = var.alerts_topic_arn != "" ? [var.alerts_topic_arn] : []

  tags = var.tags
}
