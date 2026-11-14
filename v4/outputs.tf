output "app_subnet_ids" {
  description = "v4 private 서브넷 (AZ 접미사 → ID)"
  value       = { for k, s in aws_subnet.app : k => s.id }
}

output "task_security_group_ids" {
  value = { for k, sg in aws_security_group.task : k => sg.id }
}

output "instance_security_group_id" {
  value = aws_security_group.instance.id
}

output "data_host_security_group_id" {
  value = aws_security_group.data_host.id
}

output "task_execution_role_arn" {
  value = aws_iam_role.task_execution.arn
}

output "task_role_arns" {
  value = { for k, r in aws_iam_role.task : k => r.arn }
}

output "deploy_role_arn" {
  description = "GitHub Actions v4 prod CD가 Assume하는 Role"
  value       = aws_iam_role.deploy.arn
}

output "data_host" {
  description = "데이터 호스트. 접속: aws ssm start-session --target <instance_id>. 부트스트랩 로그: /var/log/data-host-bootstrap.log. 구성 재적용: sudo data-host-apply"
  value = {
    instance_id = aws_instance.data_host.id
    private_ip  = local.data_host_private_ip
    kafka       = "${local.data_host_private_ip}:${local.kafka_port}"
    redis       = "${local.data_host_private_ip}:${local.redis_port}"
  }
}

output "v4_parameters" {
  description = "태스크에 주입할 v4 SSM 파라미터 ARN"
  value = merge(
    { for k, p in aws_ssm_parameter.broker : k => p.arn },
    { MONGODB_URI = aws_ssm_parameter.mongo["uri"].arn },
  )
}

output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_names" {
  value = [for s in aws_ecs_service.service : s.name]
}

output "task_definition_families" {
  description = "CD가 새 revision을 등록하는 family"
  value       = { for k, td in aws_ecs_task_definition.service : k => td.family }
}

output "target_group_arns" {
  value = { for k, tg in aws_lb_target_group.service : k => tg.arn }
}
