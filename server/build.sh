#!/usr/bin/env bash
# Build + push the vLLM server image to the account's ECR.
#   CODEX_ENV=<acct> ./server/build.sh [tag]      (default tag: gpu)
# Config (~/.config/codex-selfhosted/<env>.env): ECR_REPO, AWS_REGION, AWS_ACCOUNT_ID.
# Requires docker (buildx) + aws cli; `source bin/aws-mfa.sh <code>` first (or an AWS_PROFILE with ECR perms).
#
# NOTE: this builds a CUDA/x86 image. On an ARM Mac, `--platform linux/amd64` emulates and is SLOW
# (multi-GB). For a fast in-region build, use AWS CodeBuild instead (see README "CodeBuild build path").
set -euo pipefail
CODEX_ENV="${CODEX_ENV:-default}"
CFG="${CODEX_SELFHOSTED_CONFIG:-$HOME/.config/codex-selfhosted/$CODEX_ENV.env}"
[ -f "$CFG" ] && . "$CFG"
MFA="/tmp/mfa-env-$CODEX_ENV.sh"; [ -f "$MFA" ] && { set -a; . "$MFA"; set +a; }
: "${AWS_REGION:?set AWS_REGION}"; : "${AWS_ACCOUNT_ID:?set AWS_ACCOUNT_ID}"; : "${ECR_REPO:?set ECR_REPO (name) in $CFG}"
TAG="${1:-gpu}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REG="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
IMG="$REG/$ECR_REPO:$TAG"

echo "== ECR login =="
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REG"
echo "== build + push $IMG =="
docker buildx build --platform linux/amd64 -f "$ROOT/server/Dockerfile.gpu" -t "$IMG" --push "$ROOT"
echo "pushed $IMG  — set infra var image_uri=\"$IMG\" (or the taskdef) and redeploy."
