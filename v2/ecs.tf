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
  # ECS 서비스 Listener Rule을 붙일 리스너와 ALB SG (locals.ecs_alb_routing.<stage>.alb_key로 선택)
  #   prod    → Prod ALB     (인증서가 있으면 HTTPS)
  #   nonprod → Non-Prod ALB (dev·stg 공유, 인증서가 있으면 HTTPS)
  ecs_alb_listener_arns = {
    prod    = var.alb_certificate_arn == null ? aws_lb_listener.http.arn : aws_lb_listener.https[0].arn
    nonprod = local.nonprod_tls_enabled ? aws_lb_listener.nonprod_https[0].arn : aws_lb_listener.nonprod_http.arn
  }
  ecs_alb_security_group_ids = {
    prod    = aws_security_group.alb.id
    nonprod = aws_security_group.nonprod_alb.id
  }

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

  # ALB에 붙이지 않는 내부 전용 서비스. 같은 스테이지 서비스가 Service Connect(http://<name>:<port>)로만 호출한다.
  #   fastapi : 호출하는 곳이 BE뿐이라 외부 노출하지 않는다 (/ocr/* 경로 제거)
  ecs_internal_only_services = ["fastapi"]

  # 스테이지 × 서비스 → "prod-rest" 같은 키로 펼친다. 이미지가 지정된 서비스만 만든다.
  ecs_service_instances = merge([
    for stage, s in local.ecs_stages : {
      for svc, cfg in s.services : "${stage}-${svc}" => merge(local.ecs_service_specs[svc], cfg, {
        stage              = stage
        service            = svc
        image              = try(var.ecs_container_images[stage][svc], null)
        subnet_keys        = s.subnet_keys
        alb                = contains(local.ecs_internal_only_services, svc) ? null : s.alb
        log_retention_days = s.log_retention_days

        # 환경 변수 이름 → SSM 파라미터 ARN. 태스크 시작 시 execution role이 읽어 주입한다.
        #   ssm.tf    : 앱 설정 (값은 콘솔에서 입력)
        #   broker.tf : 채팅 브로커 연결 값 REDIS_HOST·REDIS_PORT·CHAT_FANOUT_CHANNEL (rest·websocket만, Terraform이 값 관리)
        secrets = merge(
          merge(flatten([
            for group in local.ecs_service_param_groups[svc] : [{
              for key in local.ssm_param_keys[group] :
              key => aws_ssm_parameter.app["${stage}/${group}/${key}"].arn
            }]
          ])...),
          { for key, arn in try(local.broker_secrets[stage], {}) : key => arn if contains(local.data_client_services, svc) },
        )
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
  config_path_prefix = var.config_path_prefix
  stage              = each.key
  services           = var.ecs_services
  container_insights = each.value.container_insights
  vpc_id             = data.aws_vpc.shared.id

  enable_execute_command  = true
  exec_log_retention_days = each.value.exec_log_retention_days

  # CD는 BE·FE·AI 레포에서 workflow_run(CI 완료)으로 돈다 → 앱 레포의 해당 스테이지 environment만 허용
  #   스테이지 키(stg/prod)와 GitHub Environment 이름(staging/production)이 달라 github_deploy_environments로 매핑한다
  #   2026-07-15 이후 생성 레포는 OIDC sub가 불변 형식이다: repo:<org>@<org_id>/<repo>@<repo_id>:environment:<env>
  #   (예: repo:100-hours-a-week@167328634/KTB4-3rd-BE@1344695611:environment:dev)
  #   github_app_repositories의 레포는 모두 github_repository_ids에 ID가 있어야 한다 (없으면 plan 단계에서 실패).
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  github_oidc_subjects = [
    for repo in distinct(var.github_app_repositories) :
    "repo:${var.github_org}@${var.github_org_id}/${repo}@${var.github_repository_ids[repo]}:environment:${lookup(var.github_deploy_environments, each.key, each.key)}"
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
# 2-1) Capacity Provider를 클러스터에 등록 (스테이지당 1개)
#   ecs-asg가 ecs-cluster 출력(클러스터 이름·인스턴스 프로파일·SG)을 받으므로
#   등록 리소스를 ecs-cluster 모듈 안에 두면 모듈 간 순환 참조가 생긴다 → 루트에 둔다.
#   managed scaling을 켠 Capacity Provider는 클러스터 하나에만 연결된다.
# -----------------------------------------------------------------------------

resource "aws_ecs_cluster_capacity_providers" "ecs" {
  for_each = local.ecs_stages

  cluster_name = module.ecs_cluster[each.key].cluster_name
  capacity_providers = [
    for k, asg in module.ecs_asg : asg.capacity_provider_name if local.ecs_asgs[k].stage == each.key
  ]

  default_capacity_provider_strategy {
    capacity_provider = module.ecs_asg["${each.key}-${each.value.default_asg}"].capacity_provider_name
    weight            = 1
    base              = 0
  }
}

locals {
  # Capacity Provider 등록이 끝난 뒤에 확정되는 클러스터 ARN.
  # 등록 리소스를 참조하므로 ecs-service가 등록 전 Capacity Provider를 쓰는 순서 오류를 막는다.
  ecs_capacity_ready_cluster_arns = {
    for stage, cp in aws_ecs_cluster_capacity_providers.ecs : stage => module.ecs_cluster[stage].cluster_arn
  }
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
  cluster_arn        = local.ecs_capacity_ready_cluster_arns[each.value.stage]
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
  secrets                    = each.value.secrets
  entry_point                = contains(local.be_container_services, each.value.service) ? local.be_container_entry_point : null
  command                    = contains(local.be_container_services, each.value.service) ? local.be_container_command : null
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
    alb_security_group_id = local.ecs_alb_security_group_ids[each.value.alb.alb_key]
    listener_arn          = local.ecs_alb_listener_arns[each.value.alb.alb_key]
    priority              = each.value.alb.priority_base + each.value.route_order
    path_patterns         = each.value.path_patterns
    host_headers          = each.value.alb.host_headers
    http_headers          = each.value.alb.http_headers
    health_check_path     = each.value.health_check_path
    health_check_port     = each.value.health_check_port
    health_check_matcher  = each.value.health_check_matcher
    deregistration_delay  = each.value.deregistration_delay
  }

  autoscaling = each.value.autoscaling

  # 중앙 모니터링 메트릭 수집 대상이면 Cloud Map에 태스크 A 레코드를 등록한다 (monitoring.tf)
  service_registry_arn = try(aws_service_discovery_service.metrics[each.key].arn, null)

  service_connect = (
    contains(var.ecs_service_connect_stages, each.value.stage) &&
    lookup(local.ecs_service_connect_roles, each.value.service, null) != null
    ) ? {
    namespace_arn = module.ecs_cluster[each.value.stage].service_connect_namespace_arn
    server        = lookup(local.ecs_service_connect_roles, each.value.service, "") == "server"
  } : null
}

# -----------------------------------------------------------------------------
# 3-1) Service Connect (ecs_service_connect_stages에 넣은 스테이지만)
#   rest·websocket → http://fastapi:<fastapi_port>, websocket → http://rest:<rest_port>
#   ALB 경로(/ocr/*)는 그대로 두고, 서비스 간 동기 호출만 Service Connect로 보낸다.
#   프록시는 클라이언트 태스크에서 서버 태스크 ENI로 직접 붙으므로 fastapi 태스크 SG에 클라이언트 태스크 SG를 연다.
# -----------------------------------------------------------------------------

locals {
  # rest는 fastapi를 부르는 클라이언트이면서, websocket이 http://rest:<rest_port>로 부르는 서버다
  #   (Service Connect에서 server로 등록한 서비스도 같은 네임스페이스의 다른 서버를 호출할 수 있다)
  ecs_service_connect_roles = {
    rest      = "server"
    websocket = "client"
    fastapi   = "server"
  }

  # fastapi를 호출하는 서비스 (역할과 무관하게 SG를 열어야 하는 쪽)
  ecs_service_connect_fastapi_callers = ["rest", "websocket"]

  # "stg-rest" → fastapi 태스크 SG에 열어 줄 클라이언트 태스크 SG (같은 스테이지 fastapi가 있을 때만)
  ecs_service_connect_ingress = {
    for k, s in local.ecs_service_instances : k => {
      server_sg_id = module.ecs_service["${s.stage}-fastapi"].task_security_group_id
      client_sg_id = module.ecs_service[k].task_security_group_id
    }
    if(
      contains(var.ecs_service_connect_stages, s.stage) &&
      contains(local.ecs_service_connect_fastapi_callers, s.service) &&
      contains(keys(local.ecs_service_instances), "${s.stage}-fastapi")
    )
  }

  # "dev-websocket" → rest 태스크 SG에 열어 줄 websocket 태스크 SG (같은 스테이지 rest가 있을 때만)
  ecs_service_connect_rest_ingress = {
    for k, s in local.ecs_service_instances : k => {
      server_sg_id = module.ecs_service["${s.stage}-rest"].task_security_group_id
      client_sg_id = module.ecs_service[k].task_security_group_id
    }
    if(
      contains(var.ecs_service_connect_stages, s.stage) &&
      s.service == "websocket" &&
      contains(keys(local.ecs_service_instances), "${s.stage}-rest")
    )
  }
}

resource "aws_vpc_security_group_ingress_rule" "service_connect_fastapi" {
  for_each = local.ecs_service_connect_ingress

  security_group_id            = each.value.server_sg_id
  description                  = "Service Connect from ${each.key} tasks"
  referenced_security_group_id = each.value.client_sg_id
  ip_protocol                  = "tcp"
  from_port                    = var.fastapi_port
  to_port                      = var.fastapi_port
}

resource "aws_vpc_security_group_ingress_rule" "service_connect_rest" {
  for_each = local.ecs_service_connect_rest_ingress

  security_group_id            = each.value.server_sg_id
  description                  = "Service Connect from ${each.key} tasks"
  referenced_security_group_id = each.value.client_sg_id
  ip_protocol                  = "tcp"
  from_port                    = var.rest_port
  to_port                      = var.rest_port
}

# Prod ECS Exec는 운영자 그룹에만 허용
resource "aws_iam_group_policy_attachment" "prod_ecs_exec_operator" {
  count = contains(keys(local.ecs_stages), "prod") && var.prod_ecs_operator_group_name != null ? 1 : 0

  group      = var.prod_ecs_operator_group_name
  policy_arn = module.ecs_cluster["prod"].exec_operator_policy_arn
}
