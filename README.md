# codex-selfhosted

Run the **OpenAI Codex CLI against your own self-hosted vLLM model on an AWS GPU** — interactive,
streaming, many concurrent sessions — instead of the paid OpenAI API. Portable + multi-account:
clone anywhere with git access, point it at any AWS account, and go.

Three layers:
- **`bin/`** — the client: `codex-selfhosted` (up/chat/exec/status/down) + `aws-mfa.sh`.
- **`server/`** — a vLLM-only GPU image (Dockerfile + `MODEL_KEY` registry + build).
- **`infra/`** — Terraform to stand up the GPU stack (ASG + capacity provider + ECS + IAM + ECR) in a new account.

The GPU **scales to zero** when idle; you `up` it for a coding session (~10–12 min cold start) and `down` it after.

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
- **`devstral-small-2`** — Devstral Small 2 24B (Mistral3), AWQ ~15GiB. Needs **g5.2xlarge** (A10G 24GB VRAM **+ 32GB RAM** — the 16GB weight file must mmap into >16GB host RAM; g5.xlarge's 16GB OOMs). Strong agentic coder — **but not usable from Codex** (see below).
- **`coder-30b`** — Qwen3-Coder-30B-A3B (Qwen3 MoE, 128 experts/8 active), AWQ **16.85 GiB**. Fits **g5.2xlarge (A10G 24GB)** at ~16–32k ctx / 1–2 sessions (fp8 KV, ~3.7GiB headroom); **g6e.xlarge (L40S 48GB)** for full MCP + more concurrency. Standard MoE (Ampere-safe) + **Codex-native tool format**. *(A strong Codex model, proven on g5.2xlarge.)*
- **`qwen38-stream`** — **Qwen3.8-27B-FP8 + MTP** on **g6e.xlarge (L40S 48GB)**, weights **streamed from S3** (not HF-downloaded). The strongest self-hosted coder here: ~60 tok/s decode (MTP speculative, ~85% draft acceptance), Codex-native tool format. Needs the [weight-streaming setup](#weight-streaming) below. *(Deployed + validated on awsdev 2026-09.)*

> **Qwen3.8-27B is now deployed** (`qwen38-stream`) — the gated-DeltaNet hybrid successor to Qwen3.6-27B.
> Its ~20GB FP8 weights + DeltaNet/MTP kernels need **Ada+ (sm_89)**, so it runs on **g6e.xlarge (L40S 48GB)**,
> not the g5/A10G box; it loads by **streaming from S3** instead of a HF download (see [Weight streaming](#weight-streaming)).
> Watch the qwen3-parser bug #58147 on vLLM upgrades.

Switch via the `model_key` Terraform var (redeploys the taskdef) — no code change. `kv_cache_dtype=fp8`
roughly doubles the number of concurrent sessions the GPU holds.

### Model ↔ Codex compatibility (important)

Codex speaks the OpenAI Responses API + OpenAI tool format. Two layers matter:

1. **vLLM 0.30.0 Responses-API gaps — affect ALL served models.** Codex sends a `developer` role and typed
   `input_text` content chunks; vLLM 0.30.0 rejects both (`400 Unknown message role: developer` /
   `'input_text' is not a valid ChunkTypes`). Fix: run **`bin/codex-role-proxy.py`** between Codex and the
   tunnel (point `base_url` at the proxy) — it rewrites `developer`→`system` and flattens content, streaming
   responses through. Proven: both `400` direct → `200` via proxy.
2. **Model tool-format fit.**
   - **Qwen models (`qwen3_coder` / `hermes` parser)** use the OpenAI tool format → work with Codex (+ proxy).
   - **Mistral models (Devstral, `mistral` parser) do NOT work with Codex.** mistral_common requires
     9-char alphanumeric tool-call ids and rejects Codex's `call_<hex>` ids, plus a
     `justification`/`sandbox_permissions` tool-schema mismatch. Devstral is built for **OpenHands /
     mini-SWE-agent / Mistral `vibe`**, not Codex — drive it with those. For **Codex** on self-hosted, use
     **`coder-30b`** (Qwen3-Coder-30B-A3B) — it fits the same g5.2xlarge box and speaks Codex's tool format.

---

## Weight streaming

Large models (the FP8 `qwen38-stream`) load their weights by **streaming from S3 straight into GPU
memory** via vLLM's [Run:ai Model Streamer](https://docs.vllm.ai/en/latest/models/extensions/runai_model_streamer/)
(`--load-format runai_streamer --model s3://<bucket>/<key>`) instead of downloading from HuggingFace.
Why it wins:

- **Free + fast.** An in-region bucket is read through the VPC's **S3 gateway endpoint** — no NAT
  egress charge — and the streamer saturates bandwidth with concurrent reads: ~57 s to load a 29 GB
  FP8 checkpoint, with no download-to-disk step (a 100 GB root is plenty).
- **Smaller image.** The model is NOT baked in (`gpu-stream` ≈ 9 GB vs ~34 GB baked), so the image
  pull is quick too.

**Measured (g6e.xlarge/L40S, awsdev 2026-09):** cold start **~11.5 min** (launch→served, incl. the MTP
+ CUDA-graph warmup) vs ~17 min for the HF-download variant; **60 tok/s** decode, **~85 %** MTP draft
acceptance; **zero** HF download / NAT cost.

**Setup:**
1. Put the model's HF snapshot in an S3 bucket **in `aws_region`** (so the gateway endpoint keeps the
   read free): `aws s3 cp <snapshot-dir> s3://<bucket>/qwen38-27b-fp8/ --recursive`.
2. Build + push the streaming image: `docker build -f server/Dockerfile.gpu-stream .` → tag `gpu-stream`.
3. Terraform: set `model_s3_bucket`, `model_key = "qwen38-stream"`, `gpu_instance_type = "g6e.xlarge"`,
   `container_memory = "28672"`, `image_tag = "gpu-stream"` (see `terraform.tfvars.example`). The task
   role gets `s3:GetObject` on the bucket automatically when `model_s3_bucket` is set.

> **Proven path vs this one.** The numbers above were validated with a **taskdef `entryPoint` override**
> carrying the exact `vllm` command — recorded in **[`server/qwen38-fp8-streaming.txt`](server/qwen38-fp8-streaming.txt)**,
> the source of truth. The `MODEL_KEY=qwen38-stream` registry path (resolved by `entrypoint-gpu.sh`) is
> the portable equivalent but has **not** been run end-to-end; its generated serve command is close but
> not identical (e.g. omits `--max-num-seqs`/`--enable-prefix-caching`). Bring up a new box from the
> override command first, confirm parity, then switch to the registry.

### Single-GPU deploy config (important)

A one-GPU service (`max_gpu_instances = 1`) must run **at most one task**, or a taskdef change
deadlocks: ECS's default rolling config (max 200 %) tries to start a 2nd task on the single GPU while
the old one still holds it, and the new task sits in `PROVISIONING` forever. `infra/ecs.tf` pins the
service to `deployment_maximum_percent = 100` / `minimum_healthy_percent = 0` with
`availability_zone_rebalancing = "DISABLED"` (AZ Rebalancing requires max > 100 and is pointless for a
single task; needs AWS provider ≥ 5.82). Apply the same if you ever deploy this service by hand.

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
