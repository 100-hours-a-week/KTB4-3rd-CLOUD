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
