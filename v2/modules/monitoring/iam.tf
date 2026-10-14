# =============================================================================
# 모니터링 호스트 Role
#   - S3      : 로그 버킷 읽기·쓰기·삭제(Loki compactor), 설정 버킷 읽기
#   - 조회    : Grafana CloudWatch 데이터소스 (지표·Logs Insights·EC2 태그)
#               (grafana.com/docs/grafana/latest/datasources/aws-cloudwatch/configure 권한 목록 중 쓰는 기능만)
#   - 하트비트: Moyeota/Monitoring 네임스페이스에만 PutMetricData (모니터링과 독립된 CloudWatch 알람의 근거)
#   - SSM     : /<prefix>/monitoring/* 비밀값 읽기 + Session Manager 접속
# =============================================================================

locals {
  heartbeat_namespace = "Moyeota/Monitoring"
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name                 = "${var.project_name}-monitoring-host"
  assume_role_policy   = data.aws_iam_policy_document.assume_ec2.json
  max_session_duration = 3600

  tags = merge(var.tags, {
    Name = "${var.project_name}-monitoring-host-role"
  })
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.project_name}-monitoring-host"
  role = aws_iam_role.host.name
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "host" {
  statement {
    sid       = "ListMonitoringBuckets"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [for k in keys(local.buckets) : aws_s3_bucket.this[k].arn]
  }

  statement {
    sid       = "LokiObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.this["logs"].arn}/*"]
  }

  statement {
    sid       = "ReadConfigObjects"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.this["config"].arn}/*"]
  }

  statement {
    sid = "GrafanaCloudWatchRead"
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents",
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "PublishHeartbeat"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.heartbeat_namespace]
    }
  }

  statement {
    sid       = "ReadMonitoringSecrets"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:parameter${local.ssm_path}/*"]
  }

  statement {
    sid       = "DecryptViaSsm"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "host" {
  name   = "${var.project_name}-monitoring-host"
  role   = aws_iam_role.host.id
  policy = data.aws_iam_policy_document.host.json
}
