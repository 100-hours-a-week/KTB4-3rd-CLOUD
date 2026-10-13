# =============================================================================
# Dev EC2 운영 시간 스케줄 — EventBridge Scheduler
#   - 대상: compute.tf의 aws_instance.host["dev"] (MySQL·Redis compose 호스트)
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
  description        = "EventBridge Scheduler role that starts/stops only the V2 dev EC2 host"
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
