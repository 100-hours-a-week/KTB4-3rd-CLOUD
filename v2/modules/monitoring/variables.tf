variable "project_name" {
  description = "리소스 이름 접두어 (예: moyeota-v2)"
  type        = string
}

variable "config_path_prefix" {
  description = "SSM 경로 접두어 (앞뒤 슬래시 없이). 모니터링 비밀값은 /<prefix>/monitoring/<KEY>에 둔다."
  type        = string
}

variable "config_noncurrent_retention_days" {
  description = "설정 버킷에서 덮어쓴 이전 버전을 보관하는 기간(일). 설정 롤백용."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}

# -----------------------------------------------------------------------------
# 모니터링 호스트
# -----------------------------------------------------------------------------

variable "subnet_id" {
  description = "모니터링 호스트 서브넷 (ops-a, 없으면 app-a)"
  type        = string
}

variable "availability_zone" {
  description = "subnet_id의 AZ. 데이터 EBS를 같은 AZ에 만든다."
  type        = string
}

variable "security_group_ids" {
  description = "모니터링 호스트 SG (루트 monitoring.tf)"
  type        = list(string)
}

variable "instance_type" {
  description = "모니터링 호스트 타입. Prometheus·Loki·Grafana를 한 호스트에서 돌린다."
  type        = string
  default     = "m7i.large"
}

variable "root_volume_size_gib" {
  type    = number
  default = 20
}

variable "data_volume_size_gib" {
  description = "Prometheus TSDB·Loki WAL·Grafana DB용 데이터 EBS (gp3). 인스턴스를 교체해도 남는다."
  type        = number
  default     = 40
}

variable "docker_compose_version" {
  description = "설치할 Docker Compose v2 플러그인 릴리스"
  type        = string
}

variable "images" {
  description = "PLG 스택 컨테이너 이미지 (버전 고정, 한 번에 하나씩 올린다)"
  type = object({
    prometheus = optional(string, "prom/prometheus:v3.15.0")
    loki       = optional(string, "grafana/loki:3.7.8")
    grafana    = optional(string, "grafana/grafana:13.2.1")
  })
  default = {}
}

variable "prometheus_retention_days" {
  type    = number
  default = 15
}

variable "loki_retention_days" {
  description = "Loki 로그 보존 기간(일). nonprod는 stage 라벨이 dev·stg인 스트림에 적용된다."
  type = object({
    prod    = number
    nonprod = number
  })
  default = {
    prod    = 30
    nonprod = 7
  }
}

variable "grafana_root_url" {
  description = "Grafana 외부 URL (ALB 호스트 규칙을 붙이면 https://monitor.moyeota.com). 비워 두면 Grafana 기본값"
  type        = string
  default     = ""
}

variable "scrape_targets" {
  description = "Prometheus dns_sd_configs 대상 (루트 monitoring.tf가 Cloud Map 이름으로 만든다)"
  type = list(object({
    job          = string
    stage        = string
    service      = string
    dns_name     = string
    port         = number
    metrics_path = string
  }))
  default = []
}
