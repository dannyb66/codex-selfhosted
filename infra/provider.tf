# Terraform + AWS provider for the Codex self-hosted GPU inference stack.
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  # Credentials come from the environment / a named profile (AWS_PROFILE) / SSO.
  # For MFA-gated accounts, source bin/aws-mfa.sh first, or set profile below.
  # profile = "your-deployer-profile"
}
