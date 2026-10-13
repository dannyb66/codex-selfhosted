# ADR-0001: Load model weights by streaming from S3, not baking the image or downloading from HuggingFace

**Status:** Accepted — production config for the FP8 model (`qwen38-stream` in `server/models.json`).
**Related:** [architecture.md](../architecture.md) · [performance.md](../performance.md) ·
[ADR-0004](ADR-0004-scale-to-zero-and-two-layer-autodown.md) (this decision only matters because the
service scales to zero and pays a cold-start cost on every `up`)

## Context

The service scales the GPU to zero between sessions (see ADR-0004), which means **every `up` pays a
full cold start**: container image pull, model weight load, and inference-engine warmup, all before
the first token streams. For an interactively-used coding agent, cold-start latency is not a one-time
cost — it recurs every time the box has been idle long enough to auto-down. There are three ways to
get an ~27B-parameter FP8 checkpoint (Qwen3.8-27B-FP8, ~29 GB of weights) onto the GPU at boot, and
they have materially different cold-start and recurring-cost profiles:

1. **Bake the weights into the Docker image.** Simple, but the image becomes enormous
   (~34 GB for this model — `gpu-qwen38fp8` in the image history) and every cold start pays a full
   image pull of that size before the container even starts.
2. **Download from HuggingFace at container boot.** Keeps the image small, but pulls the full
   checkpoint (~28 GB) through the VPC's NAT gateway on *every* cold start — a real, recurring
   dollar cost (NAT data-processing charges) as well as time.
3. **Stream the weights from an in-region S3 bucket straight into GPU memory**, using vLLM's
   [Run:ai Model Streamer](https://docs.vllm.ai/en/latest/models/extensions/runai_model_streamer/)
   (`--load-format runai_streamer --model s3://<bucket>/<key>`), reading through the VPC's **S3
   gateway endpoint** — which carries no NAT charge at all.

## Decision

Host the FP8 checkpoint in an in-region S3 bucket and load it via `runai_streamer`. This is the
`qwen38-stream` entry in `server/models.json`, wired into Terraform via `model_s3_bucket` (grants the
task role scoped `s3:GetObject`/`ListBucket`/`GetBucketLocation` on exactly that bucket —
`infra/iam.tf`) and `runai_streamer_memory_limit` (caps the streamer's CPU-side read buffer under the
task's memory ceiling).

## Why it wins — the comparison

| | Baked image | HF download | **S3 streaming (chosen)** |
|---|---|---|---|
| Image size | ~34 GB | small | **~9 GB** (no weights baked in) |
| Egress cost per cold start | $0 (already baked) | ~28 GB through NAT — a recurring charge | **$0** — in-region S3 gateway endpoint, no NAT |
| Weight load time (measured) | 100.9 s | — (not separately isolated in these artifacts) | **36.1 s** (no speculator) / **53.8 s** (with MTP speculator) |
| Storage cost | ECR image storage, ~$3.4/mo for this image | — | S3 storage, ~$0.66/mo for this checkpoint |
| Reported end-to-end cold start | — | ~17 min (README) | ~11.5 min (README, `models.json`) |

Weight-load numbers are from a live run on `g6e.xlarge` (L40S), captured in
[`server/qwen38-fp8-streaming.txt`](../../server/qwen38-fp8-streaming.txt) — the repo's own
source-of-truth artifact for this benchmark. Cost figures are from the same file.

**A measurement note, stated plainly because it matters:** the end-to-end streamed cold start is
**~11.5 min**, measured — the figure `README.md` and the `models.json` registry entry both record as
validated (live, 2026-09-29). The `server/qwen38-fp8-streaming.txt` artifact also carries a ~8.5–9 min
figure, but that one is a *component sum* it explicitly flags as "not a fresh end-to-end run," and it
proved over-optimistic: summing component timings under-counted real end-to-end overhead, so the
measured ~11.5 min supersedes it. The ~8.5–9 min number is kept in the `server/` artifact as a
corrected estimate, not a competing measurement. Note which way the correction ran — the *flattering*
number (8.5) was the one that lost, which is exactly why estimate-versus-measured is labeled here
rather than averaged into one tidy figure. See [`performance.md`](../performance.md#cold-start) for the
full breakdown with sources.

## Consequences

- **Smaller image → faster iteration.** A ~9 GB image pulls and pushes far faster than a 34 GB one,
  which matters every time the server image changes (not just at cold start).
- **No model weights committed anywhere in CI/CD.** The image and the repo stay generic; swapping the
  S3 key swaps the model with no rebuild.
- **New operational dependency.** The GPU task now needs network access to S3 (satisfied via the
  gateway endpoint, which has no additional cost or NAT dependency) and the task role needs scoped S3
  permissions — a small, explicit IAM grant (`infra/iam.tf`'s `read-model-bucket` policy), not a
  wildcard.
- **The portable path is not yet the proven path — this is the real gap.** The numbers above were
  validated using a **taskdef `entryPoint` override** that ran an exact, hand-verified `vllm serve`
  command (recorded in `server/qwen38-fp8-streaming.txt`). The `MODEL_KEY=qwen38-stream` row in
  `server/models.json` — the portable path, resolved automatically by `entrypoint-gpu.sh` — is
  designed to be equivalent, but **has not been run end-to-end**: its own `_note` field and
  `infra/terraform.tfvars.example` both flag that the generated serve command is close but not
  identical to the proven one (it currently omits `--max-num-seqs` and `--enable-prefix-caching`).
  Standing up a new box on `model_key = "qwen38-stream"` should be treated as *unverified* until that
  parity check is done — the honest status is "designed to work, pending end-to-end validation,"
  not "proven."
- **A dedicated streaming image tag existed historically and no longer does.** Earlier validation used
  a trimmed `gpu-stream`-tagged image (referenced in the benchmark artifact as built from a separate
  `Dockerfile.gpu-stream`); the repo has since consolidated to a single `server/Dockerfile.gpu` that
  the README states carries Run:ai Model Streamer support via the base `vllm/vllm-openai` image, used
  for both baked and streamed models depending on `MODEL_KEY`/`model_uri`. There is intentionally no
  second Dockerfile to keep in sync.

## Alternatives considered and rejected

- **Baking weights into the image** was the original approach and is still a valid rollback (image
  history: `:17`). Rejected for production because the 34 GB pull is the single slowest part of a
  cold start, and it couples a model change to an image rebuild/push cycle.
- **HuggingFace download at boot** is simpler to set up (no S3 bucket to manage) and remains the
  fallback for models that don't need the fastest possible cold start. Rejected for the production FP8
  model because of the recurring NAT cost and the slower reported cold start (~17 min vs ~11.5 min).
