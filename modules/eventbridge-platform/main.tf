###############################################################################
# eventbridge-platform module
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
}

###############################################################################
# CloudWatch Log group for the platform audit trail (KMS-encrypted)
###############################################################################

resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/events/${var.name_prefix}/audit"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# Allow EventBridge to write to the audit log group, scoped to this account.
data "aws_iam_policy_document" "audit_log" {
  statement {
    sid    = "AllowEventBridgeLogging"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.audit.arn}:*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "audit" {
  policy_name     = "${var.name_prefix}-audit-eb"
  policy_document = data.aws_iam_policy_document.audit_log.json
}

###############################################################################
# SNS alerting topic for operational alarms (KMS-encrypted)
###############################################################################

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-platform-alerts"
  kms_master_key_id = var.kms_key_arn
  tags              = var.tags
}

# Enforce TLS on the alerting topic.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
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

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# Optional on-call wiring: subscribe an email endpoint to the alerts topic.
# AWS sends a confirmation email; the subscription is PENDING until the human
# clicks confirm, so a live alert reaches a real inbox. Leave alert_email empty
# to create no subscription (the topic still exists for manual/PagerDuty wiring).
resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

###############################################################################
# EventBridge platform: bus + rule + archive (module v4.3.2)
###############################################################################

module "eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "4.3.2"

  bus_name        = var.bus_name
  bus_description = "Production EventBridge bus (${local.region}) for ${var.name_prefix}"

  # Customer-managed KMS encryption at rest for the bus.
  kms_key_identifier = var.kms_key_arn

  # Route matched events; targets are attached by the application root via its
  # own aws_cloudwatch_event_target resources referencing this rule.
  rules = {
    order_placed = {
      description = "Route OrderPlaced events on the ${var.bus_name} bus"
      event_pattern = jsonencode({
        source        = [var.event_source]
        "detail-type" = ["OrderPlaced"]
      })
    }
  }

  # No targets here — the application layer owns targets (separation of concerns).
  targets = {}

  # Replayable archive of all events on the bus (KMS-encrypted via bus key).
  create_archives = true
  archives = {
    "${var.name_prefix}-archive" = {
      description    = "Archive of ${var.bus_name} events (replayable)"
      retention_days = var.archive_retention_days
      event_pattern = jsonencode({
        source = [var.event_source]
      })
    }
  }

  # This module manages no target IAM here.
  create_role      = false
  create_schedules = false

  tags = var.tags
}

###############################################################################
# OPTIONAL: cross-account / org-wide sharing of this bus.
#
# By default the bus accepts PutEvents only from principals IN THIS ACCOUNT.
# To let OTHER accounts (or a whole AWS Organization) publish, attach a bus
# resource policy. Two mutually-compatible knobs, both empty by default:
#   - trusted_account_ids : explicit account IDs allowed to PutEvents
#   - organization_id      : an aws:PrincipalOrgID condition (org-wide)
# NOTE: the bus is KMS-encrypted, so a foreign publisher ALSO needs KMS access
# to the CMK — see the cross-account KMS grant below, which must be enabled too.
###############################################################################
locals {
  bus_sharing_enabled = length(var.trusted_account_ids) > 0 || var.organization_id != ""
}

data "aws_iam_policy_document" "bus_sharing" {
  count = local.bus_sharing_enabled ? 1 : 0

  # Explicit trusted accounts (if any).
  dynamic "statement" {
    for_each = length(var.trusted_account_ids) > 0 ? [1] : []
    content {
      sid       = "AllowTrustedAccountsPutEvents"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = [module.eventbridge.eventbridge_bus_arn]
      principals {
        type        = "AWS"
        identifiers = [for a in var.trusted_account_ids : "arn:aws:iam::${a}:root"]
      }
    }
  }

  # Org-wide (if an org id is given): any principal in the org may PutEvents.
  dynamic "statement" {
    for_each = var.organization_id != "" ? [1] : []
    content {
      sid       = "AllowOrgPutEvents"
      effect    = "Allow"
      actions   = ["events:PutEvents"]
      resources = [module.eventbridge.eventbridge_bus_arn]
      principals {
        type        = "AWS"
        identifiers = ["*"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:PrincipalOrgID"
        values   = [var.organization_id]
      }
    }
  }
}

resource "aws_cloudwatch_event_bus_policy" "sharing" {
  count          = local.bus_sharing_enabled ? 1 : 0
  event_bus_name = module.eventbridge.eventbridge_bus_name
  policy         = data.aws_iam_policy_document.bus_sharing[0].json
}

###############################################################################
# OPTIONAL: cross-account CONSUMING via bus-to-bus forwarding.
#
# Forward events matched on THIS bus to event buses in OTHER accounts/regions,
# so a central or partner account can consume them. For each target bus ARN we
# create a rule on this bus and a target pointing at the remote bus, plus the
# IAM role EventBridge assumes to PutEvents there. Empty list = no forwarding.
#
# The REMOTE bus must also allow this account via its own resource policy
# (that's their side of the trust — the trusted_account_ids knob above, run in
# the target account). Forwarding only moves the event; it does not decrypt it.
###############################################################################
locals {
  forwarding_enabled = length(var.forward_to_bus_arns) > 0
  # Map keyed by a stable index so for_each is deterministic.
  forward_targets = { for i, arn in var.forward_to_bus_arns : tostring(i) => arn }
}

data "aws_iam_policy_document" "forward_assume" {
  count = local.forwarding_enabled ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "forward" {
  count = local.forwarding_enabled ? 1 : 0
  statement {
    sid       = "ForwardPutEvents"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = var.forward_to_bus_arns
  }
}

resource "aws_iam_role" "forward" {
  count              = local.forwarding_enabled ? 1 : 0
  name               = "${var.name_prefix}-${local.region}-forward"
  assume_role_policy = data.aws_iam_policy_document.forward_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "forward" {
  count  = local.forwarding_enabled ? 1 : 0
  name   = "${var.name_prefix}-${local.region}-forward"
  role   = aws_iam_role.forward[0].id
  policy = data.aws_iam_policy_document.forward[0].json
}

# A rule on THIS bus that matches the platform's source and forwards to each
# remote bus as a target.
resource "aws_cloudwatch_event_rule" "forward" {
  count          = local.forwarding_enabled ? 1 : 0
  name           = "${var.name_prefix}-forward"
  description    = "Forward ${var.event_source} events to cross-account bus(es)"
  event_bus_name = module.eventbridge.eventbridge_bus_name
  event_pattern = jsonencode({
    source = [var.event_source]
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "forward" {
  for_each       = local.forwarding_enabled ? local.forward_targets : {}
  rule           = aws_cloudwatch_event_rule.forward[0].name
  event_bus_name = module.eventbridge.eventbridge_bus_name
  target_id      = "forward-${each.key}"
  arn            = each.value
  role_arn       = aws_iam_role.forward[0].arn
}

###############################################################################
# OPTIONAL: EventBridge Schema Registry + contract schema + discoverer.
#
# Enterprise event governance: register a versioned JSON Schema (OpenAPI) per
# event type so producers and consumers share a contract, and consumers can
# generate code bindings. The discoverer auto-infers schemas from events on the
# bus. Flag-gated via enable_schema_registry; the schema body is read from a
# file so it lives in version control and is used by the contract tests too.
###############################################################################
resource "aws_schemas_registry" "this" {
  count       = var.enable_schema_registry ? 1 : 0
  name        = "${var.name_prefix}-registry"
  description = "Event contract registry for ${var.name_prefix}"
  tags        = var.tags
}

# One schema per app-team event contract. Driven by var.schemas (a map), so a
# new app team onboards by ADDING an entry — no module code change. Key is the
# schema name; value is the OpenAPI/JSON Schema content.
resource "aws_schemas_schema" "contracts" {
  for_each      = var.enable_schema_registry ? var.schemas : {}
  name          = each.key
  registry_name = aws_schemas_registry.this[0].name
  type          = "OpenApi3"
  description   = "Event contract: ${each.key}"
  content       = each.value
  tags          = var.tags
}

# Optional discoverer: auto-infers schemas from events flowing on the bus.
resource "aws_schemas_discoverer" "this" {
  count       = var.enable_schema_registry && var.enable_schema_discoverer ? 1 : 0
  source_arn  = module.eventbridge.eventbridge_bus_arn
  description = "Auto-discover schemas from ${var.bus_name}"
  tags        = var.tags
}

###############################################################################
# OPTIONAL: EventBridge Scheduler — a recurring schedule that invokes a target.
# Prod-grade replacement for the old app-layer schedule. Flag-gated; when on,
# fires the configured ARN on var.schedule_expression via a scheduler role.
###############################################################################
data "aws_iam_policy_document" "scheduler_assume" {
  count = var.enable_scheduler ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler" {
  count = var.enable_scheduler ? 1 : 0
  statement {
    sid       = "InvokeScheduleTarget"
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [var.schedule_target_arn]
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.enable_scheduler ? 1 : 0
  name               = "${var.name_prefix}-${local.region}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  count  = var.enable_scheduler ? 1 : 0
  name   = "${var.name_prefix}-${local.region}-scheduler"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler[0].json
}

resource "aws_scheduler_schedule" "this" {
  count = var.enable_scheduler ? 1 : 0
  name  = "${var.name_prefix}-schedule"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression          = var.schedule_expression
  schedule_expression_timezone = "UTC"
  state                        = "ENABLED"

  target {
    arn      = var.schedule_target_arn
    role_arn = aws_iam_role.scheduler[0].arn
  }
}

###############################################################################
# OPTIONAL: EventBridge Pipe — point-to-point source -> (filter/enrich) -> target.
# Flag-gated; wires a source ARN (e.g. SQS/Kinesis/DynamoDB stream) to a target
# (e.g. this bus), with an optional filter. Enrichment ARN is optional.
###############################################################################
data "aws_iam_policy_document" "pipe_assume" {
  count = var.enable_pipe ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["pipes.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "pipe" {
  count = var.enable_pipe ? 1 : 0
  statement {
    sid       = "PipeSource"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [var.pipe_source_arn]
  }
  statement {
    sid       = "PipeTarget"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = [module.eventbridge.eventbridge_bus_arn]
  }
}

resource "aws_iam_role" "pipe" {
  count              = var.enable_pipe ? 1 : 0
  name               = "${var.name_prefix}-${local.region}-pipe"
  assume_role_policy = data.aws_iam_policy_document.pipe_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "pipe" {
  count  = var.enable_pipe ? 1 : 0
  name   = "${var.name_prefix}-${local.region}-pipe"
  role   = aws_iam_role.pipe[0].id
  policy = data.aws_iam_policy_document.pipe[0].json
}

resource "aws_pipes_pipe" "this" {
  count    = var.enable_pipe ? 1 : 0
  name     = "${var.name_prefix}-pipe"
  role_arn = aws_iam_role.pipe[0].arn
  source   = var.pipe_source_arn
  target   = module.eventbridge.eventbridge_bus_arn

  target_parameters {
    eventbridge_event_bus_parameters {
      detail_type = "PipeForwarded"
      source      = var.event_source
    }
  }
}

###############################################################################
# Monitoring: CloudWatch alarms on rule delivery failures + dashboard
###############################################################################

resource "aws_cloudwatch_metric_alarm" "failed_invocations" {
  alarm_name          = "${var.name_prefix}-${local.region}-rule-failed-invocations"
  alarm_description   = "EventBridge rule FailedInvocations > 0 in ${local.region}"
  namespace           = "AWS/Events"
  metric_name         = "FailedInvocations"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = module.eventbridge.eventbridge_rule_ids["order_placed"]
  }

  alarm_actions = var.alarm_actions_enabled ? [aws_sns_topic.alerts.arn] : []
  ok_actions    = var.alarm_actions_enabled ? [aws_sns_topic.alerts.arn] : []
  tags          = var.tags
}

resource "aws_cloudwatch_metric_alarm" "throttled_rules" {
  alarm_name          = "${var.name_prefix}-${local.region}-rule-throttled"
  alarm_description   = "EventBridge rule ThrottledRules > 0 in ${local.region}"
  namespace           = "AWS/Events"
  metric_name         = "ThrottledRules"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    RuleName = module.eventbridge.eventbridge_rule_ids["order_placed"]
  }

  alarm_actions = var.alarm_actions_enabled ? [aws_sns_topic.alerts.arn] : []
  tags          = var.tags
}

resource "aws_cloudwatch_dashboard" "platform" {
  dashboard_name = "${var.name_prefix}-${local.region}-platform"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "EventBridge — Events & Failures (${local.region})"
          region = local.region
          view   = "timeSeries"
          metrics = [
            ["AWS/Events", "TriggeredRules", "RuleName", module.eventbridge.eventbridge_rule_ids["order_placed"]],
            ["AWS/Events", "FailedInvocations", "RuleName", module.eventbridge.eventbridge_rule_ids["order_placed"]],
            ["AWS/Events", "ThrottledRules", "RuleName", module.eventbridge.eventbridge_rule_ids["order_placed"]],
          ]
        }
      },
      {
        type = "log", x = 0, y = 6, width = 24, height = 6
        properties = {
          title  = "Audit log — recent matched events (${local.region})"
          region = local.region
          query  = "SOURCE '${aws_cloudwatch_log_group.audit.name}' | fields @timestamp, @message | sort @timestamp desc | limit 50"
          view   = "table"
        }
      },
    ]
  })
}
