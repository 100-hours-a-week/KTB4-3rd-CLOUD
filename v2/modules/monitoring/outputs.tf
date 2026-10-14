output "logs_bucket_name" {
  description = "Loki 청크·인덱스 버킷"
  value       = aws_s3_bucket.this["logs"].bucket
}

output "logs_bucket_arn" {
  value = aws_s3_bucket.this["logs"].arn
}

output "config_bucket_name" {
  description = "모니터링 호스트가 동기화하는 설정 파일 버킷"
  value       = aws_s3_bucket.this["config"].bucket
}

output "config_bucket_arn" {
  value = aws_s3_bucket.this["config"].arn
}
