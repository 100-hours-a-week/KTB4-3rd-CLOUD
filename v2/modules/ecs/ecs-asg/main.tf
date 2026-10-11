# =============================================================================
# ecs-asg : 1 Launch Template = 1 ASG = 1 Capacity Provider (= 1 Cluster)
#   설계 근거: issues/ecs-asg-by-cluster-service.md
#
#   - Launch Template이 격리 설정을 담는다 (6.3)
#       ECS_CLUSTER              : 스테이지 경계
#       ECS_INSTANCE_ATTRIBUTES  : 서비스 경계 (role / purchase → memberOf placement constraint)
#       ECS_ENABLE_SPOT_INSTANCE_DRAINING : Spot만 true (기본값 false)
#       ECS_AWSVPC_BLOCK_IMDS    : 태스크가 인스턴스 Role 자격 증명을 쓰지 못하게 차단
#   - ASG는 직접 스케일링하지 않는다. Service Auto Scaling(태스크) → managed scaling(인스턴스) 2단계 (7절)
#     → desired_capacity는 ignore_changes
#   - managed termination protection + ASG scale-in protection + managed draining (7.2)
#   - instance refresh는 min/max healthy 100% (한 대씩, 새 인스턴스 먼저) (7.3)
# =============================================================================

locals {
  is_spot = var.purchase == "spot"

  # 이름 규칙: <project>-<stage>-<role>-<purchase> (6.1)
  asg_name = var.name
  lt_name  = "${var.name}-lt"
  cp_name  = "${var.name}-cp"

  # 태그 (6.2). AmazonECSManaged는 managed scaling이 붙이는 태그를 미리 선언해 드리프트 방지
  tags = merge(var.tags, {
    Stage    = var.stage
    Role     = var.role
    Purchase = var.purchase
  })

  ecs_config = join("\n", [
    "ECS_CLUSTER=${var.cluster_name}",
    "ECS_INSTANCE_ATTRIBUTES=${jsonencode({ role = var.role, purchase = var.purchase })}",
    "ECS_ENABLE_TASK_IAM_ROLE=true",
    "ECS_ENABLE_SPOT_INSTANCE_DRAINING=${local.is_spot}",
    "ECS_AWSVPC_BLOCK_IMDS=true",
    "ECS_CONTAINER_STOP_TIMEOUT=${var.container_stop_timeout_seconds}s",
  ])
}

data "aws_ssm_parameter" "ecs_ami" {
  name = var.ami_ssm_parameter_name
}

# -----------------------------------------------------------------------------
# Launch Template (ASG마다 1개)
# -----------------------------------------------------------------------------

resource "aws_launch_template" "this" {
  name                   = local.lt_name
  description            = "ECS ${var.role}/${var.purchase} hosts for ${var.cluster_name}"
  image_id               = data.aws_ssm_parameter.ecs_ami.insecure_value
  vpc_security_group_ids = var.security_group_ids
  update_default_version = true

  iam_instance_profile {
    arn = var.instance_profile_arn
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    cat <<'CONFIG' >> /etc/ecs/ecs.config
    ${local.ecs_config}
    CONFIG
  EOT
  )

  # IMDSv2 필수 + hop limit 1 (issues/ecs-iam-network.md 8.3)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gib
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = false
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = local.asg_name })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(local.tags, { Name = local.asg_name })
  }

  tags = merge(local.tags, { Name = local.lt_name })
}

# -----------------------------------------------------------------------------
# Auto Scaling Group
# -----------------------------------------------------------------------------

resource "aws_autoscaling_group" "this" {
  name                = local.asg_name
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size

  # managed termination protection 전제 조건 [D4]
  protect_from_scale_in = true
  # Spot만 Capacity Rebalance. managed draining이 Rebalance로 빠지는 인스턴스도 drain한다 [D5] [D6]
  capacity_rebalance = local.is_spot

  # ALB 대상은 태스크(IP)다. ASG는 호스트 장애만 본다 (7.2)
  health_check_type         = "EC2"
  health_check_grace_period = var.health_check_grace_period

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = local.is_spot ? 0 : 100
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        # latest_version을 쓰면 Launch Template이 바뀔 때 아래 instance_refresh가 시작된다
        version = aws_launch_template.this.latest_version
      }

      dynamic "override" {
        for_each = var.instance_types

        content {
          instance_type = override.value
        }
      }

      dynamic "override" {
        for_each = var.instance_requirements == null ? [] : [var.instance_requirements]

        content {
          instance_requirements {
            vcpu_count {
              min = override.value.vcpu_min
              max = override.value.vcpu_max
            }

            memory_mib {
              min = override.value.memory_mib_min
              max = override.value.memory_mib_max
            }

            cpu_manufacturers       = override.value.cpu_manufacturers
            burstable_performance   = override.value.burstable_performance
            instance_generations    = ["current"]
            excluded_instance_types = length(override.value.excluded_instance_types) > 0 ? override.value.excluded_instance_types : null
          }
        }
      }
    }
  }

  # AMI 교체 = instance refresh (min/max healthy 100% → 한 대씩, 새 인스턴스를 먼저 띄운 뒤 종료) [D18]
  # managed termination protection 때문에 scale-in 보호 인스턴스도 교체 대상으로 지정한다 [D5]
  # ws-od는 연결이 끊기므로 출퇴근 시간대(07–09, 17–19시)를 피해 apply한다.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      min_healthy_percentage       = 100
      max_healthy_percentage       = 100
      instance_warmup              = var.health_check_grace_period
      scale_in_protected_instances = "Refresh"
      skip_matching                = true
    }
  }

  tag {
    key                 = "Name"
    value               = local.asg_name
    propagate_at_launch = true
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.tags

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    # desired는 Capacity Provider managed scaling이 관리한다 [D1]
    ignore_changes = [desired_capacity]
  }
}

# -----------------------------------------------------------------------------
# Capacity Provider (ASG 1개 전용)
# -----------------------------------------------------------------------------

resource "aws_ecs_capacity_provider" "this" {
  name = local.cp_name

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.this.arn
    managed_termination_protection = "ENABLED"
    managed_draining               = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = var.target_capacity
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = var.maximum_scaling_step_size
      instance_warmup_period    = var.instance_warmup_period
    }
  }

  tags = merge(local.tags, { Name = local.cp_name })
}
