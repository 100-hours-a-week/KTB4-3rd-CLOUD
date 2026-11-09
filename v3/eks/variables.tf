variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "로컬 AWS 프로필. null이면 환경 변수(AWS_PROFILE)를 쓴다."
  type        = string
  default     = null
}

variable "project_name" {
  description = "재사용하는 V2 자원(서브넷, 라우트 테이블, ALB)을 이름으로 찾는 접두사. EKS 자원 이름은 local.name_prefix를 쓴다."
  type        = string
  default     = "moyeota-v2"
}

variable "vpc_id" {
  type = string
}

variable "cluster_version" {
  type = string
}

variable "cluster_subnet_c_cidr" {
  description = "클러스터 ENI용 2c 프라이빗 서브넷. EKS는 서로 다른 AZ의 서브넷 2개 이상을 요구한다."
  type        = string
}

variable "api_public_cidrs" {
  description = "Kubernetes API public endpoint 허용 CIDR. 운영자 IP만 넣는다."
  type        = list(string)
}

variable "stages" {
  description = "EKS에 올릴 스테이지 → 스토리지 등 스테이지별 값."
  type = map(object({
    images_bucket = string
  }))
}

variable "prod_node_desired" {
  description = "prod 노드 초기 대수. 전환 중 On-Demand vCPU 여유를 위해 3으로 시작한다."
  type        = number
  default     = 3
}
