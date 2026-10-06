# IAM. Mirrors the proven awsdev roles:
#   - execution role: pull from ECR + write logs (AmazonECSTaskExecutionRolePolicy).
#   - instance role:  ECS agent (register with cluster) + SSM core (so the port-forward tunnel
#                     works) + ECR read. This is what makes the SSM tunnel reach the task.
#   - task role:      vLLM-only needs nothing (no SQS/S3/Snowflake) -> empty role.

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---- ECS task execution role ----
resource "aws_iam_role" "execution" {
  name               = "${var.name_prefix}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "execution_ecs" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---- ECS task role (vLLM-only for HF models; + S3 read for streaming models) ----
resource "aws_iam_role" "task" {
  name               = "${var.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

# Streaming models (load_format=runai_streamer) read weights from S3. Grant read on the model bucket
# ONLY when one is configured; HF-download models need no task permissions.
resource "aws_iam_role_policy" "task_s3_model" {
  count = var.model_s3_bucket != "" ? 1 : 0
  name  = "read-model-bucket"
  role  = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
      Resource = ["arn:aws:s3:::${var.model_s3_bucket}", "arn:aws:s3:::${var.model_s3_bucket}/*"]
    }]
  })
}

# ---- EC2 instance role/profile for the GPU ASG ----
resource "aws_iam_role" "instance" {
  name               = "${var.name_prefix}-instance"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name_prefix}-instance"
  role = aws_iam_role.instance.name
}
