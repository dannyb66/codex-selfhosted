# GPU capacity: an ECS-GPU-optimized launch template + an ASG (min 0 = scale-to-zero) fronted by
# an ECS capacity provider with managed scaling + managed termination protection. The AMI comes
# from the public SSM parameter (portable across accounts/regions), not a hardcoded id.

data "aws_ssm_parameter" "ecs_gpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id"
}

locals {
  ecs_gpu_ami_id = jsondecode(data.aws_ssm_parameter.ecs_gpu_ami.value)["image_id"]

  instance_user_data = base64encode(<<-EOT
    #!/bin/bash
    echo "ECS_CLUSTER=${aws_ecs_cluster.this.name}" >> /etc/ecs/ecs.config
    echo "ECS_ENABLE_GPU_SUPPORT=true" >> /etc/ecs/ecs.config
  EOT
  )
}

resource "aws_launch_template" "gpu" {
  name_prefix   = "${var.name_prefix}-gpu-"
  image_id      = local.ecs_gpu_ami_id
  instance_type = var.gpu_instance_type
  user_data     = local.instance_user_data

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [aws_security_group.host.id]

  # Spot (optional, ~65% cheaper, interruptible).
  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name_prefix}-gpu" }
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }
}

resource "aws_autoscaling_group" "gpu" {
  name_prefix         = "${var.name_prefix}-gpu-"
  min_size            = 0
  max_size            = var.max_gpu_instances
  desired_capacity    = 0
  vpc_zone_identifier = local.subnet_ids

  launch_template {
    id      = aws_launch_template.gpu.id
    version = "$Latest"
  }

  # Required for ECS managed termination protection (scale-in protection managed by ECS).
  protect_from_scale_in = true

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-gpu"
    propagate_at_launch = true
  }

  # ECS manages desired capacity via the capacity provider; ignore drift.
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "gpu" {
  name = "${var.name_prefix}-gpu-cp"
  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.gpu.arn
    managed_termination_protection = "ENABLED"
    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
      instance_warmup_period    = 300
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [aws_ecs_capacity_provider.gpu.name]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.gpu.name
    weight            = 1
    base              = 0
  }
}
