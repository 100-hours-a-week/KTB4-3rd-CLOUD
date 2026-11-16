# v4 앱 호스트 용량 (설계 5.3절). 1 Launch Template = 1 ASG = 1 Capacity Provider.
#   spot : 평소 쓰는 용량. Spot 100%, 회수율 낮은 타입만, 2a·2c 두 AZ, capacity_rebalance
#   od   : On-Demand 폴백. min 0으로 대기(평소 비용 $0). 용량 부족 때 서비스 전략을 od로 바꾼다 (README 런북)
# ASG는 직접 스케일링하지 않는다. desired는 Capacity Provider managed scaling이 맞춘다.
#   참고: v2/modules/ecs/ecs-asg/main.tf

data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

locals {
  asg_groups = {
    spot = {
      purchase       = "spot"
      instance_types = var.spot_instance_types
      min            = var.spot_capacity.min
      max            = var.spot_capacity.max
    }
    od = {
      purchase       = "od"
      instance_types = ["t3.medium"]
      min            = 0
      max            = 2
    }
  }

  # 모든 호스트에 role=shared를 붙인다. 서비스 placement constraint(attribute:role == shared)의 기준이다.
  ecs_config = {
    for key, g in local.asg_groups : key => join("\n", [
      "ECS_CLUSTER=${local.cluster_name}",
      "ECS_INSTANCE_ATTRIBUTES=${jsonencode({ role = "shared", purchase = g.purchase })}",
      "ECS_ENABLE_TASK_IAM_ROLE=true",
      "ECS_ENABLE_SPOT_INSTANCE_DRAINING=${g.purchase == "spot"}",
      "ECS_AWSVPC_BLOCK_IMDS=true",
      # Spot 회수 예고(2분) 안에 끝나도록 120초보다 짧게 둔다
      "ECS_CONTAINER_STOP_TIMEOUT=${var.container_stop_timeout_seconds}s",
    ])
  }
}

resource "aws_launch_template" "app" {
  for_each = local.asg_groups

  name                   = "${local.name_prefix}-${each.key}-lt"
  description            = "v4 ECS ${each.key} hosts for ${local.cluster_name}"
  image_id               = data.aws_ssm_parameter.ecs_ami.insecure_value
  vpc_security_group_ids = [aws_security_group.instance.id]
  update_default_version = true

  iam_instance_profile {
    arn = aws_iam_instance_profile.container_instance.arn
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    cat <<'CONFIG' >> /etc/ecs/ecs.config
    ${local.ecs_config[each.key]}
    CONFIG
  EOT
  )

  # IMDSv2 필수 + hop limit 1
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = 30
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = false
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name_prefix}-${each.key}", Purchase = each.value.purchase }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${local.name_prefix}-${each.key}", Purchase = each.value.purchase }
  }
}

resource "aws_autoscaling_group" "app" {
  for_each = local.asg_groups

  name                = "${local.name_prefix}-${each.key}"
  vpc_zone_identifier = [for s in aws_subnet.app : s.id]
  min_size            = each.value.min
  max_size            = each.value.max

  # managed termination protection 전제 조건
  protect_from_scale_in = true
  # Spot만 Capacity Rebalance. 회수 위험 신호를 받으면 대체 인스턴스를 먼저 띄운다
  capacity_rebalance = each.value.purchase == "spot"

  # ALB 대상은 태스크(IP)다. ASG는 호스트 장애만 본다
  health_check_type         = "EC2"
  health_check_grace_period = 300

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = each.value.purchase == "spot" ? 0 : 100
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app[each.key].id
        version            = aws_launch_template.app[each.key].latest_version
      }

      dynamic "override" {
        for_each = each.value.instance_types

        content {
          instance_type = override.value
        }
      }
    }
  }

  # AMI 교체 = instance refresh. 새 인스턴스를 먼저 띄운 뒤 한 대씩 교체한다
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage       = 100
      max_healthy_percentage       = 200
      instance_warmup              = 300
      scale_in_protected_instances = "Refresh"
      skip_matching                = true
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-${each.key}"
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  lifecycle {
    # desired는 Capacity Provider managed scaling이 관리한다
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "app" {
  for_each = local.asg_groups

  name = "${local.name_prefix}-${each.key}-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.app[each.key].arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
      instance_warmup_period    = 300
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [for cp in aws_ecs_capacity_provider.app : cp.name]

  # 서비스에 전략을 따로 주지 않으면 Spot으로 뜬다
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.app["spot"].name
    weight            = 1
    base              = 0
  }
}
