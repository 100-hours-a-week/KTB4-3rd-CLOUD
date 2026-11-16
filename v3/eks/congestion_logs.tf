variable "congestion_log_readers" {
  description = "혼잡도 로그를 읽을 기존 IAM 사용자 이름"
  type        = set(string)
  default     = ["moyeota-ai-1"]
}

locals {
  congestion_log_stages = toset(["dev", "stg"])
}

resource "aws_cloudwatch_log_group" "congestion" {
  for_each          = local.congestion_log_stages
  name              = "/moyeota/v3/${each.key}/congestion-events"
  retention_in_days = 7
}

resource "aws_iam_role" "congestion_log_writer" {
  name               = "${local.name_prefix}-congestion-log-writer"
  assume_role_policy = data.aws_iam_policy_document.pod_assume.json
}

resource "aws_iam_role_policy" "congestion_log_writer" {
  role = aws_iam_role.congestion_log_writer.name
  name = "write-congestion-events"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = [for group in aws_cloudwatch_log_group.congestion : "${group.arn}:log-stream:*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "congestion_log_writer" {
  cluster_name    = local.cluster_name
  namespace       = "monitoring"
  service_account = "congestion-logs"
  role_arn        = aws_iam_role.congestion_log_writer.arn
}

resource "aws_iam_user_policy" "congestion_log_reader" {
  for_each = var.congestion_log_readers
  user     = each.key
  name     = "${local.name_prefix}-read-congestion-events"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = var.aws_region }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["logs:DescribeLogStreams", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults"]
        Resource = flatten([for group in aws_cloudwatch_log_group.congestion : [group.arn, "${group.arn}:*"]])
      },
      {
        Effect   = "Allow"
        Action   = ["logs:GetLogEvents"]
        Resource = [for group in aws_cloudwatch_log_group.congestion : "${group.arn}:log-stream:*"]
      }
    ]
  })
}
