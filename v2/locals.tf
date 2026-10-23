locals {
  common_tags = {
    Project     = "moyeota"
    Environment = "v2"
    ManagedBy   = "terraform"
    Owner       = "cloud"
  }

  az_a = var.availability_zones[0]
  az_b = var.availability_zones[1]

  subnet_specs = merge({
    public_a = {
      cidr  = var.subnet_cidrs.public_a
      az    = local.az_a
      tier  = "public"
      label = "public-a"
    }
    public_b = {
      cidr  = var.subnet_cidrs.public_b
      az    = local.az_b
      tier  = "public"
      label = "public-b"
    }
    app = {
      cidr  = var.subnet_cidrs.app
      az    = local.az_a
      tier  = "private-app"
      label = "app-a"
    }
    dev = {
      cidr  = var.subnet_cidrs.dev
      az    = local.az_a
      tier  = "private-dev"
      label = "dev-a"
    }
    data_a = {
      cidr  = var.subnet_cidrs.data_a
      az    = local.az_a
      tier  = "private-data"
      label = "data-a"
    }
    data_b = {
      cidr  = var.subnet_cidrs.data_b
      az    = local.az_b
      tier  = "private-data"
      label = "data-b"
    }
    },
    # 모니터링 호스트 전용 (Prometheus · Loki · Grafana). 감시 대상인 ECS 서브넷과 분리한다.
    var.subnet_cidrs.ops == null ? {} : {
      ops = {
        cidr  = var.subnet_cidrs.ops
        az    = local.az_a
        tier  = "private-ops"
        label = "ops-a"
      }
  })

  # NAT 경로를 쓰는 private 워크로드 서브넷 (app·dev + 선택 ops)
  private_workload_subnet_keys = concat(["app", "dev"], var.subnet_cidrs.ops == null ? [] : ["ops"])

  hosts = {
    prod-app = {
      environment   = "prod"
      subnet_key    = "app"
      instance_type = var.prod_app_instance_type
      data_volume   = false
    }
    prod-ws = {
      environment   = "prod"
      subnet_key    = "app"
      instance_type = var.prod_websocket_instance_type
      data_volume   = false
    }
    dev = {
      environment   = "dev"
      subnet_key    = "dev"
      instance_type = var.dev_instance_type
      data_volume   = true
    }
  }

  target_groups = {
    frontend = {
      host_key       = "prod-app"
      port           = var.frontend_port
      health_port    = var.frontend_port
      health_path    = var.frontend_health_path
      health_matcher = "200-399"
    }
    rest = {
      host_key       = "prod-app"
      port           = var.rest_port
      health_port    = var.spring_management_port
      health_path    = var.rest_health_path
      health_matcher = "200-399"
    }
    fastapi = {
      host_key       = "prod-app"
      port           = var.fastapi_port
      health_port    = var.fastapi_port
      health_path    = var.fastapi_health_path
      health_matcher = "200-399"
    }
    websocket = {
      host_key       = "prod-ws"
      port           = var.websocket_port
      health_port    = var.spring_management_port
      health_path    = var.websocket_health_path
      health_matcher = "200-399"
    }
  }

  path_routes = {
    websocket = {
      priority      = 10
      path_patterns = ["/api/wss"]
      target_group  = "websocket"
    }
    rest = {
      priority      = 20
      path_patterns = ["/api/*"]
      target_group  = "rest"
    }
    # fastapi(/ocr/*)는 내부 전용으로 바꿔 ALB 경로를 두지 않는다 — BE는 Service Connect(http://fastapi:8000)로 호출
  }

  prod_ingress_ports = toset([
    var.frontend_port,
    var.rest_port,
    var.fastapi_port,
    var.websocket_port,
    var.spring_management_port,
  ])

  # Non-Prod ALB(dev·stg) 인바운드 허용 CIDR = 운영자 + 개발자·QA
  nonprod_alb_ingress_cidrs = distinct(concat(var.admin_cidrs, var.dev_qa_cidrs))
}

# -----------------------------------------------------------------------------
# ECS 서비스 공통 스펙 (스테이지 무관) — ecs.tf의 module "ecs_service"
#   근거: issues/ECS-Task·Container-spec.md 2절 (부하 테스트 전 "시작값")
#   - REST      : 1 vCPU / 1 GiB, 컨테이너 hard limit 960 MiB, -Xmx512m, 앱 8080 · 관리 8090
#   - WebSocket : 0.5 vCPU / 1 GiB, 컨테이너 hard limit 960 MiB, heap 최대 512 MiB (잠정)
#   - frontend · fastapi : 측정값 없음 → general-od(t3.medium) 호스트당 2태스크가 들어가는 잠정값
#   route_order : ALB Listener Rule 우선순위 오프셋 (/api/wss 가 /api/* 보다 먼저)
#   APP_ROLE    : 같은 BE 이미지를 rest·websocket 두 서비스로 띄우므로 실행 역할을 알린다.
#                 BE가 이 값으로 REST 컨트롤러·STOMP endpoint·Redis listener를 조건부 등록해야 실제 자원이 분리된다
#                 (wiki「V2 WebSocket 메시지 버스와 Redis 도입 설계」— Spring profile/조건부 설정으로 경계)
# -----------------------------------------------------------------------------
#   be_container_* : BE(rest·websocket) 기동 래퍼 — ecs.tf module "ecs_service"에서 rest·websocket에만 넣는다
#                    (ecs_service_specs에 넣으면 서비스마다 타입이 달라져 ecs_service_instances를 map으로 바꾸는 곳이 깨진다)
#                    SSM FCM_SERVICE_ACCOUNT_JSON(서비스 계정 JSON)이 "{"로 시작하면 /tmp/fcm.json(권한 600)으로 쓰고
#                    GOOGLE_APPLICATION_CREDENTIALS=/tmp/fcm.json을 export한 뒤, JSON 환경 변수는 지우고 원래 ENTRYPOINT를 exec한다.
#                    원래 ENTRYPOINT: ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"] (BE Dockerfile)
#                    BE Dockerfile의 실행 명령이 바뀌면 여기도 같이 바꾼다.
locals {
  be_container_services    = ["rest", "websocket"]
  be_container_entry_point = ["sh", "-c"]
  be_container_command = [join("; ", [
    "case \"$FCM_SERVICE_ACCOUNT_JSON\" in \"{\"*) umask 077 && printf '%s' \"$FCM_SERVICE_ACCOUNT_JSON\" > /tmp/fcm.json && export GOOGLE_APPLICATION_CREDENTIALS=/tmp/fcm.json ;; esac",
    "unset FCM_SERVICE_ACCOUNT_JSON",
    "exec java $JAVA_OPTS -jar /app/app.jar",
  ])]

  ecs_service_specs = {
    websocket = {
      task_cpu             = 512
      task_memory          = 1024
      container_cpu        = 512
      container_memory     = 960
      container_port       = var.websocket_port
      additional_ports     = [var.spring_management_port]
      environment          = { JAVA_TOOL_OPTIONS = "-Xms128m -Xmx512m", APP_ROLE = "websocket" }
      path_patterns        = ["/api/wss"]
      route_order          = 0
      health_check_path    = var.websocket_health_path
      health_check_port    = var.spring_management_port
      health_check_matcher = var.spring_health_matcher
      deregistration_delay = 120 # 장기 연결 드레이닝
    }
    # AI_BASE_URL : BE → FastAPI 내부 호출 주소 (Service Connect 이름, 스테이지별 네임스페이스라 모든 스테이지 동일)
    #               BE application-*.yaml이 ${AI_BASE_URL}로 읽는다 (비밀값이 아니라 SSM이 아닌 일반 환경변수)
    rest = {
      task_cpu             = 1024
      task_memory          = 1024
      container_cpu        = 1024
      container_memory     = 960
      container_port       = var.rest_port
      additional_ports     = [var.spring_management_port]
      environment          = { JAVA_TOOL_OPTIONS = "-Xms128m -Xmx512m", APP_ROLE = "rest", AI_BASE_URL = "http://fastapi:${var.fastapi_port}" }
      path_patterns        = ["/api/*"]
      route_order          = 1
      health_check_path    = var.rest_health_path
      health_check_port    = var.spring_management_port
      health_check_matcher = var.spring_health_matcher
      deregistration_delay = 30 # Spot 2분 알림 안에 끝나도록
    }
    fastapi = {
      task_cpu             = 512
      task_memory          = 768
      container_cpu        = 512
      container_memory     = 704
      container_port       = var.fastapi_port
      additional_ports     = []
      environment          = { LOCAL_DEVICE = "FALSE" } # 로컬 테스트용 스위치 — 배포 환경은 항상 FALSE
      path_patterns        = []                         # 내부 전용 — ALB에 붙이지 않는다 (ecs.tf ecs_internal_only_services)
      route_order          = 2
      health_check_path    = var.fastapi_health_path
      health_check_port    = null
      health_check_matcher = "200-399"
      deregistration_delay = 30
    }
    frontend = {
      task_cpu             = 512
      task_memory          = 768
      container_cpu        = 512
      container_memory     = 704
      container_port       = var.frontend_port
      additional_ports     = []
      environment          = {}
      path_patterns        = ["/*"]
      route_order          = 3
      health_check_path    = var.frontend_health_path
      health_check_port    = null
      health_check_matcher = "200-399"
      deregistration_delay = 30
    }
  }

  # Spot ASG 속성 기반 인스턴스 선택: 10개 이상 타입 후보 (t3/t3a small·medium, m5/m5a/m6i/m6a large, c5/c5a/c6i/c6a large 등)
  ecs_spot_requirements = {
    rest = {
      vcpu_min       = 2
      vcpu_max       = 4
      memory_mib_min = 2048
      memory_mib_max = 8192
    }
    shared = {
      vcpu_min       = 2
      vcpu_max       = 4
      memory_mib_min = 4096
      memory_mib_max = 8192
    }
    dev_shared = {
      vcpu_min       = 2
      vcpu_max       = 4
      memory_mib_min = 4096
      memory_mib_max = 8192
    }
  }

  # REST 출퇴근 예약 스케일링 (KST, 평일) — 피크 10분 전에 min 3, 피크 10분 뒤 min 2로 복귀
  ecs_rest_peak_schedule = [
    { name = "am-peak-start", schedule = "cron(50 6 ? * MON-FRI *)", min_capacity = 3 },
    { name = "am-peak-end", schedule = "cron(10 9 ? * MON-FRI *)", min_capacity = 2 },
    { name = "pm-peak-start", schedule = "cron(50 16 ? * MON-FRI *)", min_capacity = 3 },
    { name = "pm-peak-end", schedule = "cron(10 19 ? * MON-FRI *)", min_capacity = 2 },
  ]

  # 스테이지별 ALB 라우팅 (issues/ecs-alb-multi-target-groups.md 5.2, 8절)
  #   alb_key : ecs.tf의 리스너·ALB SG 선택 (prod → Prod ALB, nonprod → Non-Prod ALB)
  #
  #   prod (Prod ALB) — ECS 규칙은 항상 우선순위 1~4 (Compose 규칙 10·20과 기본 동작보다 먼저 평가)
  #     컷오버 전 : ECS 규칙에 X-Moyeota-Stage: prod 헤더 조건 → 헤더 요청만 ECS, 나머지는 Compose 쪽으로 간다
  #     컷오버 후 : ecs_prod_alb_cutover = true → 헤더 조건만 빠진다 (규칙 교체 없이 조건 update)
  #     이전 값(컷오버 전 100~103)은 /api/* 요청이 헤더가 있어도 Compose 규칙(10·20)에 먼저 걸려 ECS로 오지 않았다.
  #   stg·dev (Non-Prod ALB, 리스너 공유)
  #     서브도메인 host-header(stg.moyeota.com / dev.moyeota.com)로만 스테이지를 나눈다. 우선순위 대역 stg 200~203, dev 300~303
  #     헤더(X-Moyeota-Stage) 대체 경로는 두지 않는다 → host 미지정 시 variables.tf 검증에서 막는다
  ecs_alb_routing = {
    prod = {
      alb_key       = "prod"
      priority_base = 1
      host_headers  = lookup(var.ecs_alb_host_headers, "prod", [])
      http_headers  = { for k, v in { "X-Moyeota-Stage" = ["prod"] } : k => v if !var.ecs_prod_alb_cutover }
    }
    stg = {
      alb_key       = "nonprod"
      priority_base = 200
      host_headers  = lookup(var.ecs_alb_host_headers, "stg", [])
      http_headers  = {}
    }
    dev = {
      alb_key       = "nonprod"
      priority_base = 300
      host_headers  = lookup(var.ecs_alb_host_headers, "dev", [])
      http_headers  = {}
    }
  }
}

# -----------------------------------------------------------------------------
# ECS 스테이지별 설정 — ecs.tf
#   근거: issues/ecs-asg-by-cluster-service.md 5절 (스테이지별 ASG), 7절 (스케일링)
#
#   asg_groups : 키 = <role>-<purchase>, ASG 이름 = <project>-<stage>-<key>
#   services   : strategy[].asg는 같은 스테이지 asg_groups 키
#
#   prod : 공용 t3.medium On-Demand baseline 3대 + 공용 Spot burst (app 서브넷, 단일 AZ)
#   stg  : QA 시간에 공용 t3.medium On-Demand baseline 최대 4대 + 공용 Spot burst (dev 서브넷)
#   dev  : shared-spot 0–2 하나를 모든 서비스가 binpack으로 공유       (dev 서브넷, Non-Prod ALB)
#
#   stg·prod는 2026-10-23 역할별 ASG(rest-od / rest-spot / ws-od)에서 공용 풀로 전환했다 (EC2 On-Demand vCPU 한도 32).
# -----------------------------------------------------------------------------
locals {
  ecs_stage_settings = {
    dev = {
      subnet_keys             = ["dev"]
      container_insights      = "disabled"
      exec_log_retention_days = 7
      log_retention_days      = 7
      alb                     = local.ecs_alb_routing.dev # Non-Prod ALB, host 기반 (dev.moyeota.com)
      default_asg             = "shared-spot"

      asg_groups = {
        shared-spot = {
          role                  = "shared"
          purchase              = "spot"
          instance_types        = []
          instance_requirements = local.ecs_spot_requirements.dev_shared
          min                   = 0
          max                   = 2
        }
      }

      # t3.medium은 ENI 3개 → 호스트당 awsvpc 태스크 2개. 4개 서비스 = 2대(=max)라
      # 롤링 여유가 없으므로 dev는 기존 태스크를 먼저 내리고 새 태스크를 띄운다 (0% / 100%).
      services = {
        for svc in ["rest", "websocket", "frontend", "fastapi"] : svc => {
          strategy             = [{ asg = "shared-spot", base = 0, weight = 1 }]
          placement_role       = "shared"
          distinct_instance    = false
          placement_strategies = [{ type = "binpack", field = "memory" }]
          desired              = 1
          deploy_min           = 0
          deploy_max           = 100
          autoscaling          = null
        }
      }
    }

    stg = {
      subnet_keys             = ["dev"]
      container_insights      = "enabled"
      exec_log_retention_days = 14
      log_retention_days      = 14
      alb                     = local.ecs_alb_routing.stg # Non-Prod ALB, host 기반 (stg.moyeota.com)
      default_asg             = "general-od"

      asg_groups = {
        # QA 중 필수 태스크가 올라오면 Capacity Provider가 필요한 호스트를 띄운다.
        # ASG min=0은 QA 종료 후 호스트를 0대로 줄이기 위한 값이며, 서비스 baseline은 CP strategy의 base로 보장한다.
        # max 4: 기본 6태스크가 3대(6자리)를 꽉 채워 distinctInstance 배치·롤링 배포가 막히므로 1대 여유를 둔다.
        general-od = {
          role                  = "shared"
          purchase              = "od"
          instance_types        = ["t3.medium"]
          instance_requirements = null
          min                   = 0
          max                   = 4
        }
        # REST·Next·FastAPI의 baseline을 넘는 태스크만 받는 공용 Spot burst 풀.
        shared-spot = {
          role                  = "shared"
          purchase              = "spot"
          instance_types        = []
          instance_requirements = local.ecs_spot_requirements.shared
          min                   = 0
          max                   = 2
        }
      }

      services = {
        rest = {
          strategy = [
            { asg = "general-od", base = 2, weight = 1 },
            { asg = "shared-spot", base = 0, weight = 4 },
          ]
          placement_role       = "shared"
          distinct_instance    = true
          placement_strategies = []
          desired              = 2
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity = 2
            max_capacity = 4
            cpu_target   = 60
            scheduled    = []
          }
        }
        # Redis Pub/Sub 크로스 태스크 검증: 최소 2태스크를 서로 다른 호스트에 둔다.
        # prod와 같은 정책(scale-in 금지)을 stg에서 먼저 확인한다.
        websocket = {
          strategy             = [{ asg = "general-od", base = 0, weight = 1 }]
          placement_role       = "shared"
          distinct_instance    = true
          placement_strategies = []
          desired              = 2
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity     = 2
            max_capacity     = 3
            cpu_target       = 60
            disable_scale_in = true
            scheduled        = []
          }
        }
        frontend = {
          strategy = [
            { asg = "general-od", base = 1, weight = 1 },
            { asg = "shared-spot", base = 0, weight = 4 },
          ]
          placement_role       = "shared"
          distinct_instance    = false
          placement_strategies = [{ type = "binpack", field = "memory" }]
          desired              = 1
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity = 1
            max_capacity = 2
            cpu_target   = 70
            scheduled    = []
          }
        }
        fastapi = {
          strategy = [
            { asg = "general-od", base = 1, weight = 1 },
            { asg = "shared-spot", base = 0, weight = 4 },
          ]
          placement_role       = "shared"
          distinct_instance    = false
          placement_strategies = [{ type = "binpack", field = "memory" }]
          desired              = 1
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity = 1
            max_capacity = 2
            cpu_target   = 70
            scheduled    = []
          }
        }
      }
    }

    prod = {
      subnet_keys             = ["app"]
      container_insights      = "enhanced"
      exec_log_retention_days = 90
      log_retention_days      = 30
      alb                     = local.ecs_alb_routing.prod
      default_asg             = "general-od"

      asg_groups = {
        # 공용 On-Demand baseline. REST/WebSocket의 distinct 태스크와 앱 baseline을 함께 수용한다.
        # 3대 baseline, 4대 max (min + 1, [D17])로 Spot 부족·배포·서비스 scale-out 시 On-Demand 여유를 둔다.
        general-od = {
          role                  = "shared"
          purchase              = "od"
          instance_types        = ["t3.medium"]
          instance_requirements = null
          min                   = 3
          max                   = 4
        }
        # REST·frontend·FastAPI의 추가 용량. WebSocket은 연결 중단 위험 때문에 On-Demand만 사용한다.
        shared-spot = {
          role                  = "shared"
          purchase              = "spot"
          instance_types        = []
          instance_requirements = local.ecs_spot_requirements.shared
          min                   = 0
          max                   = 4
        }
      }

      services = {
        # On-Demand baseline 2태스크. baseline 초과 REST는 공용 Spot과 On-Demand에 분산한다.
        rest = {
          strategy = [
            { asg = "general-od", base = 2, weight = 1 },
            { asg = "shared-spot", base = 0, weight = 4 },
          ]
          placement_role       = "shared"
          distinct_instance    = true
          placement_strategies = []
          desired              = 2
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity = 2
            max_capacity = 6 # DB 연결 예산(태스크 수 × HikariCP 풀)으로 확정 필요
            cpu_target   = 60
            scheduled    = local.ecs_rest_peak_schedule
          }
        }
        # Spot 미사용. 자동 scale-in 금지 (연결 단절 방지)
        # 동적 지표는 태스크당 STOMP 세션 수(커스텀 지표)가 목표 — 앱이 지표를 발행하기 전까지 CPU로 scale-out만 한다
        websocket = {
          strategy             = [{ asg = "general-od", base = 0, weight = 1 }]
          placement_role       = "shared"
          distinct_instance    = true
          placement_strategies = []
          desired              = 2
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity     = 2
            max_capacity     = 4
            cpu_target       = 60
            disable_scale_in = true
            scheduled        = []
          }
        }
        frontend = {
          strategy = [
            { asg = "general-od", base = 1, weight = 1 },
            { asg = "shared-spot", base = 0, weight = 4 },
          ]
          placement_role       = "shared"
          distinct_instance    = false
          placement_strategies = [{ type = "binpack", field = "memory" }]
          desired              = 1
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity = 1
            max_capacity = 2
            cpu_target   = 70
            scheduled    = []
          }
        }
        fastapi = {
          strategy = [
            { asg = "general-od", base = 1, weight = 1 },
            { asg = "shared-spot", base = 0, weight = 4 },
          ]
          placement_role       = "shared"
          distinct_instance    = false
          placement_strategies = [{ type = "binpack", field = "memory" }]
          desired              = 1
          deploy_min           = 100
          deploy_max           = 200
          autoscaling = {
            min_capacity = 1
            max_capacity = 2
            cpu_target   = 70
            scheduled    = []
          }
        }
      }
    }
  }

  ecs_stages = { for stage in var.ecs_stages : stage => local.ecs_stage_settings[stage] }
}
