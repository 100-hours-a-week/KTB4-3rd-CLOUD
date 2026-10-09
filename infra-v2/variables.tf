variable "project_name" {
  description = "Prefix used for V2 AWS resource names and tags."
  type        = string
  default     = "moyeota-v2"
}

variable "aws_region" {
  description = "AWS region for V2 workload resources."
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "Optional local AWS CLI profile. Leave null to use the default credential chain."
  type        = string
  default     = null
  nullable    = true
}

variable "vpc_id" {
  description = "ID of the existing V1 VPC to share. This Terraform root only reads the VPC."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be an existing VPC ID."
  }
}

variable "availability_zones" {
  description = "Two AZs for V2 public ALB and data subnets. Workloads initially run in the first AZ."
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]

  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "availability_zones must contain exactly two distinct AZ names."
  }
}

variable "subnet_cidrs" {
  description = "Six unused /24 CIDRs inside the shared VPC, verified against all existing AWS subnets."
  type = object({
    public_a = string
    public_b = string
    app      = string
    dev      = string
    data_a   = string
    data_b   = string
  })

  validation {
    condition = alltrue([
      for cidr in values(var.subnet_cidrs) : can(cidrnetmask(cidr)) && can(regex("/24$", cidr))
    ])
    error_message = "Every subnet_cidrs value must be a valid IPv4 /24 CIDR."
  }

  validation {
    condition     = length(distinct(values(var.subnet_cidrs))) == 6
    error_message = "Each V2 subnet must have a distinct CIDR."
  }
}

variable "prod_app_instance_type" {
  description = "EC2 type for the Prod Next.js, Spring REST, and FastAPI Compose host."
  type        = string
  default     = "t3.small"
}

variable "prod_websocket_instance_type" {
  description = "EC2 type for the separate Prod WebSocket Compose host."
  type        = string
  default     = "t3.medium"
}

variable "dev_instance_type" {
  description = "EC2 type for the private Dev integration-test host."
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size_gib" {
  description = "Encrypted gp3 root volume size for each EC2 host."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size_gib >= 8
    error_message = "root_volume_size_gib must be at least 8 GiB."
  }
}

variable "dev_data_volume_size_gib" {
  description = "Encrypted gp3 persistent volume for Dev Docker/MySQL data."
  type        = number
  default     = 30

  validation {
    condition     = var.dev_data_volume_size_gib >= 1
    error_message = "dev_data_volume_size_gib must be at least 1 GiB."
  }
}

variable "docker_compose_version" {
  description = "Pinned Docker Compose v2 release installed on the EC2 hosts."
  type        = string
  default     = "v2.39.4"
}

variable "alb_certificate_arn" {
  description = "Optional ACM certificate ARN in ap-northeast-2. When null, the ALB serves HTTP only."
  type        = string
  default     = null
  nullable    = true
}

variable "alb_ingress_cidrs" {
  description = "IPv4 CIDRs allowed to reach the internet-facing ALB. Restrict to trusted ranges when ready."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for cidr in var.alb_ingress_cidrs : can(cidrnetmask(cidr))])
    error_message = "alb_ingress_cidrs must contain valid IPv4 CIDRs."
  }
}

variable "alb_cloudfront_prefix_list_id" {
  description = "Optional AWS-managed CloudFront origin-facing prefix list ID."
  type        = string
  default     = null
  nullable    = true
}

variable "frontend_port" {
  description = "Next.js host port on the Prod App EC2 instance."
  type        = number
  default     = 3000
}

variable "rest_port" {
  description = "Spring REST host port on the Prod App EC2 instance."
  type        = number
  default     = 8080
}

variable "fastapi_port" {
  description = "FastAPI host port on the Prod App EC2 instance."
  type        = number
  default     = 8000
}

variable "websocket_port" {
  description = "WebSocket host port on the separate Prod WebSocket EC2 instance."
  type        = number
  default     = 8080
}

variable "spring_management_port" {
  description = "Spring Actuator health-check port, reachable from the ALB only."
  type        = number
  default     = 8090
}

variable "frontend_health_path" {
  description = "HTTP health-check path exposed by the Next.js host port."
  type        = string
  default     = "/"
}

variable "rest_health_path" {
  description = "Spring REST readiness path exposed by the management port."
  type        = string
  default     = "/actuator/health/readiness"
}

variable "fastapi_health_path" {
  description = "HTTP health-check path exposed by FastAPI."
  type        = string
  default     = "/health"
}

variable "websocket_health_path" {
  description = "Spring WebSocket readiness path exposed by the management port."
  type        = string
  default     = "/actuator/health/readiness"
}

variable "alb_idle_timeout_seconds" {
  description = "ALB idle timeout for long-lived WebSocket connections."
  type        = number
  default     = 300

  validation {
    condition     = var.alb_idle_timeout_seconds >= 1 && var.alb_idle_timeout_seconds <= 4000
    error_message = "alb_idle_timeout_seconds must be between 1 and 4000."
  }
}

# -----------------------------------------------------------------------------
# ECS (ecs.tf)
# -----------------------------------------------------------------------------

variable "ecs_stages" {
  description = "ECS Cluster를 생성할 스테이지 목록. 단계적으로 도입할 때 일부만 지정한다."
  type        = list(string)
  default     = ["dev", "stg", "prod"]

  validation {
    condition     = alltrue([for s in var.ecs_stages : contains(["dev", "stg", "prod"], s)])
    error_message = "ecs_stages may only contain dev, stg, prod."
  }
}

variable "ecs_services" {
  description = "각 클러스터에서 운영할 ECS Service 목록. 서비스마다 스테이지별 Task Role이 생성된다."
  type        = list(string)
  default     = ["rest", "websocket", "frontend", "fastapi"]

  validation {
    condition     = alltrue([for s in var.ecs_services : contains(["rest", "websocket", "frontend", "fastapi"], s)])
    error_message = "ecs_services may only contain rest, websocket, frontend, fastapi (locals.ecs_service_specs keys)."
  }
}

variable "github_org" {
  description = "GitHub organization used in OIDC trust conditions."
  type        = string
  default     = "100-hours-a-week"
}

variable "github_cloud_repository" {
  description = "ECS 배포 워크플로가 실행되는 레포. job의 environment(dev/stg/prod)로 스테이지별 Deploy Role이 구분된다."
  type        = string
  default     = "KTB4-3rd-CLOUD"
}

variable "prod_ecs_operator_group_name" {
  description = "Prod ECS Exec를 허용할 기존 IAM 그룹 이름. null이면 연결하지 않는다(SSO Permission Set에 직접 붙이는 경우)."
  type        = string
  default     = null
  nullable    = true
}

variable "ecs_container_images" {
  description = <<-EOT
    스테이지 → 서비스 → 최초 Task Definition 이미지. 이미지가 있는 서비스만 ECS Service를 만든다.
    태그 대신 digest(<repo>@sha256:...)를 권장한다. 이후 revision은 CI(Deploy Role)가 등록하며 Terraform은 되돌리지 않는다.
    예) { prod = { rest = "<account>.dkr.ecr.ap-northeast-2.amazonaws.com/moyeota/be@sha256:..." } }
  EOT
  type    = map(map(string))
  default = {}

  validation {
    condition = alltrue(flatten([
      for stage, images in var.ecs_container_images : [
        for svc, image in images : contains(["dev", "stg", "prod"], stage) && contains(["rest", "websocket", "frontend", "fastapi"], svc)
      ]
    ]))
    error_message = "ecs_container_images keys must be stage (dev/stg/prod) → service (rest/websocket/frontend/fastapi)."
  }
}

variable "ecs_prod_alb_cutover" {
  description = <<-EOT
    false(기본): Prod ECS 규칙은 X-Moyeota-Stage: prod 헤더 요청만 받고, 기존 Compose Target Group 규칙이 실제 트래픽을 받는다.
    true       : 헤더 조건을 빼고 우선순위 1~4로 기존 규칙보다 앞서 Prod 트래픽을 ECS로 보낸다.
  EOT
  type    = bool
  default = false
}

variable "ecs_alb_host_headers" {
  description = "스테이지별 ALB host-header 라우팅 (예: { stg = [\"stg.example.com\"] }). stg에 지정하면 헤더 조건 대신 host 기반으로 라우팅한다."
  type        = map(list(string))
  default     = {}
}
