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
