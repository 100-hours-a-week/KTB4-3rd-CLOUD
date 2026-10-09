output "vpc_id" {
  value = data.aws_vpc.shared.id
}

output "subnet_ids" {
  value = { for key, subnet in aws_subnet.v2 : key => subnet.id }
}

output "alb_dns_name" {
  value = aws_lb.public.dns_name
}

output "alb_zone_id" {
  value = aws_lb.public.zone_id
}

output "instance_ids" {
  value = { for role, instance in aws_instance.host : role => instance.id }
}

output "private_ips" {
  value = { for role, instance in aws_instance.host : role => instance.private_ip }
}

output "target_group_arns" {
  value = { for service, target_group in aws_lb_target_group.service : service => target_group.arn }
}

output "ecs_clusters" {
  description = "스테이지별 ECS Cluster 이름·ARN"
  value = {
    for stage, m in module.ecs_cluster : stage => {
      name = m.cluster_name
      arn  = m.cluster_arn
    }
  }
}

output "ecs_service_connect_namespace_arns" {
  value = { for stage, m in module.ecs_cluster : stage => m.service_connect_namespace_arn }
}

output "ecs_task_execution_role_arns" {
  value = { for stage, m in module.ecs_cluster : stage => m.task_execution_role_arn }
}

output "ecs_task_role_arns" {
  description = "stage → service → Task Role ARN"
  value       = { for stage, m in module.ecs_cluster : stage => m.task_role_arns }
}

output "ecs_deploy_role_arns" {
  description = "GitHub Actions configure-aws-credentials의 role-to-assume 값 (Environment variable로 등록)"
  value       = { for stage, m in module.ecs_cluster : stage => m.deploy_role_arn }
}

output "ecs_exec_operator_policy_arns" {
  value = { for stage, m in module.ecs_cluster : stage => m.exec_operator_policy_arn }
}

output "ecs_config_path_prefixes" {
  value = { for stage, m in module.ecs_cluster : stage => m.config_path_prefix }
}

output "ecs_instance_security_group_ids" {
  description = "stage → 컨테이너 인스턴스 SG (인바운드 없음)"
  value       = { for stage, m in module.ecs_cluster : stage => m.instance_security_group_id }
}

output "ecs_capacity_providers" {
  description = "stage → ASG 그룹(rest-od 등) → Capacity Provider 이름"
  value = {
    for stage in keys(local.ecs_stages) : stage => {
      for k, m in module.ecs_asg : local.ecs_asgs[k].key => m.capacity_provider_name if local.ecs_asgs[k].stage == stage
    }
  }
}

output "ecs_autoscaling_group_names" {
  description = "stage → ASG 그룹 → ASG 이름"
  value = {
    for stage in keys(local.ecs_stages) : stage => {
      for k, m in module.ecs_asg : local.ecs_asgs[k].key => m.autoscaling_group_name if local.ecs_asgs[k].stage == stage
    }
  }
}

output "ecs_services" {
  description = "<stage>-<service> → ECS Service·Task Definition family·태스크 SG·Target Group"
  value = {
    for k, m in module.ecs_service : k => {
      service_name           = m.service_name
      task_definition_family = m.task_definition_family
      task_security_group_id = m.task_security_group_id
      target_group_arn       = m.target_group_arn
      log_group_name         = m.log_group_name
    }
  }
}
