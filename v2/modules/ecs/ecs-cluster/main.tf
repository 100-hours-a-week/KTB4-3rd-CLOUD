# =============================================================================
# ecs-cluster : 스테이지 경계
#   - 1 스테이지 = 1 ECS Cluster (moyeota-v2-<stage>)
#   - 스테이지 격리 리소스를 한 곳에 모은다
#       · Service Connect 네임스페이스 (<stage>.moyeota-v2.local)
#       · ECS Exec 로그 / 운영자 정책
#       · 컨테이너 인스턴스 Role·SG (자기 클러스터에만 등록)        → instance.tf
#       · Task Execution Role / Task Role / Deploy Role             → iam.tf
#   - 용량(ASG·Launch Template·Capacity Provider)은 ecs-asg 모듈이 만들고,
#     여기서는 aws_ecs_cluster_capacity_providers로 클러스터에 등록만 한다.
# =============================================================================

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  name       = "${var.project_name}-${var.stage}"
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  # 스테이지별 설정 저장소 경로: /moyeota-v2/prod/* (SSM), moyeota-v2/prod/* (Secrets Manager)
  ssm_parameter_arn = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${var.project_name}/${var.stage}/*"
  secret_arn        = "arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:${var.project_name}/${var.stage}/*"

  # 이 클러스터 안의 서비스·태스크·컨테이너 인스턴스만 가리키는 ARN 패턴
  service_arn_pattern            = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${local.name}/*"
  task_arn_pattern               = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task/${local.name}/*"
  container_instance_arn_pattern = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:container-instance/${local.name}/*"

  tags = merge(var.tags, { Stage = var.stage })
}

# ---------------------------------------------------------------------------
# Service Connect 네임스페이스 (스테이지별 분리 → Dev 서비스가 Prod 서비스를 이름으로 호출할 수 없음)
# ---------------------------------------------------------------------------

resource "aws_service_discovery_http_namespace" "this" {
  name        = "${var.stage}.${var.project_name}.local"
  description = "Service Connect namespace for ${local.name}"
  tags        = local.tags
}

# ---------------------------------------------------------------------------
# ECS Exec 세션 로그
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "exec" {
  count = var.enable_execute_command ? 1 : 0

  name              = "/ecs/${local.name}/exec"
  retention_in_days = var.exec_log_retention_days
  tags              = local.tags
}

# ---------------------------------------------------------------------------
# ECS Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "this" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }

  service_connect_defaults {
    namespace = aws_service_discovery_http_namespace.this.arn
  }

  dynamic "configuration" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      execute_command_configuration {
        logging = "OVERRIDE"

        log_configuration {
          cloud_watch_log_group_name = aws_cloudwatch_log_group.exec[0].name
        }
      }
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Capacity Provider 등록
#   managed scaling을 켠 Capacity Provider는 클러스터 하나에만 연결된다. [D2]
#   → ecs-asg가 만든 ASG는 구조적으로 이 스테이지를 넘을 수 없다.
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster_capacity_providers" "this" {
  count = length(var.capacity_providers) > 0 ? 1 : 0

  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = var.capacity_providers

  dynamic "default_capacity_provider_strategy" {
    for_each = var.default_capacity_provider_strategy

    content {
      capacity_provider = default_capacity_provider_strategy.value.capacity_provider
      weight            = default_capacity_provider_strategy.value.weight
      base              = default_capacity_provider_strategy.value.base
    }
  }
}
