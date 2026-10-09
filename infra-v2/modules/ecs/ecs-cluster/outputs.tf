output "cluster_name" {
  description = "ecs-asg의 ECS_CLUSTER 값. Capacity Provider 등록과 무관하게 클러스터만 생기면 확정된다."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "capacity_ready_cluster_arn" {
  description = <<-EOT
    Capacity Provider 등록(aws_ecs_cluster_capacity_providers)이 끝난 뒤에 확정되는 클러스터 ARN.
    ecs-service 모듈에 넘겨 서비스가 등록 전 Capacity Provider를 참조하는 순서 오류를 막는다.
  EOT
  value = aws_ecs_cluster.this.arn

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

output "service_connect_namespace_arn" {
  description = "ECS Service의 service_connect_configuration.namespace에 지정"
  value       = aws_service_discovery_http_namespace.this.arn
}

output "service_connect_namespace_name" {
  value = aws_service_discovery_http_namespace.this.name
}

output "task_execution_role_arn" {
  value = aws_iam_role.task_execution.arn
}

output "task_role_arns" {
  description = "서비스 이름 → Task Role ARN"
  value       = { for k, r in aws_iam_role.task : k => r.arn }
}

output "task_role_names" {
  description = "서비스 스택에서 앱 권한(S3, SQS 등)을 붙일 때 사용"
  value       = { for k, r in aws_iam_role.task : k => r.name }
}

output "deploy_role_arn" {
  description = "GitHub Actions의 aws-actions/configure-aws-credentials role-to-assume 값"
  value       = aws_iam_role.deploy.arn
}

output "exec_operator_policy_arn" {
  value = try(aws_iam_policy.exec_operator[0].arn, null)
}

output "config_path_prefix" {
  description = "이 스테이지 설정을 저장할 Parameter Store / Secrets Manager 경로 접두어"
  value       = "/${var.project_name}/${var.stage}/"
}

output "instance_profile_arn" {
  description = "ecs-asg Launch Template에 넣을 스테이지 공용 인스턴스 프로파일"
  value       = aws_iam_instance_profile.container_instance.arn
}

output "instance_role_name" {
  value = aws_iam_role.container_instance.name
}

output "instance_security_group_id" {
  description = "ecs-asg Launch Template에 넣을 스테이지 공용 인스턴스 SG (인바운드 없음)"
  value       = aws_security_group.container_instance.id
}
