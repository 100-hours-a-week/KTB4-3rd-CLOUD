# =============================================================================
# dev AI DB(ai_dev) 접근 — 서버 모니터링 봇 (issues/ai-qdrant-setup.md)
#
#   MySQL : dev EC2(aws_instance.host["dev"])의 compose MySQL 컨테이너에 ai_dev DB·계정을 둔다 (RDS 아님, 선택지 A)
#   1) 네트워크 : dev fastapi 태스크 SG → dev EC2 SG 3306
#   2) DDL 실행 : SSM Run Command 문서(<project>-dev-ai-mysql-ddl)가 ai_dev 계정으로 ai_dev DB에만 SQL을 적용한다
#                 - 기존 backend용 문서(moyeota-v2-dev-mysql-ddl)와 분리: backend 계정·DB가 아니라 ai_dev 계정(= ai_dev.* 권한만)으로 실행
#                 - 비밀번호는 호스트의 root 전용 파일(/opt/<project>/ai-dev-db.pass)에서 읽는다 (문서·IAM·state에 값이 남지 않음)
#   3) 권한 : AI IAM 그룹(ai_log_reader_group_name)에 위 문서 + dev EC2에 대한 ssm:SendCommand와 결과 조회만 준다
#
#   호스트 1회 준비(Terraform 밖) : ai_dev DB·계정 생성 + 비밀번호 파일 — issues/ai-qdrant-setup.md 참고
# =============================================================================

locals {
  ai_dev_db_enabled   = contains(keys(local.ecs_service_instances), "dev-fastapi") && contains(keys(local.ecs_stages), "dev")
  ai_dev_ddl_doc_name = "${var.project_name}-dev-ai-mysql-ddl"
  ai_dev_db_pass_file = "/opt/${var.project_name}/ai-dev-db.pass"
}

# -----------------------------------------------------------------------------
# 1) dev fastapi 태스크 → dev EC2 MySQL(3306)
# -----------------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "dev_mysql_from_ai_fastapi" {
  count = local.ai_dev_db_enabled ? 1 : 0

  security_group_id            = aws_security_group.dev_instance.id
  description                  = "MySQL 3306 from dev-fastapi tasks (ai_dev)"
  referenced_security_group_id = module.ecs_service["dev-fastapi"].task_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

# -----------------------------------------------------------------------------
# 2) DDL 실행 문서 (ai_dev 계정 · ai_dev DB 한정)
# -----------------------------------------------------------------------------

resource "aws_ssm_document" "ai_dev_mysql_ddl" {
  count = local.ai_dev_db_enabled ? 1 : 0

  name          = local.ai_dev_ddl_doc_name
  document_type = "Command"
  target_type   = "/AWS::EC2::Instance"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "dev MySQL 컨테이너의 ai_dev DB에 base64로 받은 DDL/SQL을 ai_dev 계정으로 적용"
    parameters = {
      sqlBase64 = {
        type           = "String"
        description    = "적용할 SQL을 base64로 인코딩한 값"
        allowedPattern = "^[A-Za-z0-9+/=]+$"
        maxChars       = 30000
      }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "applyAiDdl"
      inputs = {
        runCommand = [
          "set -eu",
          "f='${local.ai_dev_db_pass_file}'",
          "[ -s \"$f\" ] || { echo \"$f 없음: 호스트에 ai_dev 비밀번호 파일을 먼저 만든다\" >&2; exit 1; }",
          "trap 'rm -f /tmp/ai-dev-ddl.sql' EXIT",
          "echo '{{ sqlBase64 }}' | base64 -d > /tmp/ai-dev-ddl.sql",
          "docker exec -i -e MYSQL_PWD=\"$(cat \"$f\")\" mysql mysql -uai_dev ai_dev < /tmp/ai-dev-ddl.sql",
        ]
      }
    }]
  })

  tags = {
    Stage = "dev"
    Group = "ai"
  }
}

# -----------------------------------------------------------------------------
# 3) AI IAM 그룹 권한 — 위 문서를 dev EC2에 실행하고 결과를 보는 것만
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ai_dev_ddl" {
  count = local.ai_dev_db_enabled && local.ai_log_reader_enabled ? 1 : 0

  # Run Command 콘솔 조회 (리소스 제한이 안 되는 읽기 API) — dev backend 정책(developer_access.tf)과 같은 묶음
  statement {
    sid = "RunCommandConsoleRead"
    actions = [
      "ssm:ListCommands",
      "ssm:ListCommandInvocations",
      "ssm:GetCommandInvocation",
      "ssm:ListDocuments",
      "ssm:ListDocumentVersions",
      "ssm:DescribeDocument",
      "ssm:GetDocument",
      "ssm:DescribeInstanceInformation",
      "ssm:DescribeInstanceProperties",
      "ssm:DescribeDocumentParameters",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "RunAiDevDdlDocument"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:${local.fastapi_log_partition}:ssm:${var.aws_region}:${local.fastapi_log_account_id}:document/${local.ai_dev_ddl_doc_name}",
      "arn:${local.fastapi_log_partition}:ec2:${var.aws_region}:${local.fastapi_log_account_id}:instance/${aws_instance.host["dev"].id}",
    ]
  }
}

resource "aws_iam_policy" "ai_dev_ddl" {
  count = length(data.aws_iam_policy_document.ai_dev_ddl)

  name        = "${var.project_name}-ai-dev-mysql-ddl"
  description = "AI part: run DDL on dev ai_dev database via SSM Run Command document ${local.ai_dev_ddl_doc_name}"
  policy      = data.aws_iam_policy_document.ai_dev_ddl[0].json
}

resource "aws_iam_group_policy_attachment" "ai_dev_ddl" {
  count = length(aws_iam_policy.ai_dev_ddl)

  group      = aws_iam_group.ai_log_reader[0].name
  policy_arn = aws_iam_policy.ai_dev_ddl[0].arn
}

output "ai_dev_ddl_document" {
  description = "AI 파트가 dev ai_dev DB에 DDL을 적용할 때 쓰는 SSM Run Command 문서 이름과 대상 인스턴스"
  value = local.ai_dev_db_enabled ? {
    document    = local.ai_dev_ddl_doc_name
    instance_id = aws_instance.host["dev"].id
    mysql_host  = aws_instance.host["dev"].private_ip
  } : null
}
