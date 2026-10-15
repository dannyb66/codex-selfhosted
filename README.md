# codex-selfhosted

Run the **OpenAI Codex CLI against your own self-hosted vLLM model on an AWS GPU** — interactive,
streaming, many concurrent sessions — instead of the paid OpenAI API. Portable + multi-account:
clone anywhere with git access, point it at any AWS account, and go.

Three layers:
- **`bin/`** — the client: `codex-selfhosted` (init/up/chat/exec/run/resume/status/down) + `aws-mfa.sh`.
- **`server/`** — a vLLM-only GPU image (Dockerfile + `MODEL_KEY` registry + build).
- **`infra/`** — Terraform to stand up the GPU stack (ASG + capacity provider + ECS + IAM + ECR) in a new account.

The GPU **scales to zero** when idle; you `up` it for a coding session (~10–12 min cold start) and `down` it after.

**Documentation:** this README is command/usage-focused. The full set lives in [`docs/`](docs/):
[`OVERVIEW.md`](docs/OVERVIEW.md) (engineering overview + results),
[`architecture.md`](docs/architecture.md) (systems view),
[`design-decisions/`](docs/design-decisions) (ADRs with the tradeoff analysis),
[`models.md`](docs/models.md) (registry, sizing, Codex compatibility),
[`performance.md`](docs/performance.md) (benchmarks + methodology),
[`operations.md`](docs/operations.md) (runbook, auto-down tuning, cost model),
[`security.md`](docs/security.md), and
[`case-study.md`](docs/case-study.md) (first-person case study).

## Contents

- [How it works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Quickstart — use an existing deployment](#quickstart--use-an-existing-deployment)
- [Stand up a NEW AWS account](#stand-up-a-new-aws-account-infra--server--client)
- [Multi-account](#multi-account)
- [Config reference](#config-reference)
- [Models](#models-servermodelsjson)
- [Weight streaming](#weight-streaming)
- [Single-GPU deploy config (important)](#single-gpu-deploy-config-important)
- [Troubleshooting](#troubleshooting)
- [Cost](#cost)
- [Testing](#testing)

---

## How it works

```
codex CLI (any terminal, wire_api=responses)
  --> role-proxy (localhost:8891; rewrites developer->system for vLLM)
  --> SSM port-forward (localhost:8000, IAM-gated, no public ingress)
  --> vLLM /v1/responses on the EC2 GPU (tool-calling on) --> your code
```

No public ingress: the GPU task's endpoint is reached only through an SSM tunnel (the isolated SG
allows `:PORT` from the cluster host only). Nothing is exposed to the internet; no API keys on the wire.

**Concurrency** is handled by vLLM (continuous batching) over **one shared tunnel** — open `chat` in
as many terminals as you like; each session gets its own isolated `CODEX_HOME`.

**Cost control is layered**, so a warm GPU can never be left billable by accident:
1. **Idle auto-down (client).** `up` starts a reaper that polls vLLM `/metrics`; after
   `CODEX_IDLE_TTL_MIN` (default 30) minutes with no request activity it runs `down` for you.
2. **Server-side self-down (backstop).** If the taskdef sets `IDLE_MINUTES` and/or `MAX_WARM_HOURS`, the
   GPU container (`server/self_down.py`) watches vLLM `/metrics` itself and scales the service to zero after
   `IDLE_MINUTES` idle **or** the `MAX_WARM_HOURS` absolute cap, whichever comes first — even if the client
   that ran `up` vanished (closed laptop, killed terminal). Client-independent, so it also catches boxes
   brought up outside `up` (e.g. via the AWS CLI / a redeploy) that the client reaper never sees.

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
bin/codex-selfhosted init           # creates ~/.config/codex-selfhosted/default.env — PRE-FILLED for the reference awsdev deployment
# set AWS_PROFILE in that file to your local `aws configure` profile for the account — the rest is ready

source bin/aws-mfa.sh 123456        # SOURCE it: 6-digit MFA code -> /tmp/mfa-env-default.sh (AWS_* only)
bin/codex-selfhosted up             # warm the GPU + open the shared SSM tunnel (~10–12 min cold)
bin/codex-selfhosted chat           # interactive, streaming — open this in as many terminals as you like
bin/codex-selfhosted down           # scale to $0 when done
```

> The default env targets the reference awsdev deployment (`config.default.env`), so `init` is ready
> after one line (`AWS_PROFILE`), no `CODEX_ENV` needed — and it assumes your IAM profile can reach
> **that** account's resources. **Standing up your own stack?**
> `CODEX_ENV=<name> bin/codex-selfhosted init` seeds the generic `config.example.env` instead — fill
> AWS + ECS names from `terraform output`. See [Multi-account](#multi-account).

`chat` = the interactive Codex TUI (streams live). `exec "task"` = one-shot automation (lean, no MCP).
`run "task"` = `up` (if needed) then chat. `resume [id|--last|--all]` = pick up a past `chat`
(sessions persist in the shared `CODEX_HOME`; no id opens a picker). `status` = state. `down` = stop paying.

> **Which `codex` you have matters.** The standalone `codex` CLI honors the isolated `CODEX_HOME`, so
> the curated `CODEX_MCP_SET` is exactly what loads. If your `codex` is the one bundled with the
> **ChatGPT desktop app**, it runs a shared *app-server* that starts **all** MCP servers from your
> global `~/.codex` regardless of `CODEX_HOME` — so curation is bypassed, and the first `chat`/`exec`
> after idle can stall a minute or two while that app-server cold-starts every server (it's fast once
> warm). Install the standalone `codex` CLI if you want reliable curation and no cold-start stall.

### MCP in interactive sessions
`chat` loads a **curated subset** of your `~/.codex` MCP servers (`CODEX_MCP_SET` in the config) so the
prompt still fits the model's context. Keep it small on a 32k model; **don't include `filesystem`** (Codex
writes files natively via `apply_patch`). Full MCP needs a large-context model (see `coder-30b`).

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

Each env gets its own `/tmp/mfa-env-<env>.sh`, tunnel pidfile, and CODEX_HOME, so sessions don't
clobber each other. Note the tunnel and role-proxy use the **same local ports in every env**
(`CODEX_PORT` 8000 / `CODEX_PROXY_PORT` 8891) — run one env at a time per machine, or override the
ports per env in its config file.

---

## Config reference

Client config lives at `~/.config/codex-selfhosted/${CODEX_ENV}.env` (created by `init`).

**Required** (for `up`/`chat`): `AWS_PROFILE` `AWS_REGION` `ECS_CLUSTER` `ECS_SERVICE` `ASG_NAME` `LOG_GROUP`.
**Required for `build.sh` too:** `ECR_REPO` (name), `AWS_ACCOUNT_ID`.

| Variable | Default | Effect |
|---|---|---|
| `CODEX_PORT` | `8000` | local tunnel port (== vLLM container port) |
| `CODEX_PROXY` / `CODEX_PROXY_PORT` | `1` / `8891` | compat role-proxy in front of the tunnel (see [compatibility](#model--codex-compatibility-important)); `0` bypasses it |
| `CODEX_MCP_SET` | `github,context7` | MCP servers curated into interactive `chat` (from your `~/.codex`) |
| `CODEX_MCP_SET_EXEC` | *(empty)* | MCP servers for one-shot `exec` (empty = none) |
| `CODEX_REASONING_EFFORT` | `xhigh` | Codex `model_reasoning_effort`; qwen3 parser accepts `xhigh\|medium\|low` (not `high`) |
| `CODEX_IDLE_REAPER` | `1` | auto-`down` after idle (Layer 1; `0` = stay warm until manual `down`) |
| `CODEX_IDLE_TTL_MIN` / `CODEX_IDLE_TTL_SEC` | `30` min | idle time before auto-down (`_SEC` overrides for tuning/tests) |
| `CODEX_REAP_POLL` | `60` | seconds between idle checks |
| `MAX_GPU` | `2` | max-capacity registered on the ECS scalable target by `up`/`down` |
| `CODEX_HOME_PERSIST` | `~/.config/codex-selfhosted/codexhome-<env>` | persistent `CODEX_HOME` for `chat`/`resume` (session rollouts) |

---

## Models (`server/models.json`)

| key | model | GPU | ctx | Codex-compatible |
|---|---|---|---|---|
| `instruct-14b` | Qwen2.5-14B-Instruct-AWQ | g5.xlarge (A10G 24GB) | 32k | yes (`hermes` parser); curated MCP only |
| `coder-30b` | Qwen3-Coder-30B-A3B (MoE, 128 experts/8 active), AWQ 16.85 GiB | g5.2xlarge (A10G 24GB) ~16–32k/1–2 sess; g6e.xlarge (L40S 48GB) full MCP + more concurrency | 65k | yes (`qwen3_coder`); proven on g5.2xlarge |
| `qwen38-stream` | Qwen3.8-27B-FP8 + MTP speculative | g6e.xlarge (L40S 48GB, Ada sm_89) | 65k | yes (`qwen3_coder` + `qwen3` reasoning); ~60 tok/s, ~85% draft acceptance — deployed + validated on awsdev 2026-09; needs [weight streaming](#weight-streaming) |
| `qwen38-int4-stream` | RedHatAI Qwen3.8-27B-INT4 (W4A16 body + BF16 lm_head/MTP head) + MTP | g6e.xlarge (L40S 48GB, Ada sm_89) | 256k | yes (same parsers); **71.4 tok/s measured (~40% faster than FP8+MTP, same box 2026-10-12)** at 18.5 vs 28.9 GiB; streamed, validated |
| `devstral-small-2`* | Devstral Small 2 24B (Mistral3) AWQ ~15GiB | g5.2xlarge (A10G 24GB **+ 32GB RAM**; g5.xlarge's 16GB OOMs) | — | **no** — drive with OpenHands / mini-SWE-agent / Mistral `vibe` (see below) |

\* no longer a row in `models.json` — it runs on awsdev via a taskdef entry-point override
(see `server/max-warm-sidecar.json` for the override-sidecar + self-down pattern).

Per-model detail (VRAM math, quant, KV dtype, deploy notes) lives in the `_note` fields of
[`server/models.json`](server/models.json).

> **Qwen3.8-27B is deployed** in two variants: `qwen38-stream` (FP8, 65k ctx) and
> `qwen38-int4-stream` (W4A16, 256k ctx, ~40% faster decode). The gated-DeltaNet hybrid needs
> **Ada+ (sm_89)**, so both run on **g6e.xlarge (L40S 48GB)**, not the g5/A10G box, and load by
> **streaming from S3** instead of a HF download (see [Weight streaming](#weight-streaming)).
> Watch the qwen3-parser bug #58147 on vLLM upgrades.

Switch via the `model_key` Terraform var (redeploys the taskdef) — no code change. `kv_cache_dtype=fp8`
roughly doubles the number of concurrent sessions the GPU holds.

### Model ↔ Codex compatibility (important)

Codex speaks the OpenAI Responses API + OpenAI tool format. Two layers matter:

1. **vLLM 0.30.0 Responses-API gaps — affect ALL served models.** Codex sends a `developer` role and typed
   `input_text` content chunks; vLLM 0.30.0 rejects both (`400 Unknown message role: developer` /
   `'input_text' is not a valid ChunkTypes`). Fix: run **`bin/codex-role-proxy.py`** between Codex and the
   tunnel (point `base_url` at the proxy) — it rewrites `developer`→`system` and flattens content, streaming
   responses through. Proven: both `400` direct → `200` via proxy. On by default in the client
   (`CODEX_PROXY=1`); the rewrites are unit-tested (`python3 tests/test_proxy.py`).
   The client and this section target **vLLM 0.30.0** behavior — `server/Dockerfile.gpu` currently
   tracks `vllm/vllm-openai:latest`, so pin the tag to the version you validated before deploying.
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
2. Build + push the image (the single `Dockerfile.gpu` already ships `runai-model-streamer` support —
   there is no separate streaming Dockerfile): `server/build.sh gpu` → tag `gpu` (or reuse the tag
   your deployment already uses, e.g. `gpu-stream` on awsdev).
3. Terraform: set `model_s3_bucket`, `model_key = "qwen38-stream"`, `gpu_instance_type = "g6e.xlarge"`,
   `container_memory = "28672"`, `image_tag` to the tag from step 2 (see `terraform.tfvars.example`). The task
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

## Troubleshooting

- **`tunnel not up — run: up`** (e.g. after laptop sleep): the SSM port-forward died with the machine.
  Just run `bin/codex-selfhosted up` again — fast if the GPU is still warm.
- **`no /tmp/mfa-env-<env>.sh`** or sudden AWS auth errors: the MFA session file is missing or the
  12-hour session expired — `source bin/aws-mfa.sh <code>` again.
- **`up` times out waiting for the model** (~10–12 min budget): `bin/codex-selfhosted status`, then
  tail the GPU logs: `aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name-prefix vllm --region "$AWS_REGION" --limit 50`.
  Common causes: image pull still running (~9 GB), HF weight download (non-streaming models), and MTP
  speculative warmup (+2–3 min *after* model load, per `server/qwen38-fp8-streaming.txt`).
- **`400 Unknown message role: developer`**: the role-proxy isn't in the path — check
  `status` (role-proxy line) or `CODEX_PROXY` in your env file.
- **New task stuck in `PROVISIONING` after a taskdef change**: single-GPU rolling-deployment deadlock —
  see [Single-GPU deploy config](#single-gpu-deploy-config-important).
- **Client-side logs**: `/tmp/codex-selfhosted-{tunnel,proxy,reaper}-<env>.log`; GPU-side: CloudWatch `$LOG_GROUP`.

---

## Cost

GPU billed only while warm (scale-to-zero when down). us-east-2 spot (2026): g5.xlarge ~$0.52/hr,
g6e.xlarge ~$1.07/hr. A shared box serves many concurrent sessions, so per-dev cost drops with team size.
Set `use_spot=true` in Terraform for ~65% off. Auto-down layers are described under
[How it works](#how-it-works); the idle TTL is `CODEX_IDLE_TTL_MIN`.

---

## Testing

```bash
python3 tests/test_proxy.py    # unit tests for the role-proxy request rewrites (developer->system, chunk flatten, reasoning strip)
```
