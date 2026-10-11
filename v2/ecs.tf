# =============================================================================
# 스테이지별 ECS (dev / stg / prod) — ECS on EC2
#   설계 근거
#     - issues/ecs-multi-cluster-by-stage.md   : 클러스터 = 스테이지 축, Service = 애플리케이션 축
#     - issues/ecs-asg-by-cluster-service.md   : 1 ASG = 1 LT = 1 Capacity Provider = 1 Cluster, 역할 × 유형별 ASG
#     - issues/ecs-iam-network.md              : 인스턴스 Role 클러스터 한정, 인스턴스 SG / 태스크 SG 분리
#
#   모듈 (modules/ecs/)
#     ecs-cluster : 클러스터 + Capacity Provider 등록 + 스테이지 격리 IAM·SG (스테이지당 1개)
#     ecs-asg     : Launch Template + ASG + Capacity Provider 1세트 (스테이지 × ASG 그룹)
#     ecs-service : Task Definition + 태스크 SG + ip Target Group + ECS Service + Service Auto Scaling
#                   (스테이지 × 서비스, ecs_container_images에 이미지가 있는 것만)
#
#   스테이지별 값은 locals.tf의 ecs_stage_settings / ecs_service_specs에서 조정한다.
# =============================================================================

# V1 infra/iam.tf에서 이미 생성한 계정 공용 GitHub OIDC Provider를 참조만 한다 (계정당 1개)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  # ECS 서비스 Listener Rule을 붙일 리스너 (인증서가 있으면 HTTPS)
  ecs_alb_listener_arn = var.alb_certificate_arn == null ? aws_lb_listener.http.arn : aws_lb_listener.https[0].arn

  # 스테이지 × ASG 그룹 → "prod-rest-od" 같은 키로 펼친다
  ecs_asgs = merge([
    for stage, s in local.ecs_stages : {
      for key, g in s.asg_groups : "${stage}-${key}" => merge(g, {
        stage       = stage
        key         = key
        subnet_keys = s.subnet_keys
      })
    }
  ]...)

  # 스테이지 × 서비스 → "prod-rest" 같은 키로 펼친다. 이미지가 지정된 서비스만 만든다.
  ecs_service_instances = merge([
    for stage, s in local.ecs_stages : {
      for svc, cfg in s.services : "${stage}-${svc}" => merge(local.ecs_service_specs[svc], cfg, {
        stage              = stage
        service            = svc
        image              = try(var.ecs_container_images[stage][svc], null)
        subnet_keys        = s.subnet_keys
        alb                = s.alb
        log_retention_days = s.log_retention_days
      })
      if contains(var.ecs_services, svc) && try(var.ecs_container_images[stage][svc], null) != null
    }
  ]...)
}

# -----------------------------------------------------------------------------
# 1) Cluster (스테이지당 1개)
# -----------------------------------------------------------------------------

module "ecs_cluster" {
  source   = "./modules/ecs/ecs-cluster"
  for_each = local.ecs_stages

  project_name       = var.project_name
  stage              = each.key
  services           = var.ecs_services
  container_insights = each.value.container_insights
  vpc_id             = data.aws_vpc.shared.id

  # ecs-asg가 만든 Capacity Provider를 이 클러스터에 등록
  capacity_providers = [
    for k, asg in module.ecs_asg : asg.capacity_provider_name if local.ecs_asgs[k].stage == each.key
  ]
  default_capacity_provider_strategy = [{
    capacity_provider = module.ecs_asg["${each.key}-${each.value.default_asg}"].capacity_provider_name
    weight            = 1
    base              = 0
  }]

  enable_execute_command  = true
  exec_log_retention_days = each.value.exec_log_retention_days

  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  github_oidc_subjects = [
    "repo:${var.github_org}/${var.github_cloud_repository}:environment:${each.key}",
  ]
}

# -----------------------------------------------------------------------------
# 2) ASG + Launch Template + Capacity Provider (스테이지 × ASG 그룹)
# -----------------------------------------------------------------------------

module "ecs_asg" {
  source   = "./modules/ecs/ecs-asg"
  for_each = local.ecs_asgs

  name         = "${var.project_name}-${each.value.stage}-${each.value.key}"
  stage        = each.value.stage
  cluster_name = module.ecs_cluster[each.value.stage].cluster_name
  role         = each.value.role
  purchase     = each.value.purchase

  instance_types        = each.value.instance_types
  instance_requirements = each.value.instance_requirements
  min_size              = each.value.min
  max_size              = each.value.max

  subnet_ids           = [for key in each.value.subnet_keys : aws_subnet.v2[key].id]
  instance_profile_arn = module.ecs_cluster[each.value.stage].instance_profile_arn
  security_group_ids   = [module.ecs_cluster[each.value.stage].instance_security_group_id]
  root_volume_size_gib = var.root_volume_size_gib

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# 3) ECS Service (스테이지 × 서비스)
# -----------------------------------------------------------------------------

module "ecs_service" {
  source   = "./modules/ecs/ecs-service"
  for_each = local.ecs_service_instances

  project_name = var.project_name
  stage        = each.value.stage
  name         = each.value.service

  cluster_name       = module.ecs_cluster[each.value.stage].cluster_name
  cluster_arn        = module.ecs_cluster[each.value.stage].capacity_ready_cluster_arn
  execution_role_arn = module.ecs_cluster[each.value.stage].task_execution_role_arn
  task_role_arn      = module.ecs_cluster[each.value.stage].task_role_arns[each.value.service]

  vpc_id     = data.aws_vpc.shared.id
  subnet_ids = [for key in each.value.subnet_keys : aws_subnet.v2[key].id]

  image                      = each.value.image
  task_cpu                   = each.value.task_cpu
  task_memory                = each.value.task_memory
  container_cpu              = each.value.container_cpu
  container_memory           = each.value.container_memory
  container_port             = each.value.container_port
  additional_container_ports = each.value.additional_ports
  environment                = each.value.environment
  log_retention_days         = each.value.log_retention_days

  capacity_provider_strategy = [
    for s in each.value.strategy : {
      capacity_provider = module.ecs_asg["${each.value.stage}-${s.asg}"].capacity_provider_name
      base              = s.base
      weight            = s.weight
    }
  ]
  placement_role       = each.value.placement_role
  distinct_instance    = each.value.distinct_instance
  placement_strategies = each.value.placement_strategies

  desired_count                      = each.value.desired
  deployment_minimum_healthy_percent = each.value.deploy_min
  deployment_maximum_percent         = each.value.deploy_max

  load_balancer = each.value.alb == null ? null : {
    alb_security_group_id = aws_security_group.alb.id
    listener_arn          = local.ecs_alb_listener_arn
    priority              = each.value.alb.priority_base + each.value.route_order
    path_patterns         = each.value.path_patterns
    host_headers          = each.value.alb.host_headers
    http_headers          = each.value.alb.http_headers
    health_check_path     = each.value.health_check_path
    health_check_port     = each.value.health_check_port
    deregistration_delay  = each.value.deregistration_delay
  }

  autoscaling = each.value.autoscaling
}

# Prod ECS Exec는 운영자 그룹에만 허용
resource "aws_iam_group_policy_attachment" "prod_ecs_exec_operator" {
  count = contains(keys(local.ecs_stages), "prod") && var.prod_ecs_operator_group_name != null ? 1 : 0

  group      = var.prod_ecs_operator_group_name
  policy_arn = module.ecs_cluster["prod"].exec_operator_policy_arn
}
