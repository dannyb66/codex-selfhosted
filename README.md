# codex-selfhosted

Run the **OpenAI Codex CLI against your own self-hosted vLLM model on an AWS GPU** — interactive,
streaming, many concurrent sessions — instead of the paid OpenAI API. Portable + multi-account:
clone anywhere with git access, point it at any AWS account, and go.

Three layers:
- **`bin/`** — the client: `codex-selfhosted` (up/chat/exec/status/down) + `aws-mfa.sh`.
- **`server/`** — a vLLM-only GPU image (Dockerfile + `MODEL_KEY` registry + build).
- **`infra/`** — Terraform to stand up the GPU stack (ASG + capacity provider + ECS + IAM + ECR) in a new account.

The GPU **scales to zero** when idle; you `up` it for a coding session (~10 min cold start) and `down` it after.

---

## Prerequisites

**Client machine (to run Codex):**
- [`aws` CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) + [`session-manager-plugin`](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- [`codex`](https://github.com/openai/codex) CLI, `python3`, `git`, `curl`
- An AWS profile (`aws configure --profile <name>`) whose IAM user has a **virtual MFA device** and the client permissions below.

**Provision machine (to create the infra):** `terraform` ≥ 1.5 + an admin/deployer profile for the target account. `docker` (with buildx) if building the image locally.

**Client IAM permissions** (attach to the profile's user/role):
`ecs:DescribeServices,ListTasks,DescribeTasks,DescribeContainerInstances,UpdateService`,
`application-autoscaling:RegisterScalableTarget`, `autoscaling:UpdateAutoScalingGroup`,
`ssm:StartSession` (+ `DescribeInstanceInformation`), `logs:FilterLogEvents`, and `sts:GetSessionToken` + `iam:ListMFADevices`.

---

## Quickstart — use an existing deployment

```bash
git clone https://github.com/dannyb66/codex-selfhosted && cd codex-selfhosted
cp config.example.env ~/.config/codex-selfhosted/dev.env    # edit: AWS_PROFILE, region, ECS_* names
export CODEX_ENV=dev

source bin/aws-mfa.sh 123456        # 6-digit MFA code -> /tmp/mfa-env-dev.sh (AWS_* only)
bin/codex-selfhosted up             # warm the GPU + open the shared SSM tunnel (~10 min cold)
bin/codex-selfhosted chat           # interactive, streaming — open this in as many terminals as you like
bin/codex-selfhosted down           # scale to $0 when done
```

`chat` = the interactive Codex TUI (streams live). `exec "task"` = one-shot automation. `status` = state.
Concurrency is handled by vLLM (continuous batching) over **one shared tunnel** — every terminal shares it;
each session gets its own isolated `CODEX_HOME`.

### MCP in interactive sessions
`chat` loads a **curated subset** of your `~/.codex` MCP servers (`CODEX_MCP_SET` in the config) so the
prompt still fits the model's context. Keep it small on a 32k model; **don't include `filesystem`** (Codex
writes files natively via `apply_patch`). Full MCP needs a large-context model (see `coder-30b`).

> **Which `codex` you have matters.** The standalone `codex` CLI honors the isolated `CODEX_HOME`, so the
> curated `CODEX_MCP_SET` is exactly what loads. If your `codex` is the one bundled with the **ChatGPT
> desktop app**, it runs a shared *app-server* that starts **all** MCP servers from your global `~/.codex`
> regardless of `CODEX_HOME` — so curation is bypassed, and the first `chat`/`exec` after idle can stall
> a minute or two while that app-server cold-starts every server (it's fast once warm). Install the
> standalone `codex` CLI if you want reliable curation and no cold-start stall.

---

## Stand up a NEW AWS account (infra + server + client)

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars    # set region, gpu_instance_type, model_key, vpc/subnets or create_network=true
terraform init && terraform apply               # creates ECR, GPU ASG+capacity-provider, ECS cluster/service, IAM, SG, log group
terraform output                                # -> cluster/service/asg/log-group/ecr names

# build + push the vLLM image to the new account's ECR
cd .. && CODEX_ENV=<name> source bin/aws-mfa.sh 123456
CODEX_ENV=<name> ECR_REPO=<from-output> server/build.sh gpu   # (or use the CodeBuild path below on a Mac)

# fill ~/.config/codex-selfhosted/<name>.env from `terraform output`, then:
CODEX_ENV=<name> bin/codex-selfhosted up && CODEX_ENV=<name> bin/codex-selfhosted chat
```

**CodeBuild build path (recommended on ARM Macs — no slow local emulation):** author a small CodeBuild
project (privileged, `aws/codebuild/amazonlinux2-x86_64-standard`) that runs `docker build -f server/Dockerfile.gpu .`
against a zip of this repo in S3, and push to ECR. See `server/build.sh` for the login/tag/push commands.

---

## Multi-account

One config file per account under `~/.config/codex-selfhosted/`; select with `CODEX_ENV`:

```bash
CODEX_ENV=dev  source bin/aws-mfa.sh 111111 && CODEX_ENV=dev  bin/codex-selfhosted up
CODEX_ENV=prod source bin/aws-mfa.sh 222222 && CODEX_ENV=prod bin/codex-selfhosted up
```

Each env gets its own `/tmp/mfa-env-<env>.sh` and tunnel pidfile, so sessions don't clobber each other.

---

## Models (`server/models.json`)

- **`instruct-14b`** — Qwen2.5-14B-Instruct-AWQ on **g5.xlarge (A10G 24GB)**. Tool-calls with Codex; curated MCP only (32k).
- **`coder-30b`** — Qwen3-Coder-30B-A3B on **g6e.xlarge (L40S 48GB)**. Best agentic coder + full MCP + large context.

Switch via the `model_key` Terraform var (redeploys the taskdef) — no code change. `kv_cache_dtype=fp8`
roughly doubles the number of concurrent sessions the GPU holds.

---

## How it works

```
codex CLI (any terminal, wire_api=responses) --> SSM port-forward (localhost:PORT, IAM-gated)
   --> vLLM /v1/responses on the EC2 GPU (tool-calling on) --> your code
```

No public ingress: the GPU task's endpoint is reached only through an SSM tunnel (the isolated SG allows
`:PORT` from the cluster host only). Nothing is exposed to the internet; no API keys on the wire.

---

## Cost

GPU billed only while warm (scale-to-zero when down). us-east-2 spot (2026): g5.xlarge ~$0.52/hr,
g6e.xlarge ~$1.07/hr. A shared box serves many concurrent sessions, so per-dev cost drops with team size.
Set `use_spot=true` in Terraform for ~65% off.
