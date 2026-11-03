data "aws_partition" "current" {}

locals {
  tags      = merge(var.tags, { Component = "mq-integration" })
  partition = data.aws_partition.current.partition

  queue_name = "${var.name_prefix}-outbound"
  rule_name  = "mq-outbound-rule"

  use_default_vpc = var.vpc_id == ""
  vpc_id          = local.use_default_vpc ? one(data.aws_vpc.default[*].id) : var.vpc_id
  subnet_id       = var.subnet_id != "" ? var.subnet_id : try(sort(data.aws_subnets.selected.ids)[0], "")

  bus_kms_key = try(data.aws_cloudwatch_event_bus.this.kms_key_identifier, null)
  # Bus CMK (if the provider reports it) plus the failover buses' CMKs.
  bus_kms_keys = compact(concat([local.bus_kms_key == null ? "" : local.bus_kms_key], var.failover_kms_key_arns))
}

# Existing platform bus (looked up, never managed here).
data "aws_cloudwatch_event_bus" "this" {
  name = var.bus_name
}

###############################################################################
# Networking lookups
###############################################################################

data "aws_vpc" "default" {
  count   = local.use_default_vpc ? 1 : 0
  default = true
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [local.vpc_id == null ? "" : local.vpc_id]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "terraform_data" "network_check" {
  lifecycle {
    precondition {
      condition     = local.vpc_id != null && local.vpc_id != ""
      error_message = "No VPC available: no default VPC exists in ${var.region}. Set var.vpc_id and var.subnet_id."
    }
    precondition {
      condition     = local.subnet_id != ""
      error_message = "No subnet found in VPC ${coalesce(local.vpc_id, "(none)")}. Set var.subnet_id."
    }
  }
}

###############################################################################
# Security group: egress all; ingress only when CIDRs are supplied
###############################################################################

resource "aws_security_group" "mq" {
  name_prefix = "${var.name_prefix}-host-"
  description = "IBM MQ host (no ingress by default; SSM access only)"
  vpc_id      = local.vpc_id

  tags = merge(local.tags, { Name = "${var.name_prefix}-host" })

  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = local.vpc_id != null && local.vpc_id != ""
      error_message = "No VPC available: no default VPC exists in ${var.region}. Set var.vpc_id and var.subnet_id."
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.mq.id
  description       = "All outbound (package, image, AWS API access)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "mq_client" {
  for_each          = toset(var.mq_client_cidrs)
  security_group_id = aws_security_group.mq.id
  description       = "MQ client listener"
  ip_protocol       = "tcp"
  from_port         = 1414
  to_port           = 1414
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "console" {
  for_each          = toset(var.console_cidrs)
  security_group_id = aws_security_group.mq.id
  description       = "MQ web console"
  ip_protocol       = "tcp"
  from_port         = 9443
  to_port           = 9443
  cidr_ipv4         = each.value
}

###############################################################################
# SQS: EventBridge -> eb-mq-outbound (+ DLQ), SSE enabled
###############################################################################

resource "aws_sqs_queue" "dlq" {
  name                      = "${local.queue_name}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "outbound" {
  name                       = local.queue_name
  message_retention_seconds  = var.sqs_retention_seconds
  visibility_timeout_seconds = 60
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
}

data "aws_iam_policy_document" "outbound_queue" {
  statement {
    sid       = "AllowRuleSendMessage"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.outbound.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.outbound.arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.outbound.arn]
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

resource "aws_sqs_queue_policy" "outbound" {
  queue_url = aws_sqs_queue.outbound.id
  policy    = data.aws_iam_policy_document.outbound_queue.json
}

data "aws_iam_policy_document" "dlq" {
  statement {
    sid       = "AllowRuleDeadLetter"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.outbound.arn]
    }
  }
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.dlq.arn]
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

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq.json
}

###############################################################################
# EventBridge rule (anti-loop: skip events the bridge itself published)
###############################################################################

resource "aws_cloudwatch_event_rule" "outbound" {
  name           = local.rule_name
  description    = "Orders -> SQS for the IBM MQ bridge (excludes origin=ibm-mq)"
  event_bus_name = data.aws_cloudwatch_event_bus.this.name

  event_pattern = jsonencode({
    source        = [var.event_source]
    "detail-type" = ["OrderPlaced"]
    detail = {
      # Values in one field's array are OR'ed: match events with NO origin
      # (lab producer, test.sh) or any origin other than ibm-mq. "anything-but"
      # alone never matches a missing field.
      origin = [{ "exists" = false }, { "anything-but" = "ibm-mq" }]
    }
  })
}

resource "aws_cloudwatch_event_target" "outbound" {
  rule           = aws_cloudwatch_event_rule.outbound.name
  event_bus_name = data.aws_cloudwatch_event_bus.this.name
  target_id      = "mq-outbound-sqs"
  arn            = aws_sqs_queue.outbound.arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq.arn
  }

  depends_on = [aws_sqs_queue_policy.outbound, aws_sqs_queue_policy.dlq]
}

###############################################################################
# Secret container only (values are generated on the instance at first boot)
###############################################################################

resource "aws_secretsmanager_secret" "mq" {
  name                    = var.secret_name
  description             = "IBM MQ admin/app passwords (values written by the instance at first boot)"
  recovery_window_in_days = 0 # lab: allow immediate delete and name reuse
}

###############################################################################
# Bundle: ../docker + ../bridge -> private encrypted S3 bucket
###############################################################################

locals {
  docker_dir = "${path.module}/../docker"
  bridge_dir = "${path.module}/../bridge"
  # Never upload tests, caches, local env files, state or key-like files.
  bundle_exclude = "(^|/)(__pycache__|\\.pytest_cache|tests|node_modules|\\.git|\\.terraform|\\.build|\\.venv)(/|$)|(^|/)(\\.env[^/]*|bridge\\.env|[^/]*\\.(tfstate|tfvars|pem|key|p12|jks|kdb|sth|rdb|crt)|[^/]*\\.py[co])$"
  bundle_files = merge(
    { for f in fileset(local.docker_dir, "**") : "docker/${f}" => "${local.docker_dir}/${f}" if !can(regex(local.bundle_exclude, f)) },
    { for f in fileset(local.bridge_dir, "**") : "bridge/${f}" => "${local.bridge_dir}/${f}" if !can(regex(local.bundle_exclude, f)) },
  )
}

data "archive_file" "bundle" {
  type        = "zip"
  output_path = "${path.module}/.build/eb-mq-bundle.zip"

  dynamic "source" {
    for_each = local.bundle_files
    content {
      filename = source.key
      content  = file(source.value)
    }
  }
}

resource "aws_s3_bucket" "bundle" {
  bucket_prefix = "${var.name_prefix}-bundle-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bundle" {
  bucket                  = aws_s3_bucket.bundle.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "bundle" {
  bucket = aws_s3_bucket.bundle.id
  versioning_configuration {
    status = "Disabled"
  }
}

data "aws_iam_policy_document" "bundle_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.bundle.arn, "${aws_s3_bucket.bundle.arn}/*"]
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

resource "aws_s3_bucket_policy" "bundle" {
  bucket     = aws_s3_bucket.bundle.id
  policy     = data.aws_iam_policy_document.bundle_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.bundle]
}

resource "aws_s3_object" "bundle" {
  bucket                 = aws_s3_bucket.bundle.id
  key                    = "bundle-${data.archive_file.bundle.output_md5}.zip"
  source                 = data.archive_file.bundle.output_path
  etag                   = data.archive_file.bundle.output_md5
  server_side_encryption = "AES256"

  lifecycle {
    precondition {
      condition     = length(local.bundle_files) > 0
      error_message = "Bundle is empty: ../docker and ../bridge contain no files."
    }
  }
}

###############################################################################
# IAM
###############################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name_prefix        = "${var.name_prefix}-host-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "host" {
  statement {
    sid     = "PutEventsOnBus"
    actions = ["events:PutEvents"]
    # With a global endpoint (eb_endpoint_id), a failover redirects PutEvents to the
    # bus in the other region, so that bus must be authorized too (same pattern as
    # modules/event-application).
    resources = concat([data.aws_cloudwatch_event_bus.this.arn], var.failover_bus_arns)
  }

  dynamic "statement" {
    for_each = length(local.bus_kms_keys) > 0 ? [local.bus_kms_keys] : []
    content {
      sid       = "BusCmkUse"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
      resources = statement.value
      # Only usable through EventBridge, in this region or a failover region.
      condition {
        test     = "StringLike"
        variable = "kms:ViaService"
        values   = ["events.*.amazonaws.com"]
      }
    }
  }

  statement {
    sid = "ConsumeOutboundQueue"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:ChangeMessageVisibility",
    ]
    resources = [aws_sqs_queue.outbound.arn]
  }

  statement {
    sid       = "SecretAccess"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.mq.arn]
  }

  statement {
    sid       = "ReadBundle"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bundle.arn}/${aws_s3_object.bundle.key}"]
  }
}

resource "aws_iam_role_policy" "host" {
  name   = "eb-mq-host"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.host.json
}

resource "aws_iam_instance_profile" "host" {
  name_prefix = "${var.name_prefix}-host-"
  role        = aws_iam_role.host.name
}

###############################################################################
# EC2 host
###############################################################################

resource "aws_instance" "mq" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.mq.id]
  iam_instance_profile        = aws_iam_instance_profile.host.name
  associate_public_ip_address = var.associate_public_ip
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/templates/user-data.sh.tftpl", {
    region          = var.region
    bus_name        = var.bus_name
    event_source    = var.event_source
    outbound_queue  = aws_sqs_queue.outbound.url
    eb_endpoint_id  = var.eb_endpoint_id
    secret_id       = aws_secretsmanager_secret.mq.name
    bundle_bucket   = aws_s3_bucket.bundle.id
    bundle_key      = aws_s3_object.bundle.key
    compose_version = var.compose_version
    mq_image        = var.mq_image
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers (bridge) may need IMDS/credentials
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
    tags        = merge(local.tags, { Name = "${var.name_prefix}-root" })
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-mq-host" })

  depends_on = [terraform_data.network_check, aws_iam_role_policy.host]

  lifecycle {
    ignore_changes = [ami] # don't replace the host when the public AMI parameter moves
  }
}
