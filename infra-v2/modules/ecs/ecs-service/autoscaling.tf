# =============================================================================
# Service Auto Scaling (태스크 단계)
#   설계 근거: issues/ecs-asg-by-cluster-service.md 7.1
#   - 동적 정책: CPU target tracking(시작값) 또는 커스텀 지표(예: 태스크당 STOMP 세션 수)
#   - 예약 정책: 출퇴근 피크 10분 전에 min을 올린다 (예측 가능한 부하) [D14]
#   - WebSocket은 disable_scale_in = true → 자동 scale-in으로 연결을 끊지 않는다
#   - 인스턴스 수는 Capacity Provider managed scaling이 태스크 수를 따라 맞춘다 (ASG 직접 스케일링 금지)
# =============================================================================

locals {
  as_enabled   = var.autoscaling != null
  as_cpu       = local.as_enabled ? var.autoscaling.cpu_target != null : false
  as_custom    = local.as_enabled ? var.autoscaling.custom_metric != null : false
  as_schedules = { for s in try(var.autoscaling.scheduled, []) : s.name => s if local.as_enabled }
}

resource "aws_appautoscaling_target" "this" {
  count = local.as_enabled ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.autoscaling.min_capacity
  max_capacity       = var.autoscaling.max_capacity

  tags = local.tags
}

resource "aws_appautoscaling_policy" "cpu" {
  count = local.as_cpu ? 1 : 0

  name               = "${local.full_name}-cpu-${var.autoscaling.cpu_target}"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.cpu_target
    disable_scale_in   = var.autoscaling.disable_scale_in
    scale_in_cooldown  = var.autoscaling.scale_in_cooldown
    scale_out_cooldown = var.autoscaling.scale_out_cooldown

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "custom" {
  count = local.as_custom ? 1 : 0

  name               = "${local.full_name}-${lower(var.autoscaling.custom_metric.metric_name)}"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.custom_metric.target
    disable_scale_in   = var.autoscaling.disable_scale_in
    scale_in_cooldown  = var.autoscaling.scale_in_cooldown
    scale_out_cooldown = var.autoscaling.scale_out_cooldown

    customized_metric_specification {
      namespace   = var.autoscaling.custom_metric.namespace
      metric_name = var.autoscaling.custom_metric.metric_name
      statistic   = var.autoscaling.custom_metric.statistic
      unit        = var.autoscaling.custom_metric.unit

      dynamic "dimensions" {
        for_each = var.autoscaling.custom_metric.dimensions

        content {
          name  = dimensions.key
          value = dimensions.value
        }
      }
    }
  }
}

resource "aws_appautoscaling_scheduled_action" "this" {
  for_each = local.as_schedules

  name               = "${local.full_name}-${each.key}"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  schedule           = each.value.schedule
  timezone           = each.value.timezone

  scalable_target_action {
    min_capacity = each.value.min_capacity
    max_capacity = each.value.max_capacity
  }
}
