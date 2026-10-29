###############################################################################
# App layer — target permissions the EventBridge module does not manage itself
#
#  - SNS resource policy allowing EventBridge to Publish.
#  - Scheduler execution role allowing it to invoke the producer Lambda.
###############################################################################

# --- SNS topic policy: allow EventBridge rule target to publish -------------
data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    sid    = "AllowEventBridgePublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [module.sns.topic_arn]
  }
}

resource "aws_sns_topic_policy" "eventbridge" {
  arn    = module.sns.topic_arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

# --- Scheduler execution role: allow it to invoke the producer Lambda -------
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Scope the trust to this account to avoid the confused-deputy problem.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  count              = var.enable_schedule ? 1 : 0
  name               = "${var.name_prefix}-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "scheduler_invoke" {
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [module.producer.lambda_function_arn]
  }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  count  = var.enable_schedule ? 1 : 0
  name   = "${var.name_prefix}-scheduler-invoke"
  role   = aws_iam_role.scheduler[0].id
  policy = data.aws_iam_policy_document.scheduler_invoke.json
}
