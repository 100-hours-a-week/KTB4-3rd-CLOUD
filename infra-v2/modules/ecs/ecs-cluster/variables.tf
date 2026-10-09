variable "project_name" {
  description = "리소스 이름 접두어. 클러스터 이름(<project_name>-<stage>)과 설정 경로(/<project_name>/<stage>/*)에 쓰인다."
  type        = string
  default     = "moyeota-v2"
}

variable "stage" {
  description = "스테이지 이름"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.stage)
    error_message = "stage must be one of dev, stg, prod."
  }
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

variable "container_insights" {
  description = "Container Insights 수준: disabled | enabled | enhanced"
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "enabled", "enhanced"], var.container_insights)
    error_message = "container_insights must be one of disabled, enabled, enhanced."
  }
}

# ---------------------------------------------------------------------------
# Capacity Provider 연결
#   ASG·Launch Template·Capacity Provider는 modules/ecs/ecs-asg가 만든다.
#   이 모듈은 만들어진 Capacity Provider를 클러스터에 등록만 한다.
# ---------------------------------------------------------------------------

variable "capacity_providers" {
  description = "클러스터에 연결할 Capacity Provider 이름 목록 (ecs-asg 모듈 출력)"
  type        = list(string)
  default     = []

  # 한 전략 안에 ASG Capacity Provider와 Fargate Capacity Provider를 섞을 수 없다. [D1]
  validation {
    condition = (
      alltrue([for cp in var.capacity_providers : contains(["FARGATE", "FARGATE_SPOT"], cp)]) ||
      !anytrue([for cp in var.capacity_providers : contains(["FARGATE", "FARGATE_SPOT"], cp)])
    )
    error_message = "ASG capacity providers and FARGATE/FARGATE_SPOT must not be mixed in one cluster configuration."
  }
}

variable "default_capacity_provider_strategy" {
  description = <<-EOT
    클러스터 기본 Capacity Provider 전략. 비워 두거나 general-od(dev는 shared-spot)로 둔다.
    REST·WebSocket 서비스는 항상 서비스에서 전략을 명시한다.
  EOT
  type = list(object({
    capacity_provider = string
    weight            = optional(number, 1)
    base              = optional(number, 0)
  }))
  default = []

  validation {
    condition = alltrue([
      for s in var.default_capacity_provider_strategy : contains(var.capacity_providers, s.capacity_provider)
    ])
    error_message = "Every default strategy capacity_provider must be listed in capacity_providers."
  }

  # base는 전략 안의 provider 하나에만 둘 수 있다. [D3]
  validation {
    condition     = length([for s in var.default_capacity_provider_strategy : s if s.base > 0]) <= 1
    error_message = "Only one capacity provider in a strategy can have a base greater than 0."
  }
}

# ---------------------------------------------------------------------------
# EC2 컨테이너 인스턴스 공통 (인스턴스 Role · 인스턴스 SG)
#   스테이지당 1개를 두고 같은 스테이지의 ASG끼리 공유한다.
# ---------------------------------------------------------------------------

variable "vpc_id" {
  description = "컨테이너 인스턴스 보안 그룹을 만들 VPC"
  type        = string
}

# ---------------------------------------------------------------------------
# 서비스별 Task Role
# ---------------------------------------------------------------------------

variable "services" {
  description = "이 클러스터에서 운영할 애플리케이션(ECS Service) 목록. 서비스마다 Task Role이 하나씩 만들어진다."
  type        = list(string)
  default     = ["rest", "websocket", "frontend", "fastapi"]
}

# ---------------------------------------------------------------------------
# ECS Exec
# ---------------------------------------------------------------------------

variable "enable_execute_command" {
  description = "ECS Exec 사용 여부. true면 Exec 로그 그룹, Task Role의 ssmmessages 권한, 운영자용 Exec 정책이 만들어진다."
  type        = bool
  default     = true
}

variable "exec_log_retention_days" {
  description = "ECS Exec 세션 로그 보관 기간(일)"
  type        = number
  default     = 30
}

# ---------------------------------------------------------------------------
# CD (GitHub Actions OIDC)
# ---------------------------------------------------------------------------

variable "github_oidc_provider_arn" {
  description = "계정에 이미 존재하는 GitHub Actions OIDC Provider ARN (V1 infra/iam.tf에서 생성)"
  type        = string
}

variable "github_oidc_subjects" {
  description = <<-EOT
    이 스테이지 배포 Role을 Assume할 수 있는 GitHub OIDC sub 값.
    예) repo:100-hours-a-week/KTB4-3rd-CLOUD:environment:prod
    워크플로 job에 environment를 지정하면 sub가 environment 기준으로 발급된다.
  EOT
  type = list(string)

  validation {
    condition     = length(var.github_oidc_subjects) > 0
    error_message = "At least one github_oidc_subjects value is required."
  }
}

variable "tags" {
  description = "추가 태그"
  type        = map(string)
  default     = {}
}
