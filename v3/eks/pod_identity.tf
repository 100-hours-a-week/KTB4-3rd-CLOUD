# ServiceAccount와 IAM Role의 연결. 연결은 Namespace와 ServiceAccount가 아직 없어도 만들 수 있다.
resource "aws_eks_pod_identity_association" "rest" {
  for_each = var.stages

  cluster_name    = aws_eks_cluster.this.name
  namespace       = each.key
  service_account = "rest-api"
  role_arn        = aws_iam_role.rest[each.key].arn
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
}
