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

output "instance_id" {
  value = aws_instance.host.id
}

output "private_ip" {
  description = "Alloy가 Loki로 push할 주소, Prometheus·Grafana 내부 주소"
  value       = aws_instance.host.private_ip
}

output "ssm_session_command" {
  value = "aws ssm start-session --target ${aws_instance.host.id}"
}

output "grafana_port_forward_command" {
  description = "ALB 호스트 규칙 없이 Grafana에 접속 (로컬 http://localhost:3000)"
  value       = "aws ssm start-session --target ${aws_instance.host.id} --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3000"
}

output "config_object_keys" {
  description = "S3 설정 버킷에 올라간 스택 설정 파일"
  value       = sort([for o in aws_s3_object.config : o.key])
}

output "prometheus_config" {
  description = "렌더링된 prometheus.yml (검토용)"
  value       = local.config_files["prometheus/prometheus.yml"]
}
