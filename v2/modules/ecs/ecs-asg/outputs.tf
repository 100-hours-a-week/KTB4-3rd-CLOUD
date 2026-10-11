output "capacity_provider_name" {
  description = "ecs-cluster capacity_providers 와 ecs-service capacity_provider_strategy 에 넣는 값"
  value       = aws_ecs_capacity_provider.this.name
}

output "capacity_provider_arn" {
  value = aws_ecs_capacity_provider.this.arn
}

output "autoscaling_group_name" {
  value = aws_autoscaling_group.this.name
}

output "autoscaling_group_arn" {
  value = aws_autoscaling_group.this.arn
}

output "launch_template_id" {
  value = aws_launch_template.this.id
}

output "instance_attributes" {
  description = "이 ASG 인스턴스에 붙는 ECS 인스턴스 속성 (placement constraint 작성용)"
  value = {
    role     = var.role
    purchase = var.purchase
  }
}
