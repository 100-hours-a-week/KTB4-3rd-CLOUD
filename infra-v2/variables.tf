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
