variable "name" {
  description = "ASG 이름: <project>-<stage>-<role>-<purchase> (예: moyeota-v2-prod-rest-spot). Launch Template은 -lt, Capacity Provider는 -cp를 붙인다."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]{1,200}$", var.name)) && !can(regex("^(aws|ecs|fargate)", lower(var.name)))
    error_message = "name must be alphanumeric/hyphen and must not start with aws, ecs or fargate (capacity provider naming rule)."
  }
}

variable "stage" {
  description = "스테이지 (Stage 태그)"
  type        = string

  validation {
    condition     = contains(["dev", "stg", "prod"], var.stage)
    error_message = "stage must be one of dev, stg, prod."
  }
}

variable "cluster_name" {
  description = "user data ECS_CLUSTER 값. 컨테이너 인스턴스는 이 클러스터 하나에만 등록된다. (ecs-cluster 출력)"
  type        = string
}

variable "role" {
  description = "ECS 인스턴스 속성 role. 서비스의 memberOf(attribute:role == <role>) placement constraint와 짝을 이룬다."
  type        = string

  validation {
    condition     = contains(["rest", "ws", "general", "shared"], var.role)
    error_message = "role must be one of rest, ws, general, shared."
  }
}

variable "purchase" {
  description = "유형별 인스턴스: od(On-Demand) | spot"
  type        = string

  validation {
    condition     = contains(["od", "spot"], var.purchase)
    error_message = "purchase must be od or spot."
  }
}

# ---------------------------------------------------------------------------
# 인스턴스 타입: instance_types(고정 목록) 또는 instance_requirements(속성 기반) 중 하나
#   Spot은 속성 기반으로 10개 이상 타입을 후보로 둔다. [D7] [B2]
# ---------------------------------------------------------------------------

variable "instance_types" {
  description = "고정 인스턴스 타입 목록 (On-Demand ASG). instance_requirements와 함께 쓰지 않는다."
  type        = list(string)
  default     = []
}

variable "instance_requirements" {
  description = "속성 기반 인스턴스 선택 (Spot ASG). x86 이미지 전제라 cpu_manufacturers는 intel/amd로 둔다."
  type = object({
    vcpu_min          = number
    vcpu_max          = number
    memory_mib_min    = number
    memory_mib_max    = number
    cpu_manufacturers = optional(list(string), ["intel", "amd"])
    # t3/t3a 계열을 후보에 넣으려면 included여야 한다 (API 기본값은 excluded)
    burstable_performance   = optional(string, "included")
    excluded_instance_types = optional(list(string), [])
  })
  default  = null
  nullable = true

  validation {
    condition     = (var.instance_requirements == null) != (length(var.instance_types) == 0)
    error_message = "Set exactly one of instance_types or instance_requirements."
  }
}

variable "subnet_ids" {
  description = "ASG vpc_zone_identifier. Multi-AZ 전환 시 app-c 서브넷만 추가하면 된다."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "At least one subnet is required."
  }
}

variable "min_size" {
  type = number
}

variable "max_size" {
  description = "On-Demand ASG는 롤링 배포 여유를 위해 min + 1 이상으로 둔다. [D17]"
  type        = number

  validation {
    condition     = var.max_size >= 1 && var.max_size >= var.min_size
    error_message = "max_size must be at least 1 and not smaller than min_size."
  }
}

variable "instance_profile_arn" {
  description = "스테이지 공용 인스턴스 프로파일 (ecs-cluster 출력)"
  type        = string
}

variable "security_group_ids" {
  description = "인스턴스 SG (ecs-cluster 출력)"
  type        = list(string)
}

# ---------------------------------------------------------------------------
# Launch Template
# ---------------------------------------------------------------------------

variable "ami_ssm_parameter_name" {
  description = "ECS-optimized AMI SSM 파라미터 (Amazon Linux 2023, x86_64)"
  type        = string
  default     = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

variable "root_volume_size_gib" {
  description = "루트 볼륨(gp3, 암호화). ECS 최적화 AMI는 최소 30GiB."
  type        = number
  default     = 30
}

variable "container_stop_timeout_seconds" {
  description = "ECS_CONTAINER_STOP_TIMEOUT. Spring graceful shutdown용, Spot 2분 알림 안에 끝나도록 120초 미만."
  type        = number
  default     = 60

  validation {
    condition     = var.container_stop_timeout_seconds >= 30 && var.container_stop_timeout_seconds < 120
    error_message = "container_stop_timeout_seconds must be >= 30 and < 120."
  }
}

# ---------------------------------------------------------------------------
# ASG · Capacity Provider
# ---------------------------------------------------------------------------

variable "health_check_grace_period" {
  type    = number
  default = 300
}

variable "target_capacity" {
  description = "managed scaling target capacity(%). 100이면 여유 호스트 없이 운영하고 0대까지 줄일 수 있다. [D2] [B1]"
  type        = number
  default     = 100

  validation {
    condition     = var.target_capacity >= 1 && var.target_capacity <= 100
    error_message = "target_capacity must be between 1 and 100."
  }
}

variable "maximum_scaling_step_size" {
  type    = number
  default = 2
}

variable "instance_warmup_period" {
  type    = number
  default = 300
}

variable "tags" {
  description = "추가 태그 (common_tags는 provider default_tags로 붙는다)"
  type        = map(string)
  default     = {}
}
