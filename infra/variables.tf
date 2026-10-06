# Inputs for the Codex self-hosted GPU inference stack. Everything account/region/model
# specific is a variable so this applies cleanly into a fresh AWS account.

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-2"
}

variable "name_prefix" {
  description = "Prefix for all created resource names."
  type        = string
  default     = "codex-selfhosted"
}

variable "gpu_instance_type" {
  description = "GPU EC2 instance type. g5.xlarge (A10G 24GB) for 14B; g6e.xlarge (L40S 48GB) for Qwen3-Coder-30B / full MCP."
  type        = string
  default     = "g5.xlarge"
}

variable "model_key" {
  description = "MODEL_KEY passed to the container; the server's models.json resolves it to a HF model + parser + flags. NOTE: streaming models (e.g. qwen38-stream) also need model_s3_bucket set, gpu_instance_type=g6e.xlarge, and container_memory=28672."
  type        = string
  default     = "instruct-14b"
}

variable "model_s3_bucket" {
  description = "S3 bucket holding model weights for runai_streamer (the qwen38-stream registry entry streams from s3://<this>/qwen38-27b-fp8). Empty = HF-download models only. When set: the container gets a MODEL_S3_BUCKET env + the task role gets s3:GetObject on this bucket. Keep the bucket in aws_region so the S3 gateway endpoint keeps the read free (no NAT)."
  type        = string
  default     = ""
}

variable "runai_streamer_memory_limit" {
  description = "RUNAI_STREAMER_MEMORY_LIMIT (bytes) — caps the Run:ai streamer's CPU read buffer under container_memory. Only used by streaming (load_format=runai_streamer) models. Empty = unset (streamer default). For the ~29GB FP8 checkpoint on a 28672-MiB task, ~16GiB (17179869184) is safe."
  type        = string
  default     = ""
}

variable "image_tag" {
  description = "Tag of the image in the created ECR repo (server/build.sh pushes this)."
  type        = string
  default     = "gpu"
}

variable "max_gpu_instances" {
  description = "ASG max size (also the app-autoscaling max). Scale-to-zero min is always 0. Default 1: one shared box serves all sessions via vLLM continuous batching; >1 lets the capacity provider over-provision a 2nd idle box during a slow cold start."
  type        = number
  default     = 1
}

variable "use_spot" {
  description = "Use EC2 Spot for the GPU ASG (~65% cheaper; interruptible)."
  type        = bool
  default     = false
}

variable "container_cpu" {
  description = "Task CPU units."
  type        = string
  default     = "4096"
}

variable "container_memory" {
  description = "Task memory (MiB). Leave headroom below the instance RAM. Default 14336 suits instruct-14b on a g5. STREAMING models (qwen38-stream) need 28672 on a g6e.xlarge (32GB RAM) — the runai_streamer buffers weights in CPU RAM, and 14336 OOM-kills mid-load."
  type        = string
  default     = "14336"
}

variable "container_port" {
  description = "Port vLLM serves on (OpenAI-compatible)."
  type        = number
  default     = 8000
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for the container log group."
  type        = number
  default     = 30
}

# ---- Networking: reuse an existing VPC/subnets, or create a minimal one ----

variable "create_network" {
  description = "If true, create a minimal VPC (public+2 private subnets, NAT, S3 gateway endpoint). If false, reuse vpc_id + subnet_ids."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "Existing VPC id (required when create_network = false)."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Existing PRIVATE subnet ids for the GPU tasks (required when create_network = false). Need NAT/egress for HF model download + ECR."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR for the created VPC (only when create_network = true)."
  type        = string
  default     = "10.20.0.0/16"
}
