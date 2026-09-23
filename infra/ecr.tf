# ECR repo for the vLLM server image (server/build.sh pushes ${name_prefix}:${image_tag}).
resource "aws_ecr_repository" "this" {
  name                 = var.name_prefix
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}
