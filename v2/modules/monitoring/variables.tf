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
