variable "project_name" {
  description = "리소스 이름 접두어. 클러스터 이름(<project_name>-<stage>)에 쓰인다."
  type        = string
  default     = "moyeota-v2"
}

variable "config_path_prefix" {
  description = "설정 저장 경로 접두어 (앞뒤 슬래시 없이, 예: moyeota/v2). Execution Role은 /<config_path_prefix>/<stage>/* 만 읽는다."
  type        = string
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
    예) repo:100-hours-a-week@167328634/KTB4-3rd-BE@1344695611:environment:dev (불변 sub 형식)
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
