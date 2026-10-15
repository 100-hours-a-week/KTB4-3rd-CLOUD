output "logs_bucket_name" {
  description = "Loki 청크·인덱스 버킷"
  value       = aws_s3_bucket.this["logs"].bucket
}

output "logs_bucket_arn" {
  value = aws_s3_bucket.this["logs"].arn
}

output "config_bucket_name" {
  description = "모니터링 호스트가 동기화하는 설정 파일 버킷"
  value       = aws_s3_bucket.this["config"].bucket
}

output "config_bucket_arn" {
  value = aws_s3_bucket.this["config"].arn
}

output "host_role_name" {
  value = aws_iam_role.host.name
}

output "host_instance_profile_name" {
  value = aws_iam_instance_profile.host.name
}

output "ssm_parameter_names" {
  description = "값을 콘솔·CLI로 넣어야 하는 비밀값 (초기값 CHANGE_ME)"
  value       = { for k, p in aws_ssm_parameter.secret : k => p.name }
}

output "heartbeat_namespace" {
  description = "모니터링 호스트가 하트비트를 보내는 CloudWatch 네임스페이스"
  value       = local.heartbeat_namespace
}
