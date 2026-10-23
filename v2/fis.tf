# =============================================================================
# AWS FIS 실험 템플릿 (fis_stages, 기본 stg) — 장애 대응 시나리오·ECS 스케줄링 검증
#   템플릿은 실행(start-experiment)하기 전까지 아무 영향이 없다.
#
#   1) websocket-task-stop      : websocket 태스크 1개 강제 종료
#                                 → 서비스 스케줄러 재배치, ALB 재등록, 클라이언트 재연결, Pub/Sub 유실 구간 확인
#   2) rest-spot-interruption   : shared Spot 인스턴스 1대에 중단 알림(2분)
#                                 → managed draining, deregistration 30s / stopTimeout 60s 안에 대체 태스크 기동 확인
#                                 (REST desired를 baseline 2보다 높여 Spot 태스크가 배치된 뒤 실행)
#   3) container-instance-drain : 클러스터 컨테이너 인스턴스 50%를 10분간 DRAINING
#                                 → distinctInstance·memberOf 제약 아래 재배치와 Capacity Provider scale-out 확인
#
#   실행 : aws fis start-experiment --experiment-template-id $(terraform output -json fis_experiment_template_ids | jq -r '.stg.websocket_task_stop')
#   중단 : aws fis stop-experiment --id <experiment-id>
#   중지 조건은 두지 않는다(source = none). prod는 variables.tf 검증에서 막는다.
# =============================================================================

locals {
  fis_stages = toset([for s in var.fis_stages : s if contains(keys(local.ecs_stages), s)])
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "fis_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["fis.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "fis" {
  count = length(local.fis_stages) > 0 ? 1 : 0

  name               = "${var.project_name}-fis"
  assume_role_policy = data.aws_iam_policy_document.fis_assume.json

  tags = {
    Name = "${var.project_name}-fis-role"
  }
}

# 대상 스테이지 클러스터·인스턴스로만 한정 (관리형 AWSFaultInjectionSimulator* 정책은 계정 전체 대상이라 쓰지 않는다)
data "aws_iam_policy_document" "fis" {
  count = length(local.fis_stages) > 0 ? 1 : 0

  statement {
    sid       = "ResolveTargets"
    actions   = ["ecs:ListTasks", "ecs:DescribeTasks", "ecs:DescribeClusters", "ecs:ListContainerInstances", "ecs:DescribeContainerInstances", "ec2:DescribeInstances", "tag:GetResources"]
    resources = ["*"]
  }

  statement {
    sid     = "StopTasksInStageClusters"
    actions = ["ecs:StopTask"]
    resources = [
      for stage in local.fis_stages : "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${module.ecs_cluster[stage].cluster_name}/*"
    ]
  }

  statement {
    sid     = "DrainStageContainerInstances"
    actions = ["ecs:UpdateContainerInstancesState"]
    resources = flatten([
      for stage in local.fis_stages : [
        module.ecs_cluster[stage].cluster_arn,
        "arn:${data.aws_partition.current.partition}:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:container-instance/${module.ecs_cluster[stage].cluster_name}/*",
      ]
    ])
  }

  statement {
    sid       = "InterruptStageSpotInstances"
    actions   = ["ec2:SendSpotInstanceInterruptions"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Stage"
      values   = tolist(local.fis_stages)
    }
  }
}

resource "aws_iam_role_policy" "fis" {
  count = length(local.fis_stages) > 0 ? 1 : 0

  name   = "fis-${join("-", sort(tolist(local.fis_stages)))}-ecs"
  role   = aws_iam_role.fis[0].id
  policy = data.aws_iam_policy_document.fis[0].json
}

# -----------------------------------------------------------------------------
# 1) websocket 태스크 1개 종료
# -----------------------------------------------------------------------------

resource "aws_fis_experiment_template" "websocket_task_stop" {
  for_each = local.fis_stages

  description = "${each.key}: stop one websocket task (scheduler re-placement, reconnect, pub/sub gap)"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "stop-websocket-task"
    action_id = "aws:ecs:stop-task"

    target {
      key   = "Tasks"
      value = "websocket-task"
    }
  }

  target {
    name           = "websocket-task"
    resource_type  = "aws:ecs:task"
    selection_mode = "COUNT(1)"

    parameters = {
      cluster = module.ecs_cluster[each.key].cluster_name
      service = "websocket"
    }
  }

  tags = {
    Name  = "${var.project_name}-${each.key}-websocket-task-stop"
    Stage = each.key
  }

  depends_on = [aws_iam_role_policy.fis]
}

# -----------------------------------------------------------------------------
# 2) shared Spot 인스턴스 중단 (태그: ecs-asg Launch Template이 붙이는 Stage·Role·Purchase)
# -----------------------------------------------------------------------------

resource "aws_fis_experiment_template" "rest_spot_interruption" {
  for_each = local.fis_stages

  description = "${each.key}: interrupt one shared Spot instance (managed draining, task replacement)"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "interrupt-shared-spot"
    action_id = "aws:ec2:send-spot-instance-interruptions"

    parameter {
      key   = "durationBeforeInterruption"
      value = "PT2M"
    }

    target {
      key   = "SpotInstances"
      value = "shared-spot-instance"
    }
  }

  target {
    name           = "shared-spot-instance"
    resource_type  = "aws:ec2:spot-instance"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Stage"
      value = each.key
    }

    resource_tag {
      key   = "Role"
      value = "shared"
    }

    resource_tag {
      key   = "Purchase"
      value = "spot"
    }

    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }

  tags = {
    Name  = "${var.project_name}-${each.key}-rest-spot-interruption"
    Stage = each.key
  }

  depends_on = [aws_iam_role_policy.fis]
}

# -----------------------------------------------------------------------------
# 3) 컨테이너 인스턴스 드레인
# -----------------------------------------------------------------------------

resource "aws_fis_experiment_template" "container_instance_drain" {
  for_each = local.fis_stages

  description = "${each.key}: drain 50% of container instances for 10 minutes (re-placement, capacity provider scale-out)"
  role_arn    = aws_iam_role.fis[0].arn

  stop_condition {
    source = "none"
  }

  action {
    name      = "drain-container-instances"
    action_id = "aws:ecs:drain-container-instances"

    parameter {
      key   = "drainagePercentage"
      value = "50"
    }

    parameter {
      key   = "duration"
      value = "PT10M"
    }

    target {
      key   = "Clusters"
      value = "stage-cluster"
    }
  }

  target {
    name           = "stage-cluster"
    resource_type  = "aws:ecs:cluster"
    selection_mode = "ALL"
    resource_arns  = [module.ecs_cluster[each.key].cluster_arn]
  }

  tags = {
    Name  = "${var.project_name}-${each.key}-container-instance-drain"
    Stage = each.key
  }

  depends_on = [aws_iam_role_policy.fis]
}
