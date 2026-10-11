variable "project_name" {
  type    = string
  default = "moyeota-v2"
}

variable "stage" {
  type = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.stage)
    error_message = "stage must be one of dev, stg, prod."
  }
}

variable "name" {
  description = "ECS Service 이름 = 컨테이너 이름 (rest | websocket | frontend | fastapi)"
  type        = string
}

# ---------------------------------------------------------------------------
# Cluster (ecs-cluster 출력)
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Service Auto Scaling resource_id(service/<cluster>/<service>)에 쓰인다."
  type        = string
}

variable "cluster_arn" {
  description = "ecs-cluster의 capacity_ready_cluster_arn (Capacity Provider 등록 이후 값)"
  type        = string
}

variable "execution_role_arn" {
  description = "스테이지 Task Execution Role (/<project>/<stage>/* 설정만 읽기 가능)"
  type        = string
}

variable "task_role_arn" {
  description = "서비스 전용 Task Role"
  type        = string
}

# ---------------------------------------------------------------------------
# 네트워크 (awsvpc)
# ---------------------------------------------------------------------------

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "태스크 ENI 서브넷. ASG와 같은 서브넷(단일 AZ)을 쓴다."
  type        = list(string)
}

# ---------------------------------------------------------------------------
# Task Definition
#   CI(Deploy Role)가 이미지 digest로 새 revision을 등록하므로 서비스는 task_definition 변경을 무시한다.
#   여기서 만드는 revision은 최초 부트스트랩용이다.
# ---------------------------------------------------------------------------

variable "image" {
  description = "컨테이너 이미지. 태그 대신 image@sha256:<digest> 권장 (스테이지 간 동일 digest Promote)"
  type        = string
}

variable "task_cpu" {
  description = "task CPU units (1024 = 1 vCPU)"
  type        = number
}

variable "task_memory" {
  description = "task memory (MiB). ECS 배치 판단에 이 값이 쓰인다."
  type        = number
}

variable "container_cpu" {
  description = "앱 컨테이너 CPU units (단일 앱 컨테이너면 task_cpu와 같게)"
  type        = number
}

variable "container_memory" {
  description = "앱 컨테이너 hard limit (MiB). memoryReservation은 두지 않는다."
  type        = number
}

variable "container_port" {
  description = "앱 포트 (ALB 대상 포트)"
  type        = number
}

variable "additional_container_ports" {
  description = "추가 노출 포트 (예: Spring 관리 포트 8090)"
  type        = list(number)
  default     = []
}

variable "environment" {
  description = "일반 환경 변수"
  type        = map(string)
  default     = {}
}

variable "secrets" {
  description = "환경 변수 이름 → SSM/Secrets Manager ARN. 반드시 자기 스테이지 경로(/<project>/<stage>/*)만 넣는다."
  type        = map(string)
  default     = {}
}

variable "stop_timeout_seconds" {
  description = "컨테이너 stopTimeout. Spot 2분 알림 안에 graceful shutdown이 끝나도록 120초 미만."
  type        = number
  default     = 60

  validation {
    condition     = var.stop_timeout_seconds >= 1 && var.stop_timeout_seconds < 120
    error_message = "stop_timeout_seconds must be between 1 and 119."
  }
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# ---------------------------------------------------------------------------
# 배치: Capacity Provider 전략 + placement
# ---------------------------------------------------------------------------

variable "capacity_provider_strategy" {
  description = <<-EOT
    서비스 Capacity Provider 전략 (ecs-asg 출력 이름).
    예) REST prod: [{ rest-od, base 2, weight 0 }, { rest-spot, weight 1 }]
  EOT
  type = list(object({
    capacity_provider = string
    base              = optional(number, 0)
    weight            = optional(number, 1)
  }))

  validation {
    condition     = length(var.capacity_provider_strategy) > 0
    error_message = "capacity_provider_strategy must not be empty; REST/WebSocket must always state their strategy."
  }

  # base는 전략 안의 provider 하나에만 둘 수 있다 [D3]
  validation {
    condition     = length([for s in var.capacity_provider_strategy : s if s.base > 0]) <= 1
    error_message = "Only one capacity provider in a strategy can have a base greater than 0."
  }

  # 한 전략 안에 ASG Capacity Provider와 Fargate를 섞을 수 없다 [D1]
  validation {
    condition = (
      alltrue([for s in var.capacity_provider_strategy : contains(["FARGATE", "FARGATE_SPOT"], s.capacity_provider)]) ||
      !anytrue([for s in var.capacity_provider_strategy : contains(["FARGATE", "FARGATE_SPOT"], s.capacity_provider)])
    )
    error_message = "ASG capacity providers and FARGATE/FARGATE_SPOT must not be mixed in one strategy."
  }

  # 모든 provider의 weight가 0이면 base 이후 태스크를 배치할 곳이 없다
  validation {
    condition     = anytrue([for s in var.capacity_provider_strategy : s.weight > 0])
    error_message = "At least one capacity provider must have weight > 0."
  }
}

variable "placement_role" {
  description = "memberOf(attribute:role == <값>) placement constraint. 클러스터 기본 전략으로 잘못 배포돼도 다른 역할 호스트에 올라가지 않게 한다. [D20]"
  type        = string
  default     = null
  nullable    = true
}

variable "distinct_instance" {
  description = "필수 replica를 서로 다른 EC2에 둔다 (REST·WebSocket)"
  type        = bool
  default     = false
}

variable "placement_strategies" {
  description = "ordered_placement_strategy (예: [{ type = \"binpack\", field = \"memory\" }])"
  type = list(object({
    type  = string
    field = optional(string)
  }))
  default = []
}

# ---------------------------------------------------------------------------
# 서비스 · 배포
# ---------------------------------------------------------------------------

variable "desired_count" {
  description = "최초 desired. 이후에는 Service Auto Scaling이 관리한다 (ignore_changes)."
  type        = number
}

variable "deployment_minimum_healthy_percent" {
  type    = number
  default = 100
}

variable "deployment_maximum_percent" {
  description = "200이면 기존 태스크를 멈추기 전에 새 태스크를 띄운다 → 호스트 +1 필요 [D17]"
  type        = number
  default     = 200
}

variable "health_check_grace_period_seconds" {
  description = "Spring 기동 시간을 고려한 ALB 헬스체크 유예"
  type        = number
  default     = 120
}

variable "enable_execute_command" {
  type    = bool
  default = true
}

# ---------------------------------------------------------------------------
# ALB 연결 (null이면 ALB 없이 실행 — dev)
# ---------------------------------------------------------------------------

variable "load_balancer" {
  description = <<-EOT
    서비스 전용 ip Target Group + Listener Rule.
    ECS Service가 Target Group을 쓰려면 Target Group이 ALB(Listener Rule)에 연결돼 있어야 한다.
  EOT
  type = object({
    alb_security_group_id = string
    listener_arn          = string
    priority              = number
    path_patterns         = list(string)
    host_headers          = optional(list(string), [])
    http_headers          = optional(map(list(string)), {})
    health_check_path     = string
    health_check_port     = optional(number) # null이면 traffic-port
    health_check_matcher  = optional(string, "200-399")
    deregistration_delay  = optional(number, 30)
  })
  default  = null
  nullable = true
}

# ---------------------------------------------------------------------------
# Service Auto Scaling (태스크 단계)
# ---------------------------------------------------------------------------

variable "autoscaling" {
  description = <<-EOT
    null이면 Auto Scaling 없이 desired_count 고정.
    cpu_target / custom_metric 중 필요한 것을 지정한다. scheduled는 KST 기준 예약 정책.
  EOT
  type = object({
    min_capacity       = number
    max_capacity       = number
    cpu_target         = optional(number)
    disable_scale_in   = optional(bool, false)
    scale_in_cooldown  = optional(number, 300)
    scale_out_cooldown = optional(number, 60)
    custom_metric = optional(object({
      namespace   = string
      metric_name = string
      statistic   = optional(string, "Average")
      unit        = optional(string)
      dimensions  = optional(map(string), {})
      target      = number
    }))
    scheduled = optional(list(object({
      name         = string
      schedule     = string
      timezone     = optional(string, "Asia/Seoul")
      min_capacity = optional(number)
      max_capacity = optional(number)
    })), [])
  })
  default  = null
  nullable = true

  validation {
    condition     = var.autoscaling == null || try(var.autoscaling.min_capacity <= var.autoscaling.max_capacity, false)
    error_message = "autoscaling.min_capacity must be <= max_capacity."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
