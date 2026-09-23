# The ECS cluster, the vLLM task definition (1 GPU), and the service. The service runs on the GPU
# capacity provider, desired_count 0 (the client's `up` scales it to 1 on demand, `down` back to
# 0). The task ENI carries BOTH the host SG and the isolated endpoint SG, and gets no public IP —
# it is reached only through the SSM port-forward tunnel.

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "this" {
  name = "${var.name_prefix}-cluster"
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name_prefix
  requires_compatibilities = ["EC2"]
  network_mode             = "awsvpc"
  cpu                      = var.container_cpu
  memory                   = var.container_memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "vllm"
      image     = "${aws_ecr_repository.this.repository_url}:${var.image_tag}"
      essential = true
      resourceRequirements = [
        { type = "GPU", value = "1" }
      ]
      portMappings = [
        { containerPort = var.container_port, hostPort = var.container_port, protocol = "tcp" }
      ]
      environment = [
        { name = "MODEL_KEY", value = var.model_key },
        { name = "PORT", value = tostring(var.container_port) }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.this.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "vllm"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-service"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = 0

  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.gpu.name
    weight            = 1
    base              = 0
  }

  network_configuration {
    subnets          = local.subnet_ids
    security_groups  = [aws_security_group.host.id, aws_security_group.endpoint.id]
    assign_public_ip = false
  }

  # ECS manages desired_count as the client scales up/down; don't fight it on apply.
  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}
