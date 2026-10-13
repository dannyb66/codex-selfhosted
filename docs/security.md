# Security

The design goal: an OpenAI-compatible inference endpoint with the security posture of a managed
internal service — **no public endpoint, ever** — while staying one person to operate. Every
control below is implemented in `infra/` (Terraform), `bin/` (client), or the image; this doc maps
each one to where it lives.

## Zero public ingress

- The GPU task's ENI carries two security groups: a host SG (egress-only, for image/model pulls)
  and an **endpoint SG that allows inbound on the vLLM port only from the host SG**
  (`infra/network.tf`). There is no inbound rule reachable from the internet, no LB, no
  ALB, no public IP on the ENI (`assign_public_ip = false`).
- The only route to the model is an **SSM port-forward** opened by the client
  (`aws ssm start-session`, AWS-StartPortForwardingSessionToRemoteHost) — an IAM-authenticated
  session over AWS's session channel, per user, auditable in CloudTrail, torn down with the
  terminal. The tunnel binds a local port (8000); the role-proxy in front of it binds 127.0.0.1
  only.
- Nothing speaks on the box except vLLM on :8000. The role-proxy and reaper are local-only.

## Identity and credentials

- **MFA-gated client sessions.** `aws-mfa.sh` requires the profile's IAM user to have a **virtual
  MFA device** and obtains a 12-hour session via `sts get-session-token` — so the client's
  effective permissions are always MFA-elevated, never a bare long-lived key. Credentials are
  written to `/tmp/mfa-env-<env>.sh` (mode 600, `AWS_*` only) and re-sourced by the client; they
  are never placed in the repo or in the config files.
- **Least-privilege client actions.** The client profile needs only: ECS describe/list/update
  (the scaling calls), `application-autoscaling:RegisterScalableTarget`,
  `autoscaling:UpdateAutoScalingGroup`, `ssm:StartSession` (+ `DescribeInstanceInformation`),
  `logs:FilterLogEvents`, and `sts:GetSessionToken` + `iam:ListMFADevices`. No wildcard, no
  S3, no ECR for the client role.
- **Container IAM is scoped to the task, and only as large as the model demands:**
  - execution role: ECR pull + CloudWatch log write (AWS managed policy).
  - task role: **empty for HF-download models**; only when `model_s3_bucket` is set does it gain
    `s3:GetObject/ListBucket/GetBucketLocation` on *that one bucket* — the streamed-weights path
    cannot read anything else.
  - instance role: ECS agent registration + SSM core (which is what makes the tunnel possible)
    + ECR read.
- **IMDSv2 required** on the GPU instances (`http_tokens = "required"` in the launch template),
  so metadata-based credential theft requires a valid session token.

## Defense in depth on the down path

The auto-down layers ([ADR-0004](design-decisions/ADR-0004-scale-to-zero-and-two-layer-autodown.md))
are also a security property: the in-container watchdog's only control-plane capability is to scale
its *own* service down, and it is scoped to exact resources via the task's `SELF_*` env vars plus a
dedicated inline policy (`server/self-down-iam.json`) — a compromised container cannot scale
anything else, read anything, or open anything.

## Secrets handling

- No API keys exist in the system at all: Codex talks to vLLM over the local tunnel with no
  `Authorization` header requirement, and the client authenticates to AWS with the MFA session.
- Per-account configs (`~/.config/codex-selfhosted/<env>.env`, mode 600 after `init`) contain
  resource names, never credentials.
- The committed config templates are the only `*.env` in git; `dev.env`-style local files and
  `/tmp/mfa-env-*.sh` are git-ignored.

## What this is not

- It is not a shared multi-tenant service: one team/account, one GPU, IAM-gated per user.
  Authorization is "any user with the client IAM permissions" — sufficient for the team, not for
  public exposure.
- There is no TLS between the tunnel and vLLM: the traffic never leaves the laptop's local
  interfaces (127.0.0.1 hop) and the AWS-internal session channel (TLS end-to-end with AWS).

## Residual risks and mitigations

| Risk | Status / mitigation |
|---|---|
| Warm GPU forgotten running | Two independent auto-down layers (client reaper + in-container max-warm backstop) — see ADR-0004 |
| MFA session outlives intent | 12h max; `status` shows live state; `down` is one command |
| Compromised client laptop | Creds are in `/tmp` (cleared on reboot), scoped to the listed actions; the GPU has no ingress a laptop could exploit without those credentials |
| Model/IP leakage | Weights live in a private in-region S3 bucket readable only by the task role; the served endpoint is unreachable without the tunnel |
