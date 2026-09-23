# These outputs map 1:1 to the client wrapper's config.env keys. After `terraform apply`, copy them
# into config.env (or run `terraform output` and paste) so `bin/codex-selfhosted up` targets this stack.

output "aws_region" {
  description = "CODEX_REGION"
  value       = var.aws_region
}

output "cluster_name" {
  description = "CODEX_CLUSTER"
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "CODEX_SERVICE"
  value       = aws_ecs_service.this.name
}

output "asg_name" {
  description = "CODEX_ASG"
  value       = aws_autoscaling_group.gpu.name
}

output "log_group" {
  description = "CODEX_LOG_GROUP"
  value       = aws_cloudwatch_log_group.this.name
}

output "container_port" {
  description = "CODEX_PORT"
  value       = var.container_port
}

output "endpoint_security_group_id" {
  description = "Isolated SG that exposes the vLLM port to the host SG only."
  value       = aws_security_group.endpoint.id
}

output "ecr_repository_url" {
  description = "Push the server image here (server/build.sh)."
  value       = aws_ecr_repository.this.repository_url
}
