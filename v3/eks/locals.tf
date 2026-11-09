locals {
  cluster_name = "${var.project_name}-eks"

  # 노드 그룹은 권한 경계다. SG와 IAM Role을 이 이름별로 분리한다.
  # 노드 그룹 정의(local.node_groups)의 키와 같아야 한다.
  node_group_names = toset(["system", "prod", "stg"])
}
