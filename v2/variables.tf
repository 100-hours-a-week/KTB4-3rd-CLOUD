variable "project_name" {
  description = "Prefix used for V2 AWS resource names and tags."
  type        = string
  default     = "moyeota-v2"
}

variable "config_path_prefix" {
  description = <<-EOT
    앱 설정 저장 경로 접두어 (앞뒤 슬래시 없이). 서비스 버전별로 경로를 나눈다.
      SSM             : /<config_path_prefix>/<stage>/<group>/<KEY>  예) /moyeota/v2/prod/backend/DB_PASSWORD
      Secrets Manager :  <config_path_prefix>/<stage>/...
    V3에서는 moyeota/v3 로 두면 V2·V3 Execution Role이 서로의 설정을 읽지 못한다.
  EOT
  type        = string
  default     = "moyeota/v2"

  validation {
    condition     = can(regex("^[a-z0-9-]+(/[a-z0-9-]+)*$", var.config_path_prefix))
    error_message = "config_path_prefix는 앞뒤 슬래시 없이 소문자·숫자·하이픈 경로여야 한다 (예: moyeota/v2)."
  }
}

variable "github_ci_role_name" {
  description = "FE CI가 OIDC로 Assume하는 CI Role 이름 (V1 infra/에서 생성). 빌드 값 SSM 읽기 권한을 덧붙인다. null이면 권한을 붙이지 않는다."
  type        = string
  default     = "moyeota-github-ci-ecr-push"
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
  description = <<-EOT
    Unused /24 CIDRs inside the shared VPC, verified against all existing AWS subnets.
    ops : (선택) 모니터링 호스트 전용 private 서브넷 ops-a. null이면 만들지 않고 모니터링 호스트를 app 서브넷에 둔다.
  EOT
  type = object({
    public_a = string
    public_b = string
    app      = string
    dev      = string
    data_a   = string
    data_b   = string
    ops      = optional(string)
  })

  validation {
    condition = alltrue([
      for cidr in compact(values(var.subnet_cidrs)) : can(cidrnetmask(cidr)) && can(regex("/24$", cidr))
    ])
    error_message = "Every subnet_cidrs value must be a valid IPv4 /24 CIDR."
  }

  validation {
    condition     = length(distinct(compact(values(var.subnet_cidrs)))) == length(compact(values(var.subnet_cidrs)))
    error_message = "Each V2 subnet must have a distinct CIDR."
  }
}

variable "s3_gateway_endpoint_enabled" {
  description = <<-EOT
    true면 private 워크로드 라우트 테이블(app·dev·ops)에 S3 Gateway Endpoint를 연결한다.
    ECR 이미지 레이어·모니터링 로그 블록처럼 S3로 가는 트래픽이 NAT를 거치지 않는다 (Gateway Endpoint는 시간당 요금 없음).
  EOT
  type        = bool
  default     = false
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

variable "nonprod_alb_certificate_arn" {
  description = "Optional ACM certificate ARN (ap-northeast-2) for the Non-Prod ALB, covering dev.moyeota.com and stg.moyeota.com. When null, the Non-Prod ALB serves HTTP only."
  type        = string
  default     = null
  nullable    = true
}

variable "admin_cidrs" {
  description = "운영자(팀) IPv4 CIDR. Non-Prod ALB(dev·stg) 인바운드에 허용한다."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.admin_cidrs : can(cidrnetmask(cidr))])
    error_message = "admin_cidrs must contain valid IPv4 CIDRs."
  }
}

variable "dev_qa_cidrs" {
  description = "개발자·QA IPv4 CIDR. Non-Prod ALB(dev·stg) 인바운드에 허용한다."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for cidr in var.dev_qa_cidrs : can(cidrnetmask(cidr))])
    error_message = "dev_qa_cidrs must contain valid IPv4 CIDRs."
  }
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
  description = "Spring Actuator 관리 포트(management.server.port). BE application-prod.yaml 기본값 8090과 같아야 한다. ALB 헬스체크만 이 포트로 들어온다."
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

variable "spring_health_matcher" {
  description = "rest·websocket Target Group 헬스체크 정상 코드. 4xx를 정상으로 넣으면 엔드포인트가 없어도(404) healthy가 되므로 200-399를 유지한다."
  type        = string
  default     = "200-399"
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

variable "github_org_id" {
  description = "GitHub org 불변 ID. OIDC 불변 sub 형식(repo:<org>@<org_id>/<repo>@<repo_id>:...)에 쓰인다."
  type        = string
  default     = "167328634"
}

variable "github_cloud_repository" {
  description = "인프라 레포 이름. (미사용) Deploy Role OIDC sub는 github_app_repositories + github_repository_ids로 만든다."
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
  type        = map(map(string))
  default     = {}

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
  type        = bool
  default     = false
}

variable "ecs_alb_host_headers" {
  description = <<-EOT
    스테이지별 ALB host-header 라우팅. dev·stg는 Non-Prod ALB 하나를 공유하고 서브도메인 host로만 스테이지를 나눈다.
    예) { dev = ["dev.moyeota.com"], stg = ["stg.moyeota.com"] }
    ecs_container_images에 dev·stg 이미지를 지정했다면 해당 스테이지 host는 필수다.
    prod에 지정하면 Prod ALB 규칙에 host 조건이 추가된다.
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for stage in keys(var.ecs_alb_host_headers) : contains(["dev", "stg", "prod"], stage)])
    error_message = "ecs_alb_host_headers keys must be dev, stg or prod."
  }

  # dev·stg는 Non-Prod ALB 리스너를 공유하므로 host 조건이 없으면 두 스테이지 규칙이 경로만으로 겹친다
  validation {
    condition = alltrue([
      for stage in ["dev", "stg"] : length(lookup(var.ecs_alb_host_headers, stage, [])) > 0
      if length(lookup(var.ecs_container_images, stage, {})) > 0
    ])
    error_message = "dev·stg ECS 서비스를 만들려면 ecs_alb_host_headers에 해당 스테이지 서브도메인(예: dev = [\"dev.moyeota.com\"])을 지정해야 한다."
  }
}

# -----------------------------------------------------------------------------
# 채팅 브로커·데이터 계층 (broker.tf)
# -----------------------------------------------------------------------------

variable "elasticache_redis_stages" {
  description = "채팅 브로커 ElastiCache Redis를 만들 스테이지. stg는 QA·스케줄링 테스트 때만 넣고 끝나면 뺀다. prod는 replica 1 + 자동 장애 조치(broker.tf). dev는 dev EC2 compose Redis를 쓴다."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.elasticache_redis_stages : contains(["stg", "prod"], s)])
    error_message = "elasticache_redis_stages는 stg 또는 prod만 지정할 수 있다 (dev는 dev EC2 compose Redis 사용)."
  }
}

variable "redis_engine_version" {
  description = "ElastiCache Redis OSS 엔진 버전"
  type        = string
  default     = "7.1"
}

variable "redis_parameter_group_name" {
  description = "redis_engine_version과 같은 계열의 파라미터 그룹"
  type        = string
  default     = "default.redis7"
}

variable "redis_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "redis_port" {
  type    = number
  default = 6379
}

variable "redis_transit_encryption_enabled" {
  description = "전송 구간 TLS. true로 바꾸면 BE에 SPRING_DATA_REDIS_SSL_ENABLED=true가 필요하다 (변경 시 클러스터 교체)."
  type        = bool
  default     = false
}

variable "dev_redis_port" {
  description = "dev EC2 compose Redis가 호스트에 publish한 포트 (dev 브로커 REDIS_PORT 값)"
  type        = number
  default     = 6379
}

variable "chat_fanout_schema_version" {
  description = "채팅 fan-out 이벤트 계약 버전. 채널 이름 moyeota:<stage>:chat:fanout:v<버전>에 들어간다. 계약을 깨는 변경 때만 올린다."
  type        = number
  default     = 1
}

variable "alarm_sns_topic_arn" {
  description = "브로커 CloudWatch 알람을 보낼 기존 SNS 토픽. null이면 alerting_enabled로 만든 <project>-alerts 토픽을 쓰고, 그것도 없으면 알람 상태만 남는다."
  type        = string
  default     = null
  nullable    = true
}

variable "dev_data_ports" {
  description = "dev rest·websocket 태스크가 dev EC2(compose MySQL·Redis)에 접근할 포트"
  type        = list(number)
  default     = [3306, 6379]
}

# -----------------------------------------------------------------------------
# RDS for MySQL (rds.tf) — wiki「V2 DB 인프라 설계」「V2 DB 무중단 마이그레이션 설계」
# -----------------------------------------------------------------------------

variable "rds_stages" {
  description = <<-EOT
    Terraform으로 RDS for MySQL을 만들 스테이지. prod만 지정할 수 있다.
    stg RDS는 QA·리허설 때만 CLI(Claude outputs/stg-rds-create.sh)로 만들고 지우므로 여기서 관리하지 않는다
    (같은 이름 moyeota-v2-stg·moyeota-v2-mysql84·moyeota-v2-data와 겹치지 않게 prod 리소스 이름에는 스테이지를 넣는다).
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.rds_stages : s == "prod"])
    error_message = "rds_stages에는 prod만 지정할 수 있다 (stg RDS는 CLI로 관리)."
  }
}

variable "rds_engine_version" {
  description = "MySQL 엔진 버전. V1 Prod MySQL(8.4.11)보다 낮으면 안 된다 (역방향 롤백 덤프·복제 호환). 자동 마이너 업그레이드는 끈다."
  type        = string
  default     = "8.4.11"
}

variable "rds_instance_class" {
  description = "DB 인스턴스 클래스. stg 리허설과 같은 db.t4g.small에서 시작한다."
  type        = string
  default     = "db.t4g.small"
}

variable "rds_allocated_storage_gib" {
  description = "gp3 할당 스토리지(GiB). 20 GiB 미만은 gp3로 만들 수 없다."
  type        = number
  default     = 20

  validation {
    condition     = var.rds_allocated_storage_gib >= 20
    error_message = "rds_allocated_storage_gib must be at least 20 (gp3 minimum)."
  }
}

variable "rds_max_allocated_storage_gib" {
  description = "스토리지 자동 확장 상한(GiB). 0이면 자동 확장을 끈다."
  type        = number
  default     = 100
}

variable "rds_backup_retention_days" {
  description = "자동 백업·PITR 보존 기간(일). Single-AZ의 AZ 장애 대응 수단이 백업·PITR이므로 0으로 두지 않는다."
  type        = number
  default     = 7

  validation {
    condition     = var.rds_backup_retention_days >= 1 && var.rds_backup_retention_days <= 35
    error_message = "rds_backup_retention_days must be between 1 and 35."
  }
}

variable "rds_migration_relay_port" {
  description = "V1 Prod EC2의 binlog 중계(socat) 게시 포트. 정방향 복제(RDS → V1) 때 RDS SG 아웃바운드와 V1 SG 인바운드에 쓴다."
  type        = number
  default     = 3307
}

variable "rds_migration_source_security_group_ids" {
  description = <<-EOT
    이름 → 보안 그룹 ID. RDS 3306 인바운드를 임시로 열어 줄 V2 밖의 출발지.
    V1 Prod EC2 SG(덤프 적재 + 컷오버 중 V1 backend의 RDS 연결)를 넣고, V1 정리 후 빼서 apply한다.
    예) { v1-prod-ec2 = "sg-02594c8be428026d0" }
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for id in values(var.rds_migration_source_security_group_ids) : can(regex("^sg-[0-9a-f]+$", id))])
    error_message = "rds_migration_source_security_group_ids values must be security group IDs (sg-...)."
  }
}

# -----------------------------------------------------------------------------
# Non-Prod DNS·인증서 (dns.tf)
# -----------------------------------------------------------------------------

variable "route53_zone_name" {
  description = "Non-Prod ALIAS·ACM DNS 검증 레코드를 만들 퍼블릭 Hosted Zone (예: moyeota.com). null이면 DNS 리소스를 만들지 않는다."
  type        = string
  default     = null
  nullable    = true
}

variable "nonprod_dns_records" {
  description = <<-EOT
    Terraform이 Non-Prod ALB로 ALIAS(A)할 호스트 이름. ecs_alb_host_headers의 dev·stg 값 중에서 고른다.
    V1이 이미 쓰는 레코드(예: dev.moyeota.com)는 넣지 않는다 — 같은 이름의 기존 레코드가 있으면 apply가 실패한다.
    V1 레코드를 넘겨받으려면 terraform import 후 목록에 추가한다.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.nonprod_dns_records) == 0 || var.route53_zone_name != null
    error_message = "nonprod_dns_records를 쓰려면 route53_zone_name이 필요하다."
  }

  validation {
    condition = alltrue([
      for host in var.nonprod_dns_records :
      contains(concat(lookup(var.ecs_alb_host_headers, "dev", []), lookup(var.ecs_alb_host_headers, "stg", [])), host)
    ])
    error_message = "nonprod_dns_records는 ecs_alb_host_headers의 dev·stg 호스트 중에서만 지정할 수 있다."
  }
}

variable "nonprod_acm_certificate_create" {
  description = <<-EOT
    true: ecs_alb_host_headers의 dev·stg 호스트를 SAN으로 묶은 ACM 인증서를 만들고 route53_zone_name에서 DNS 검증한 뒤
          Non-Prod ALB HTTPS 리스너에 붙인다 (wss:// 테스트용).
    nonprod_alb_certificate_arn을 지정하면 그 인증서가 우선이고 새로 만들지 않는다.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.nonprod_acm_certificate_create || var.route53_zone_name != null
    error_message = "nonprod_acm_certificate_create = true 이면 route53_zone_name이 필요하다."
  }

  validation {
    condition = !var.nonprod_acm_certificate_create || length(concat(
      lookup(var.ecs_alb_host_headers, "dev", []),
      lookup(var.ecs_alb_host_headers, "stg", []),
    )) > 0
    error_message = "nonprod_acm_certificate_create = true 이면 ecs_alb_host_headers에 dev 또는 stg 호스트가 있어야 한다."
  }
}

# -----------------------------------------------------------------------------
# CD (Deploy Role OIDC)
# -----------------------------------------------------------------------------

variable "github_app_repositories" {
  description = <<-EOT
    스테이지 Deploy Role을 Assume할 앱 레포 (github_org 하위). CD 워크플로가 BE·FE 레포에서 workflow_run으로 돌기 때문에 필요하다.
    OIDC sub는 대소문자를 구분하므로 GitHub에 표시되는 레포 이름 그대로 적는다.
  EOT
  type        = list(string)
  default     = ["KTB4-3rd-BE", "KTB4-3rd-FE", "KTB4-3rd-AI"]
}

variable "github_repository_ids" {
  description = <<-EOT
    스테이지 Deploy Role을 Assume할 레포 → 불변 repo ID (github_org 하위).
    2026-07-15 이후 생성 레포는 OIDC sub에 owner ID·repo ID가 들어간다 (issues/ecs-multi-cluster-by-stage.md).
    ID 확인: gh api repos/<org>/<repo> --jq .id
  EOT
  type        = map(string)
  default = {
    "KTB4-3rd-BE" = "1344695611"
    "KTB4-3rd-FE" = "1344690549"
    "KTB4-3rd-AI" = "1344696058"
  }
}
variable "github_deploy_environments" {
  description = <<-EOT
    스테이지 → CD job의 GitHub Environment 이름. Deploy Role 신뢰 정책의 OIDC sub(environment:<이름>)에 쓰인다.
    앱 레포는 V1부터 production environment(승인 규칙)를 써 왔고 V2 CD 워크플로도 staging/production을 쓰므로 스테이지 키와 다르다.
  EOT
  type        = map(string)
  default = {
    dev  = "dev"
    stg  = "staging"
    prod = "production"
  }
}

# -----------------------------------------------------------------------------
# Service Connect (ecs.tf) · FIS (fis.tf)
# -----------------------------------------------------------------------------

variable "ecs_service_connect_stages" {
  description = <<-EOT
    Service Connect를 켤 스테이지. fastapi는 서버(http://fastapi:<fastapi_port>), rest·websocket은 클라이언트로 등록된다.
    켜면 태스크마다 Service Connect 프록시 컨테이너가 붙고 모든 대상 서비스가 새 배포된다.
    켜기 전에 fastapi에 이름 붙은 포트(portMappings.name = fastapi)가 들어간 Task Definition revision이 CD로 배포돼 있어야 한다.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.ecs_service_connect_stages : contains(["dev", "stg", "prod"], s)])
    error_message = "ecs_service_connect_stages must contain dev, stg or prod."
  }
}

variable "fis_stages" {
  description = "FIS 실험 템플릿(태스크 종료·Spot 중단·컨테이너 인스턴스 드레인)을 만들 스테이지. 템플릿은 실행하기 전까지 비용·영향이 없다."
  type        = list(string)
  default     = ["stg"]

  validation {
    condition     = alltrue([for s in var.fis_stages : contains(["dev", "stg"], s)])
    error_message = "fis_stages는 dev 또는 stg만 지정할 수 있다 (prod 장애 주입 금지)."
  }
}

variable "dev_instance_schedule" {
  description = <<-EOT
    Dev 운영 시간 스케줄 (scheduler.tf). cron은 EventBridge Scheduler 형식(6필드), timezone 기준.
      - start_cron / stop_cron         : Dev EC2 호스트(aws_instance.host["dev"], MySQL·Redis) 시작/중지
      - ecs_start_cron / ecs_stop_cron : Dev ECS 서비스 desiredCount 복구/0
          → 태스크가 0개가 되면 Capacity Provider managed scaling이 Spot ASG를 0대로 줄인다.
          → 앱은 의존성(MySQL·Redis)보다 늦게 올리고 먼저 내리도록 호스트와 5분씩 어긋나게 둔다.
    기본: 호스트 09:00 시작 / 00:00 중지, ECS 09:05 시작 / 23:55 중지 (Asia/Seoul).
    주말을 빼려면 start_cron = "cron(0 9 ? * MON-FRI *)", stop_cron = "cron(0 0 ? * TUE-SAT *)",
    ecs_start_cron = "cron(5 9 ? * MON-FRI *)", ecs_stop_cron = "cron(55 23 ? * MON-FRI *)".
  EOT
  type = object({
    enabled        = optional(bool, true)
    timezone       = optional(string, "Asia/Seoul")
    start_cron     = optional(string, "cron(0 9 * * ? *)")
    stop_cron      = optional(string, "cron(0 0 * * ? *)")
    ecs_enabled    = optional(bool, true)
    ecs_start_cron = optional(string, "cron(5 9 * * ? *)")
    ecs_stop_cron  = optional(string, "cron(55 23 * * ? *)")
  })
  default = {}

  validation {
    condition = alltrue([
      for c in [
        var.dev_instance_schedule.start_cron,
        var.dev_instance_schedule.stop_cron,
        var.dev_instance_schedule.ecs_start_cron,
        var.dev_instance_schedule.ecs_stop_cron,
      ] : can(regex("^cron\\(.+\\)$", c))
    ])
    error_message = "dev_instance_schedule cron fields must be EventBridge Scheduler cron(...) expressions."
  }
}

variable "stg_qa_schedule" {
  description = <<-EOT
    Stg ECS QA 기간용 일회성 시작·종료 스케줄 (scheduler.tf).
    start_at / stop_at은 timezone 기준 현지 시각이며 YYYY-MM-DDTHH:MM:SS 형식이다.
    QA 창을 만들거나 연장할 때 미래의 시작·종료 시각을 입력하고 Terraform을 apply한다.
    stop_at이 실행되기 전에 enabled=false로 바꾸면 종료 스케줄도 삭제되므로, QA를 일찍 끝낼 때는 stop_at을 앞당겨 apply한다.
    QA 종료 후 enabled=false로 바꾸면 완료된 일회성 스케줄 리소스를 정리한다.
  EOT
  type = object({
    enabled  = optional(bool, false)
    timezone = optional(string, "Asia/Seoul")
    start_at = optional(string)
    stop_at  = optional(string)
  })
  default = {}

  validation {
    condition = !var.stg_qa_schedule.enabled || try(
      regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$", var.stg_qa_schedule.start_at) != "" &&
      regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$", var.stg_qa_schedule.stop_at) != "" &&
      var.stg_qa_schedule.start_at < var.stg_qa_schedule.stop_at,
      false,
    )
    error_message = "enabled인 stg_qa_schedule은 start_at과 stop_at을 YYYY-MM-DDTHH:MM:SS 형식으로 지정하고, stop_at은 start_at보다 뒤여야 합니다."
  }
}

# -----------------------------------------------------------------------------
# 중앙 모니터링 (monitoring.tf) — PLG(Prometheus · Loki · Grafana) + Alloy
#   wiki「V2 중앙 집중식 모니터링 시스템 설계」
# -----------------------------------------------------------------------------

variable "monitoring_enabled" {
  description = <<-EOT
    true면 중앙 모니터링 리소스(모니터링 SG·수집 포트 규칙, 이후 호스트·저장소·수집기)를 만든다.
    false(기본값)면 이 파일 묶음은 아무것도 만들지 않으므로, 모니터링 PR이 머지돼도 tfvars에서 켜기 전까지 인프라가 바뀌지 않는다.
  EOT
  type        = bool
  default     = false
}

variable "monitoring_instance_type" {
  description = "모니터링 호스트(Prometheus · Loki · Grafana) EC2 타입. loadtest-infra와 같은 m7i.large(2 vCPU · 8 GiB)에서 시작한다."
  type        = string
  default     = "t3.small"
}

variable "monitoring_data_volume_size_gib" {
  description = "모니터링 호스트 데이터 EBS (Prometheus TSDB · Loki WAL · Grafana DB)"
  type        = number
  default     = 40

  validation {
    condition     = var.monitoring_data_volume_size_gib >= 20
    error_message = "monitoring_data_volume_size_gib must be at least 20 GiB."
  }
}

variable "monitoring_prometheus_retention_days" {
  description = "Prometheus 보존 기간(일). 장기 보존이 필요해지면 AMP·Mimir remote write를 검토한다."
  type        = number
  default     = 15
}

variable "monitoring_loki_retention_days" {
  description = "Loki 로그 보존 기간(일). nonprod는 stage 라벨이 dev·stg인 로그에 적용된다."
  type = object({
    prod    = number
    nonprod = number
  })
  default = {
    prod    = 30
    nonprod = 7
  }
}

# -----------------------------------------------------------------------------
# 장애 알림 (alerting.tf) — 모니터링 스택과 독립된 CloudWatch Alarm 경로
# -----------------------------------------------------------------------------

variable "alerting_enabled" {
  description = <<-EOT
    true면 공용 SNS 토픽(<project>-alerts)과 인프라 알람(ALB·대상 그룹·ECS 태스크 수·모니터링 호스트 하트비트)을 만든다.
    alarm_sns_topic_arn을 따로 지정하지 않으면 Redis 브로커 알람도 이 토픽으로 보낸다.
  EOT
  type        = bool
  default     = false
}

variable "alert_emails" {
  description = "SNS 이메일 구독 주소. 생성 후 각 메일함에서 구독 확인(Confirm subscription)을 눌러야 알림이 간다."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "alert_emails must contain valid email addresses."
  }
}

variable "alert_stages" {
  description = "ALB 대상 그룹·ECS 태스크 수 알람을 만들 스테이지. dev는 09–24시에만 떠 있어 기본값에서 뺀다."
  type        = list(string)
  default     = ["prod"]

  validation {
    condition     = alltrue([for s in var.alert_stages : contains(["dev", "stg", "prod"], s)])
    error_message = "alert_stages may only contain dev, stg, prod."
  }
}

variable "alert_alb_5xx_threshold" {
  description = "Prod ALB 자체 5xx(HTTPCode_ELB_5XX_Count) 5분 합계 임계값"
  type        = number
  default     = 10
}

variable "alert_discord_enabled" {
  description = <<-EOT
    true면 "<project>-" 로 시작하는 CloudWatch 알람의 상태 변경(ALARM·OK)을 EventBridge API destination으로 Discord #incident에 보낸다.
    웹훅 URL은 /<config_path_prefix>/monitoring/DISCORD_WEBHOOK_INCIDENT 값을 읽는다 → 값을 넣은 뒤에 켠다 (CHANGE_ME면 생성 실패).
    URL이 state에 남으므로(sensitive) state 버킷 접근 권한을 확인한다.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.alert_discord_enabled || (var.alerting_enabled && var.monitoring_enabled)
    error_message = "alert_discord_enabled = true 이면 alerting_enabled와 monitoring_enabled(웹훅 SSM 파라미터)가 모두 true여야 한다."
  }
}

variable "monitoring_discovery_namespace" {
  description = <<-EOT
    메트릭 수집용 Cloud Map 프라이빗 DNS 네임스페이스. ECS 서비스 태스크가 <stage>-<service>-metrics.<이 이름> A 레코드로 등록된다.
    Service Connect 네임스페이스(<stage>.moyeota-v2.local, HTTP)와 별개다. 공유 VPC의 DNS 지원·호스트 이름 속성이 켜져 있어야 한다.
  EOT
  type        = string
  default     = "monitor.moyeota.internal"
}

variable "monitoring_grafana_host" {
  description = <<-EOT
    Grafana를 Non-Prod ALB 호스트 규칙으로 열 도메인 (예: monitor.moyeota.com). null이면 ALB에 붙이지 않고 SSM 포트 포워딩으로만 접속한다.
    Non-Prod ALB SG가 admin_cidrs·dev_qa_cidrs만 허용하므로 팀 CIDR에서만 열린다. 로그인은 Grafana 계정으로 한다.
  EOT
  type        = string
  default     = null
  nullable    = true
}

variable "monitoring_grafana_listener_priority" {
  description = "Non-Prod ALB 리스너 규칙 우선순위. ECS 규칙(stg 200~, dev 300~)보다 앞에 둔다."
  type        = number
  default     = 50

  validation {
    condition     = var.monitoring_grafana_listener_priority >= 1 && var.monitoring_grafana_listener_priority < 200
    error_message = "monitoring_grafana_listener_priority must be between 1 and 199 (ECS rules use 200+)."
  }
}

variable "monitoring_grafana_dns_record" {
  description = "true면 route53_zone_name에 monitoring_grafana_host → Non-Prod ALB ALIAS 레코드를 만든다."
  type        = bool
  default     = false

  validation {
    condition     = !var.monitoring_grafana_dns_record || (var.monitoring_grafana_host != null && var.route53_zone_name != null)
    error_message = "monitoring_grafana_dns_record = true 이면 monitoring_grafana_host와 route53_zone_name이 필요하다."
  }
}

variable "monitoring_grafana_certificate_create" {
  description = <<-EOT
    true면 monitoring_grafana_host 전용 ACM 인증서를 DNS 검증으로 만들어 Non-Prod HTTPS 리스너에 추가 인증서(SNI)로 붙인다.
    기존 Non-Prod 인증서(dev·stg SAN)에 도메인을 더하면 인증서가 교체되므로 따로 만든다.
  EOT
  type        = bool
  default     = false

  validation {
    condition = !var.monitoring_grafana_certificate_create || (
      var.monitoring_grafana_host != null && var.route53_zone_name != null &&
      (var.nonprod_alb_certificate_arn != null || var.nonprod_acm_certificate_create)
    )
    error_message = "monitoring_grafana_certificate_create = true 이면 monitoring_grafana_host, route53_zone_name, Non-Prod HTTPS 리스너(nonprod_alb_certificate_arn 또는 nonprod_acm_certificate_create)가 필요하다."
  }
}

variable "monitoring_alloy_stages" {
  description = <<-EOT
    Alloy DAEMON을 띄워 Loki로 로그를 보낼 ECS 스테이지. ecs_stages에 없는 값은 무시한다.
    처음에는 ["stg"]로 dual logging(docker logs) 동작과 호스트 메모리 여유를 확인한 뒤 dev·prod로 넓힌다.
  EOT
  type        = list(string)
  default     = ["dev", "stg", "prod"]

  validation {
    condition     = alltrue([for s in var.monitoring_alloy_stages : contains(["dev", "stg", "prod"], s)])
    error_message = "monitoring_alloy_stages values must be dev, stg or prod."
  }
}

variable "monitoring_alloy_image" {
  description = "Grafana Alloy 이미지 (버전 고정). docker.sock을 마운트하므로 latest를 쓰지 않는다."
  type        = string
  default     = "grafana/alloy:v1.20.1"
}

variable "monitoring_alloy_memory" {
  description = "Alloy 컨테이너 메모리(MiB). reservation은 배치 시 예약, limit을 넘으면 컨테이너가 OOM으로 재시작된다."
  type = object({
    reservation = number
    limit       = number
  })
  default = {
    reservation = 128
    limit       = 256
  }

  validation {
    condition     = var.monitoring_alloy_memory.reservation >= 64 && var.monitoring_alloy_memory.limit >= var.monitoring_alloy_memory.reservation
    error_message = "monitoring_alloy_memory.reservation must be >= 64 and limit must be >= reservation."
  }
}

variable "monitoring_grafana_alerting_enabled" {
  description = <<-EOT
    true면 Grafana 알림(서비스 지표 규칙 → Discord #incident·#alerts)을 프로비저닝한다. 규칙 대상 스테이지는 alert_stages.
    켜기 전에 SSM DISCORD_WEBHOOK_INCIDENT·DISCORD_WEBHOOK_ALERTS 값을 넣는다 (CHANGE_ME면 전송이 실패한다).
  EOT
  type        = bool
  default     = false
}

# -----------------------------------------------------------------------------
# 앱 이미지 버킷 (images.tf)
# -----------------------------------------------------------------------------

variable "ecs_image_buckets" {
  description = <<-EOT
    스테이지 → 앱 이미지 버킷 이름. 여기 있는 스테이지의 ecs_image_bucket_services Task Role에 접근 권한을 붙인다.
    stg는 사용할 버킷(dev 공유 / 별도 버킷)을 정한 뒤 추가한다. stg가 dev 버킷을 쓰면 버킷 CORS에 https://stg.moyeota.com도 넣어야 한다.
  EOT
  type        = map(string)
  default = {
    dev  = "moyeota-dev-images"
    prod = "moyeota-prod-images"
  }

  validation {
    condition     = alltrue([for s in keys(var.ecs_image_buckets) : contains(["dev", "stg", "prod"], s)])
    error_message = "ecs_image_buckets keys must be dev, stg, prod."
  }

  # dev·stg 태스크가 prod 이미지 버킷에 접근하지 못하게 한다
  validation {
    condition = alltrue([
      for s, b in var.ecs_image_buckets : s == "prod" || b != lookup(var.ecs_image_buckets, "prod", "")
    ])
    error_message = "Non-prod stages must not use the prod image bucket."
  }
}

variable "ecs_image_bucket_services" {
  description = "이미지 버킷 권한을 붙일 ECS 서비스(Task Role). 이미지 presigned URL 발급·확인·복사는 REST만 한다."
  type        = list(string)
  default     = ["rest"]

  validation {
    condition     = alltrue([for s in var.ecs_image_bucket_services : contains(["rest", "websocket", "frontend", "fastapi"], s)])
    error_message = "ecs_image_bucket_services may only contain rest, websocket, frontend, fastapi."
  }
}

variable "ecs_image_object_prefixes" {
  description = "앱이 읽고 쓰는 이미지 버킷 prefix. tmp(업로드 임시) · profile(공개) · meter·transfer(정산, 비공개)."
  type        = list(string)
  default     = ["tmp", "profile", "meter", "transfer"]
}

# --- 백엔드 파트 dev 접근 (developer_access.tf) --------------------------------

variable "dev_backend_users" {
  description = "dev 로그·ECS 조회·ECS Exec 권한을 받을 BE IAM 사용자 이름. 비어 있으면 그룹·정책도 만들지 않는다."
  type        = list(string)
  default     = []
}

variable "dev_backend_group_name" {
  description = "BE IAM 그룹 이름"
  type        = string
  default     = "moyeota-backend"
}

variable "dev_backend_console_access" {
  description = "BE 사용자에게 콘솔 로그인(초기 비밀번호, 첫 로그인 때 변경 강제)을 줄지"
  type        = bool
  default     = true
}

variable "dev_backend_log_services" {
  description = "BE가 조회할 dev 로그 그룹의 서비스. exec 로그 그룹은 넣지 않는다."
  type        = list(string)
  default     = ["rest", "websocket", "fastapi"]

  validation {
    condition     = alltrue([for s in var.dev_backend_log_services : contains(["rest", "websocket", "frontend", "fastapi"], s)])
    error_message = "dev_backend_log_services may only contain rest, websocket, frontend, fastapi."
  }
}

variable "stg_backend_log_services" {
  description = "BE가 조회할 stg 로그 그룹의 서비스. exec 로그 그룹은 넣지 않는다."
  type        = list(string)
  default     = ["rest", "websocket", "fastapi"]

  validation {
    condition     = alltrue([for s in var.stg_backend_log_services : contains(["rest", "websocket", "frontend", "fastapi"], s)])
    error_message = "stg_backend_log_services may only contain rest, websocket, frontend, fastapi."
  }
}

variable "dev_backend_exec_containers" {
  description = "BE가 ECS Exec로 들어갈 수 있는 dev 컨테이너 이름"
  type        = list(string)
  default     = ["rest", "websocket"]
}

variable "dev_backend_ssm_groups" {
  description = "BE가 값을 조회·수정할 dev SSM 파라미터 그룹 (ssm.tf ssm_param_keys의 키)"
  type        = list(string)
  default     = ["backend"]

  validation {
    condition     = alltrue([for g in var.dev_backend_ssm_groups : contains(["backend", "frontend", "ai"], g)])
    error_message = "dev_backend_ssm_groups may only contain backend, frontend, ai."
  }
}

variable "dev_backend_deploy_services" {
  description = "BE가 \"새 배포 강제\"(ecs:UpdateService)로 재배포할 수 있는 dev 서비스"
  type        = list(string)
  default     = ["rest", "websocket"]

  validation {
    condition     = alltrue([for s in var.dev_backend_deploy_services : contains(["rest", "websocket", "frontend", "fastapi"], s)])
    error_message = "dev_backend_deploy_services may only contain rest, websocket, frontend, fastapi."
  }
}

# -----------------------------------------------------------------------------
# FastAPI 로그 읽기 권한 (fastapi_log_access.tf)
# -----------------------------------------------------------------------------

variable "fastapi_log_read_stages" {
  description = "FastAPI Task Role에 자기 스테이지 로그 읽기 권한을 붙일 스테이지. 해당 스테이지 fastapi 서비스가 있을 때만 생성된다."
  type        = list(string)
  default     = ["dev", "prod"]

  validation {
    condition     = alltrue([for s in var.fastapi_log_read_stages : contains(["dev", "stg", "prod"], s)])
    error_message = "fastapi_log_read_stages may only contain dev, stg, prod."
  }
}

variable "fastapi_log_read_expires_at" {
  description = "FastAPI 로그 읽기 권한 만료 시각 (UTC, RFC3339). 기본값은 2026-11-16 00:00 KST."
  type        = string
  default     = "2026-11-15T15:00:00Z"

  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$", var.fastapi_log_read_expires_at))
    error_message = "fastapi_log_read_expires_at must be UTC RFC3339 like 2026-11-15T15:00:00Z."
  }
}

variable "ai_log_reader_users" {
  description = "로컬에서 dev FastAPI 로그를 aws login으로 읽을 AI IAM 사용자 이름. 비어 있으면 그룹·정책·사용자를 만들지 않는다."
  type        = list(string)
  default     = []
}

variable "ai_log_reader_group_name" {
  description = "AI 로컬 로그 조회 IAM 그룹 이름"
  type        = string
  default     = "moyeota-ai"
}
