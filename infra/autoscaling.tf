# Registers the ECS service as a scalable target with min 0 (scale-to-zero) and max = max_gpu_instances.
# No scaling policies: the client wrapper sets desired_count directly (`up` -> 1, `down` -> 0). This
# target just declares the allowed range and leaves room to attach policies later.
resource "aws_appautoscaling_target" "this" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 0
  max_capacity       = var.max_gpu_instances
}
