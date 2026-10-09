output "service_name" {
  value = aws_ecs_service.this.name
}

output "service_arn" {
  value = aws_ecs_service.this.id
}

output "task_definition_family" {
  description = "CI가 새 revision을 등록할 family"
  value       = aws_ecs_task_definition.this.family
}

output "task_security_group_id" {
  description = "MySQL·Redis SG에서 이 서비스 태스크만 허용할 때 참조"
  value       = aws_security_group.task.id
}

output "target_group_arn" {
  value = try(aws_lb_target_group.this[0].arn, null)
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
