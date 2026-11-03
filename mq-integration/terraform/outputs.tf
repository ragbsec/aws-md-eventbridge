output "instance_id" {
  value = aws_instance.mq.id
}

output "private_ip" {
  value = aws_instance.mq.private_ip
}

output "outbound_queue_url" {
  value = aws_sqs_queue.outbound.url
}

output "outbound_queue_arn" {
  value = aws_sqs_queue.outbound.arn
}

output "outbound_dlq_arn" {
  value = aws_sqs_queue.dlq.arn
}

output "secret_arn" {
  value = aws_secretsmanager_secret.mq.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.mq.name
}

output "bundle_bucket" {
  value = aws_s3_bucket.bundle.id
}

output "event_rule_name" {
  value = aws_cloudwatch_event_rule.outbound.name
}

output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.mq.id} --region ${var.region}"
}
