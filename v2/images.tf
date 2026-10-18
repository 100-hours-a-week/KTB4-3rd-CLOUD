# =============================================================================
# 앱 이미지 버킷 접근 권한 (ECS Task Role)
#   이슈: issues/dev-meter-photo-s3-permission-v2-task-role.md
#
#   흐름 (미터기·이체 사진 제출)
#     1. BE가 tmp/<key> presigned PUT URL 발급 → 브라우저가 직접 업로드
#        presigned URL은 서명한 주체(Task Role)의 권한으로 동작 → tmp/* PutObject 필요
#     2. BE가 HeadObject로 tmp/ 업로드 확인 → GetObject + 버킷 ListBucket
#        ListBucket이 없으면 키가 없을 때 404 대신 403이 와서 500으로 이어진다 (10/16 V1 장애 원인)
#     3. BE가 CopyObject로 tmp/ → meter/·transfer/ 복사 → 원본 GetObject, 대상 PutObject
#     tmp/ 원본은 버킷 lifecycle(expire-tmp-uploads, 1일)이 정리하므로 DeleteObject는 주지 않는다.
#
#   V2 컨테이너 인스턴스는 ECS_AWSVPC_BLOCK_IMDS=true라 태스크가 인스턴스 Role로 넘어가지 못한다.
#   → S3 권한은 반드시 Task Role에 있어야 한다.
#
#   V1 대응 (moyeota-ec2-dev-permissions, 10/16 콘솔 수정)에서 옮기지 않은 것
#     - AbortMultipartUpload·ListMultipartUploadParts : backups용 잔여, presigned 단일 PUT에는 불필요
#     - SettlementImagesCopyAndRead : 버킷 이름 없는 ARN이라 효과 없음
#     - ecr:DescribeImages : V1 CD용
#
#   ListBucket에 s3:prefix 조건을 걸지 않는 이유
#     HeadObject가 404/403을 가를 때 하는 ListBucket 평가에는 s3:prefix 키가 없다.
#     조건을 걸면 그 평가가 실패해 다시 403이 된다. 버킷에는 앱 이미지만 있으므로 버킷 단위로 허용한다.
#
#   버킷 자체(CORS·lifecycle·버킷 정책·Public Access Block)는 아직 Terraform 밖에 있다 (콘솔 생성).
#   data 소스로 존재만 확인해 오타·미생성 버킷이면 plan 단계에서 실패시킨다.
# =============================================================================

locals {
  # (스테이지, 서비스) 중 ECS 클러스터가 있고 버킷이 매핑된 것만
  ecs_image_bucket_access = merge({}, [
    for stage in keys(local.ecs_stages) : {
      for svc in var.ecs_image_bucket_services : "${stage}-${svc}" => {
        stage   = stage
        service = svc
        bucket  = var.ecs_image_buckets[stage]
      } if contains(var.ecs_services, svc)
    } if contains(keys(var.ecs_image_buckets), stage)
  ]...)

  ecs_image_bucket_stages = toset([for k, v in local.ecs_image_bucket_access : v.stage])
}

data "aws_s3_bucket" "images" {
  for_each = local.ecs_image_bucket_stages

  bucket = var.ecs_image_buckets[each.key]
}

data "aws_iam_policy_document" "ecs_task_images" {
  for_each = local.ecs_image_bucket_stages

  statement {
    sid     = "ImageObjectsReadWrite"
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject"]
    resources = [
      for prefix in var.ecs_image_object_prefixes : "${data.aws_s3_bucket.images[each.key].arn}/${prefix}/*"
    ]
  }

  statement {
    sid       = "ImageBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.images[each.key].arn]
  }
}

resource "aws_iam_role_policy" "ecs_task_images" {
  for_each = local.ecs_image_bucket_access

  name   = "rw-${each.value.stage}-images"
  role   = module.ecs_cluster[each.value.stage].task_role_names[each.value.service]
  policy = data.aws_iam_policy_document.ecs_task_images[each.value.stage].json
}
