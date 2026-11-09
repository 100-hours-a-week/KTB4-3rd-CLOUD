output "vpc_id" {
  description = "AWS Load Balancer Controller의 vpcId 값 (IMDS hop limit 1이라 직접 지정한다)"
  value       = data.aws_vpc.shared.id
}

output "node_security_group_ids" {
  value = { for k, sg in aws_security_group.node : k => sg.id }
}
