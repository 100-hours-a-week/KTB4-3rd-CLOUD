locals {
  common_tags = {
    Project     = "moyeota"
    Environment = "v2"
    ManagedBy   = "terraform"
    Owner       = "cloud"
  }

  az_a = var.availability_zones[0]
  az_b = var.availability_zones[1]

  subnet_specs = {
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
  }

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
      path_patterns = ["/api/wss*"]
      target_group  = "websocket"
    }
    rest = {
      priority      = 20
      path_patterns = ["/api/*"]
      target_group  = "rest"
    }
    fastapi = {
      priority      = 30
      path_patterns = ["/ocr/*"]
      target_group  = "fastapi"
    }
  }

  prod_ingress_ports = toset([
    var.frontend_port,
    var.rest_port,
    var.fastapi_port,
    var.websocket_port,
    var.spring_management_port,
  ])
}
