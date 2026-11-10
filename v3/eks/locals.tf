locals {
  # EKS가 새로 만드는 자원의 이름 접두사. V2 자원 조회에는 var.project_name을 쓴다.
  name_prefix  = "moyeota-v3"
  cluster_name = "${local.name_prefix}-eks"

  # 노드 그룹의 권한 경계. SG와 IAM Role을 이 이름별로 분리한다.
  # 노드 그룹 정의(local.node_groups)의 access 값과 같아야 한다.
  node_group_names = toset(["system", "realtime", "core", "burst", "stg"])
}
