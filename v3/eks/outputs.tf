output "vpc_id" {
  description = "AWS Load Balancer Controller의 vpcId 값 (IMDS hop limit 1이라 직접 지정한다)"
  value       = data.aws_vpc.shared.id
}

output "node_security_group_ids" {
  value = { for k, sg in aws_security_group.node : k => sg.id }
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.this.name}"
}
