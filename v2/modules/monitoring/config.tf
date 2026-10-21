# =============================================================================
# 모니터링 스택 설정 → S3 설정 버킷 (config/)
#   모니터링 호스트의 moyeota-monitoring-sync가 1분마다 받아 반영한다
#     prometheus/ 변경 → /-/reload,  loki/ 변경 → restart,  grafana/ 변경 → 재생성
#   grafana/
#     provisioning/datasources·dashboards·alerting  → 데이터소스·대시보드 폴더·알림 규칙
#     dashboards/*.json                              → "Moyeota V2" 폴더의 대시보드 (UI 수정 불가, 파일로만 변경)
#   terraform apply만으로 설정이 배포되고, 호스트는 교체하지 않는다.
# =============================================================================

locals {
  config_files = merge(
    {
      "compose.yaml" = templatefile("${path.module}/templates/compose.yaml.tftpl", {
        prometheus_image          = var.images.prometheus
        loki_image                = var.images.loki
        grafana_image             = var.images.grafana
        prometheus_retention_days = var.prometheus_retention_days
        grafana_root_url          = var.grafana_root_url
        data_dir                  = local.data_dir
      })

      "prometheus/prometheus.yml" = templatefile("${path.module}/templates/prometheus.yml.tftpl", {
        project_name          = var.project_name
        scrape_targets        = var.scrape_targets
        static_scrape_targets = var.static_scrape_targets
      })

      "loki/loki.yaml" = templatefile("${path.module}/templates/loki.yaml.tftpl", {
        region                  = local.region
        logs_bucket             = aws_s3_bucket.this["logs"].bucket
        retention_prod_hours    = var.loki_retention_days.prod * 24
        retention_nonprod_hours = var.loki_retention_days.nonprod * 24
      })

      "grafana/provisioning/datasources/datasources.yaml" = templatefile("${path.module}/templates/grafana/datasources.yaml.tftpl", {
        region            = local.region
        mysql_datasources = var.mysql_datasources
      })

      "grafana/provisioning/dashboards/provider.yaml" = file("${path.module}/templates/grafana/dashboards-provider.yaml")

      # 인프라 대시보드: CloudWatch 차원(ALB arn suffix, 클러스터 이름)을 렌더링한다
      "grafana/dashboards/infra.json" = templatefile("${path.module}/templates/grafana/dashboards/infra.json.tftpl", {
        project_name = var.project_name
        prod_alb     = var.alb_arn_suffixes.prod
        nonprod_alb  = var.alb_arn_suffixes.nonprod
      })
    },

    # 나머지 대시보드는 그대로 올린다 (UI에서 고친 JSON을 내보내 이 디렉터리에 덮어쓰면 된다)
    {
      for f in fileset("${path.module}/templates/grafana/dashboards", "*.json") :
      "grafana/dashboards/${f}" => file("${path.module}/templates/grafana/dashboards/${f}")
    },

    # 추가 대시보드 (이관 리허설 등). 지우면 sync --delete로 호스트에서도 빠진다
    { for name, json in var.extra_dashboards : "grafana/dashboards/${name}" => json },

    # 알림 규칙·연락처·라우팅. 대상 스테이지가 없으면 올리지 않는다 (Discord 웹훅을 SSM에 넣은 뒤 켠다)
    length(var.grafana_alert_stages) > 0 ? {
      "grafana/provisioning/alerting/alerting.yaml" = templatefile("${path.module}/templates/grafana/alerting.yaml.tftpl", {
        stage_regex = join("|", var.grafana_alert_stages)
      })
    } : {},
  )
}

resource "aws_s3_object" "config" {
  for_each = local.config_files

  bucket       = aws_s3_bucket.this["config"].id
  key          = "config/${each.key}"
  content      = each.value
  content_type = endswith(each.key, ".json") ? "application/json" : "text/plain; charset=utf-8"

  tags = var.tags
}

# =============================================================================
# 동기화 스크립트 배포
#   user data는 처음 부팅 때만 sync.sh를 설치한다 → 스크립트를 바꿔도 떠 있는 호스트에는 반영되지 않았다.
#   S3(bin/)에 올리고 SSM State Manager association이 호스트의 /usr/local/bin/moyeota-monitoring-sync를 교체한다.
#   명령 문자열에 스크립트 해시를 넣어 두어, 스크립트가 바뀔 때만 association이 갱신되고 다시 실행된다.
#   교체 후 다음 주기(1분)부터 새 스크립트가 돈다. .env 키가 바뀌면 Grafana가 한 번 재생성된다.
# =============================================================================

locals {
  sync_script_key = "bin/moyeota-monitoring-sync"
}

resource "aws_s3_object" "sync_script" {
  bucket       = aws_s3_bucket.this["config"].id
  key          = local.sync_script_key
  content      = file("${path.module}/templates/sync.sh")
  content_type = "text/x-shellscript; charset=utf-8"

  tags = var.tags
}

resource "aws_ssm_association" "sync_script" {
  name             = "AWS-RunShellScript"
  association_name = "${var.project_name}-monitoring-sync-script"

  targets {
    key    = "InstanceIds"
    values = [aws_instance.host.id]
  }

  parameters = {
    commands = join(" && ", [
      "aws s3 cp s3://${aws_s3_bucket.this["config"].bucket}/${local.sync_script_key} /usr/local/bin/moyeota-monitoring-sync.new --region ${local.region} --only-show-errors",
      "chmod 0755 /usr/local/bin/moyeota-monitoring-sync.new",
      "mv -f /usr/local/bin/moyeota-monitoring-sync.new /usr/local/bin/moyeota-monitoring-sync",
      "echo sync-script-sha256=${filesha256("${path.module}/templates/sync.sh")}",
    ])
  }

  depends_on = [aws_s3_object.sync_script]
}
