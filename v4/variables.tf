variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "로컬 AWS 프로필. null이면 환경 변수(AWS_PROFILE)를 쓴다."
  type        = string
  default     = null
}

variable "v2_project_name" {
  description = "공유하는 V2 리소스(서브넷, ALB, RDS, SG)를 이름으로 찾는 접두사. v4 리소스 이름은 local.name_prefix를 쓴다."
  type        = string
  default     = "moyeota-v2"
}

variable "vpc_id" {
  description = "V2와 공유하는 VPC."
  type        = string
}

variable "app_subnet_cidrs" {
  description = "v4 앱 호스트·데이터 호스트용 private 서브넷. 키는 AZ 접미사(a, c)다. VPC에서 쓰지 않는 대역이어야 한다."
  type        = map(string)

  validation {
    condition     = length(setsubtract(keys(var.app_subnet_cidrs), ["a", "c"])) == 0 && length(var.app_subnet_cidrs) == 2
    error_message = "app_subnet_cidrs는 a, c 두 키만 가진다."
  }
}

variable "v2_config_path" {
  description = "V2가 관리하는 prod 앱 시크릿 SSM 경로 (앞뒤 슬래시 없이). Kakao, JWT, DB 등 앱 시크릿을 그대로 읽는다."
  type        = string
  default     = "moyeota/v2/prod"
}

variable "v4_config_path" {
  description = "v4가 쓰는 SSM 경로 (앞뒤 슬래시 없이). 데이터 호스트 접속 정보처럼 V2 값과 겹치면 안 되는 값을 둔다."
  type        = string
  default     = "moyeota/v4/prod"
}

variable "images_bucket" {
  description = "앱 이미지 버킷 (V2 소유)."
  type        = string
  default     = "moyeota-prod-images"
}

variable "image_object_prefixes" {
  description = "rest가 읽고 쓰는 이미지 버킷 prefix. tmp(업로드 임시) · profile(공개) · meter·transfer(정산, 비공개)."
  type        = list(string)
  default     = ["tmp", "profile", "meter", "transfer"]
}

variable "github_org" {
  type    = string
  default = "100-hours-a-week"
}

variable "github_org_id" {
  description = "GitHub org 불변 ID. OIDC 불변 sub 형식(repo:<org>@<org_id>/<repo>@<repo_id>:...)에 쓰인다."
  type        = string
  default     = "167328634"
}

variable "github_repository_ids" {
  description = "배포 Role을 Assume할 레포 → 불변 repo ID. 확인: gh api repos/<org>/<repo> --jq .id"
  type        = map(string)
  default = {
    "KTB4-3rd-BE" = "1344695611"
    "KTB4-3rd-FE" = "1344690549"
    "KTB4-3rd-AI" = "1344696058"
  }
}

variable "github_deploy_environment" {
  description = "CD job의 GitHub Environment 이름. 앱 레포는 prod 배포에 production environment(승인 규칙)를 쓴다."
  type        = string
  default     = "production"
}

variable "data_host_instance_type" {
  description = "데이터 호스트 타입. Kafka(heap 768MiB, 한도 1280MiB) + MongoDB(768MiB) + Redis(256MiB)가 들어가야 한다."
  type        = string
  default     = "t3.medium"
}

variable "data_host_ip_offset" {
  description = "데이터 호스트 고정 사설 IP의 서브넷 내 위치 (app-a 서브넷 cidrhost 번호). AWS 예약(0~3)과 마지막 주소는 피한다."
  type        = number
  default     = 10

  validation {
    condition     = var.data_host_ip_offset >= 4 && var.data_host_ip_offset <= 250
    error_message = "data_host_ip_offset은 4~250 사이여야 한다."
  }
}

variable "data_host_images" {
  description = "데이터 호스트 컨테이너 이미지. 고정 태그를 쓰고 latest를 쓰지 않는다. Kafka는 V2 dev·stg MSK와 같은 4.1 계열, MongoDB는 dev·stg와 같은 8.0이다."
  type = object({
    kafka = string
    mongo = string
    redis = string
  })
  default = {
    kafka = "apache/kafka:4.1.2"
    mongo = "mongo:8.0"
    redis = "redis:7.2"
  }

  validation {
    condition     = alltrue([for image in values(var.data_host_images) : !endswith(image, ":latest") && strcontains(image, ":")])
    error_message = "data_host_images는 고정 태그를 써야 한다 (latest 금지)."
  }
}

variable "data_host_data_gib" {
  description = "데이터 EBS 크기(GiB). Kafka 로그(파티션당 256MiB 상한)와 MongoDB 데이터를 둔다."
  type        = number
  default     = 30
}

variable "data_host_snapshot_retain_days" {
  description = "데이터 EBS 일일 스냅샷 보관 개수."
  type        = number
  default     = 7
}

variable "image_digests" {
  description = "첫 배포(부트스트랩 revision) 이미지 digest. 이후 이미지는 CD가 새 revision으로 반영한다. V3 prod 값(v3/helm/app-values/prod)으로 시작한다."
  type = object({
    be = string
    fe = string
    ai = string
  })

  validation {
    condition     = alltrue([for d in values(var.image_digests) : can(regex("^sha256:[0-9a-f]{64}$", d))])
    error_message = "image_digests는 sha256:<64자리 hex> 형식이어야 한다."
  }
}

variable "spot_instance_types" {
  description = "Spot 앱 호스트 후보. 서울 회수율이 낮은 타입만 둔다(설계 6.2절). m5·m6i·c6i·r5 계열은 회수율이 높아 넣지 않는다. 모두 ENI 3개 → awsvpc 태스크 2개."
  type        = list(string)
  default     = ["t3.medium", "t3.large", "t3a.medium", "c5.large"]
}

variable "spot_capacity" {
  description = "Spot ASG 크기. 태스크 4개 = 호스트 2대. max는 회수 예고 때 대체 인스턴스를 먼저 띄울 여유 1대를 더한다."
  type = object({
    min = number
    max = number
  })
  default = {
    min = 2
    max = 3
  }
}

variable "capacity_mode" {
  description = "서비스가 쓰는 Capacity Provider. 평소 spot, Spot 용량 부족 때 od로 바꿔 apply한다 (README 런북)."
  type        = string
  default     = "spot"

  validation {
    condition     = contains(["spot", "od"], var.capacity_mode)
    error_message = "capacity_mode는 spot 또는 od다."
  }
}

variable "container_stop_timeout_seconds" {
  description = "SIGTERM 뒤 SIGKILL까지 기다리는 시간. Spot 회수 예고(2분) 안에 끝나도록 120초보다 짧게 둔다."
  type        = number
  default     = 110

  validation {
    condition     = var.container_stop_timeout_seconds > 0 && var.container_stop_timeout_seconds < 120
    error_message = "container_stop_timeout_seconds는 120초보다 짧아야 한다."
  }
}

variable "rest_app_role" {
  description = "rest 서비스의 APP_ROLE. 전환 전(EKS worker가 도는 동안)에는 rest, 전환 때 rest,worker,matching으로 바꾼다 (설계 5.2절)."
  type        = string
  default     = "rest"

  validation {
    condition     = contains(["rest", "rest,worker,matching"], var.rest_app_role)
    error_message = "rest_app_role은 rest 또는 rest,worker,matching이다."
  }
}

variable "cutover_enabled" {
  description = "false: 헤더 X-Moyeota-Target: v4 요청만 v4로(테스트). true: 경로가 맞는 모든 요청을 v4로(전환). 되돌리면 V2 규칙으로 돌아간다."
  type        = bool
  default     = false
}

variable "listener_priorities" {
  description = "V2 prod HTTPS 리스너에 추가하는 v4 규칙 우선순위. V2 prod 규칙(priority_base 100 이후)보다 앞서야 한다."
  type = object({
    websocket = number
    rest      = number
    frontend  = number
  })
  default = {
    websocket = 10
    rest      = 11
    frontend  = 13
  }
}

variable "log_retention_days" {
  description = "서비스·Alloy CloudWatch 로그 보관 일수."
  type        = number
  default     = 14
}

variable "exec_log_retention_days" {
  description = "ECS Exec 세션 로그 보관 일수 (접속 감사 기록)."
  type        = number
  default     = 30
}

variable "alloy_image" {
  type    = string
  default = "grafana/alloy:v1.20.1"
}

variable "discord_webhook_parameter" {
  description = "Discord #incident webhook URL이 든 SSM SecureString (V2·V3 알람과 같은 채널)."
  type        = string
  default     = "/moyeota/v2/monitoring/DISCORD_WEBHOOK_INCIDENT"
}

variable "nat_instance_enabled" {
  description = "v4 NAT 인스턴스를 만든다. 만든 뒤 확인하고 nat_mode를 instance로 바꾼다 (nat.tf)."
  type        = bool
  default     = false
}

variable "nat_mode" {
  description = "v4 서브넷 기본 경로. v2_gateway: V2 NAT Gateway, instance: v4 NAT 인스턴스 ENI. 롤백은 v2_gateway로 되돌린다."
  type        = string
  default     = "v2_gateway"

  validation {
    condition     = contains(["v2_gateway", "instance"], var.nat_mode)
    error_message = "nat_mode는 v2_gateway 또는 instance다."
  }
}

variable "nat_instance_type" {
  description = "NAT 인스턴스 타입 (arm64). 트래픽이 적어 t4g.nano로 충분하다."
  type        = string
  default     = "t4g.nano"
}
