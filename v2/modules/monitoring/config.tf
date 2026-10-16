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
        project_name   = var.project_name
        scrape_targets = var.scrape_targets
      })

      "loki/loki.yaml" = templatefile("${path.module}/templates/loki.yaml.tftpl", {
        region                  = local.region
        logs_bucket             = aws_s3_bucket.this["logs"].bucket
        retention_prod_hours    = var.loki_retention_days.prod * 24
        retention_nonprod_hours = var.loki_retention_days.nonprod * 24
      })

      "grafana/provisioning/datasources/datasources.yaml" = templatefile("${path.module}/templates/grafana/datasources.yaml.tftpl", {
        region = local.region
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
