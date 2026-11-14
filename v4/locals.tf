locals {
  name_prefix  = "moyeota-v4-prod"
  cluster_name = local.name_prefix

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region

  azs = {
    a = "${var.aws_region}a"
    c = "${var.aws_region}c"
  }

  # 서비스 → 포트. rest·websocket은 같은 BE 이미지이고 관리 포트(8090)로 health check·지표를 노출한다.
  # rest는 APP_ROLE=rest,worker,matching으로 worker·matching 역할을 함께 맡는다 (설계 5.2절).
  services = {
    rest      = { port = 8080, management_port = 8090, alb = true }
    websocket = { port = 8080, management_port = 8090, alb = true }
    frontend  = { port = 3000, management_port = null, alb = true }
    fastapi   = { port = 8000, management_port = null, alb = false }
  }

  # ARN 패턴. 클러스터를 만들기 전에도 IAM 정책을 쓸 수 있게 이름으로 만든다.
  cluster_arn                    = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:cluster/${local.cluster_name}"
  service_arn_pattern            = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:service/${local.cluster_name}/*"
  task_arn_pattern               = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:task/${local.cluster_name}/*"
  container_instance_arn_pattern = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:container-instance/${local.cluster_name}/*"
  exec_log_group_name            = "/aws/ecs/${local.cluster_name}/exec"

  v2_ssm_arn_pattern = "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${var.v2_config_path}/*"
  # 태스크는 v4 경로 중 broker·backend만 읽는다. mongo/*(root·app 비밀번호)는 데이터 호스트만 읽는다.
  v4_ssm_arn_patterns = [
    for group in ["broker", "backend"] :
    "arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter/${var.v4_config_path}/${group}/*"
  ]
}
