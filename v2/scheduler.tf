# =============================================================================
# Dev EC2 운영 시간 스케줄 — EventBridge Scheduler
#   - 대상 1: compute.tf의 aws_instance.host["dev"] (MySQL·Redis compose 호스트)
#   - 대상 2: dev ECS 서비스(rest·websocket·frontend ...) desiredCount → 아래 "Dev ECS 서비스" 절 참고
#             Spot ASG 인스턴스는 직접 끄지 않는다. 태스크가 0개가 되면 managed scaling이 0대로 줄인다.
#   - 기본값: 매일 09:00 시작 / 24:00(=00:00) 중지, Asia/Seoul 기준 (variables.tf의 dev_instance_schedule)
#   - Scheduler universal target(aws-sdk:ec2:startInstances / stopInstances)로 직접 호출 → Lambda 없음
#   - 인스턴스 실행 상태는 Terraform이 관리하지 않으므로 중지돼 있어도 plan에 drift가 생기지 않는다
#   - 재시작 후 데이터 EBS는 fstab(nofail)로, 컨테이너는 docker enable + restart: unless-stopped로 복구된다
#   - 스케줄을 끄려면 dev_instance_schedule = { enabled = false } 후 apply
# =============================================================================

locals {
  dev_instance_schedules = var.dev_instance_schedule.enabled ? {
    start = {
      action      = "startInstances"
      expression  = var.dev_instance_schedule.start_cron
      description = "Start V2 dev EC2 host (operating hours begin)"
    }
    stop = {
      action      = "stopInstances"
      expression  = var.dev_instance_schedule.stop_cron
      description = "Stop V2 dev EC2 host (operating hours end)"
    }
  } : {}
}

data "aws_iam_policy_document" "dev_instance_scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "dev_instance_scheduler" {
  count = var.dev_instance_schedule.enabled ? 1 : 0

  name               = "${var.project_name}-dev-ec2-scheduler"
  description        = "EventBridge Scheduler role that starts/stops the V2 dev EC2 host and scales dev ECS services"
  assume_role_policy = data.aws_iam_policy_document.dev_instance_scheduler_assume.json
}

data "aws_iam_policy_document" "dev_instance_scheduler" {
  statement {
    sid       = "StartStopDevHostOnly"
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [aws_instance.host["dev"].arn]
  }
}

resource "aws_iam_role_policy" "dev_instance_scheduler" {
  count = var.dev_instance_schedule.enabled ? 1 : 0

  name   = "start-stop-dev-host"
  role   = aws_iam_role.dev_instance_scheduler[0].id
  policy = data.aws_iam_policy_document.dev_instance_scheduler.json
}

resource "aws_scheduler_schedule" "dev_instance" {
  for_each = local.dev_instance_schedules

  name        = "${var.project_name}-dev-ec2-${each.key}"
  description = each.value.description

  schedule_expression          = each.value.expression
  schedule_expression_timezone = var.dev_instance_schedule.timezone
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ec2:${each.value.action}"
    role_arn = aws_iam_role.dev_instance_scheduler[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.host["dev"].id] })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }
}

# =============================================================================
# Dev ECS 서비스 운영 시간 스케줄
#   왜 필요한가
#     - dev Spot ASG(moyeota-v2-dev-shared-spot)의 인스턴스 수는 Capacity Provider managed scaling이 정한다.
#       서비스가 desiredCount=1을 유지하는 한 managed termination protection 때문에 인스턴스가 줄지 않는다.
#     - 그래서 ASG가 아니라 서비스 desiredCount를 0으로 내린다 → 태스크 0개 → managed scaling이 ASG를 0대로 축소.
#       (ASG desired/min을 직접 0으로 내리면 managed scaling이 곧바로 다시 늘린다)
#   동작
#     - ecs_stop_cron  (기본 23:55) : UpdateService DesiredCount=0  — 호스트(MySQL·Redis) 중지 전에 앱부터 내린다
#     - ecs_start_cron (기본 09:05) : UpdateService DesiredCount=<locals의 desired> — 호스트 기동 후에 앱을 올린다
#   drift
#     - ecs-service 모듈이 desired_count를 ignore_changes 하므로 야간에 apply해도 Terraform이 1로 되돌리지 않는다.
#   Alloy(DAEMON)
#     - DAEMON 태스크는 managed scaling 계산·scale-in 보호에서 제외되므로 따로 내리지 않는다.
#       적용 후 야간에 Spot이 0대로 줄지 않으면 alloy 서비스도 이 목록에 추가할 것.
# =============================================================================

locals {
  # "dev-rest" 같은 키 중 dev 스테이지 서비스만 (ecs_container_images에 이미지가 있는 서비스만 존재)
  dev_ecs_scheduled_services = var.dev_instance_schedule.enabled && var.dev_instance_schedule.ecs_enabled ? {
    for k, s in local.ecs_service_instances : k => s if s.stage == "dev"
  } : {}

  # 서비스 × {start, stop}
  dev_ecs_service_schedules = merge([
    for k, s in local.dev_ecs_scheduled_services : {
      "${s.service}-start" = {
        service_key   = k
        service       = s.service
        desired_count = s.desired
        expression    = var.dev_instance_schedule.ecs_start_cron
        description   = "Scale V2 dev ECS service ${s.service} to ${s.desired} (operating hours begin)"
      }
      "${s.service}-stop" = {
        service_key   = k
        service       = s.service
        desired_count = 0
        expression    = var.dev_instance_schedule.ecs_stop_cron
        description   = "Scale V2 dev ECS service ${s.service} to 0 (operating hours end)"
      }
    }
  ]...)
}

data "aws_iam_policy_document" "dev_ecs_scheduler" {
  count = length(local.dev_ecs_scheduled_services) > 0 ? 1 : 0

  statement {
    sid       = "ScaleDevEcsServicesOnly"
    actions   = ["ecs:UpdateService"]
    resources = [for k, s in local.dev_ecs_scheduled_services : module.ecs_service[k].service_arn]
  }
}

resource "aws_iam_role_policy" "dev_ecs_scheduler" {
  count = length(local.dev_ecs_scheduled_services) > 0 ? 1 : 0

  name   = "scale-dev-ecs-services"
  role   = aws_iam_role.dev_instance_scheduler[0].id
  policy = data.aws_iam_policy_document.dev_ecs_scheduler[0].json
}

resource "aws_scheduler_schedule" "dev_ecs_service" {
  for_each = local.dev_ecs_service_schedules

  name        = "${var.project_name}-dev-ecs-${each.key}"
  description = each.value.description

  schedule_expression          = each.value.expression
  schedule_expression_timezone = var.dev_instance_schedule.timezone
  state                        = "ENABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = "arn:${data.aws_partition.current.partition}:scheduler:::aws-sdk:ecs:updateService"
    role_arn = aws_iam_role.dev_instance_scheduler[0].arn
    input = jsonencode({
      Cluster      = module.ecs_cluster["dev"].cluster_name
      Service      = module.ecs_service[each.value.service_key].service_name
      DesiredCount = each.value.desired_count
    })

    retry_policy {
      maximum_event_age_in_seconds = 3600
      maximum_retry_attempts       = 3
    }
  }

  # 권한이 붙기 전에 첫 실행이 돌지 않도록
  depends_on = [aws_iam_role_policy.dev_ecs_scheduler]
}
