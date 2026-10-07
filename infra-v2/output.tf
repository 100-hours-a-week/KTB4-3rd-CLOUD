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
