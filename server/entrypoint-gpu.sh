#!/usr/bin/env bash
# Launch the vLLM OpenAI-compatible server in the FOREGROUND (PID 1 forwards SIGTERM so ECS
# scale-in drains cleanly). vLLM-ONLY — no async SQS worker (that's a separate concern).
#
# Model is config-driven: MODEL_KEY resolves a row in /app/models.json to the HF model,
# served name, tool-call parser, context length, quant, kv-cache dtype, and reasoning parser.
# Codex needs tool-calling, so --enable-auto-tool-choice + --tool-call-parser are added whenever
# a parser is set. Falls back to the MODEL_NAME/MAX_MODEL_LEN env if MODEL_KEY is unset.
set -e

REGISTRY=/app/models.json

if [ -n "${MODEL_KEY:-}" ] && [ -f "$REGISTRY" ]; then
  echo "resolving MODEL_KEY=$MODEL_KEY from $REGISTRY"
  eval "$(python3 - "$MODEL_KEY" <<'PY'
import json, sys, shlex
key = sys.argv[1]
try:
    m = json.load(open("/app/models.json"))["models"][key]
except KeyError:
    sys.stderr.write(f"MODEL_KEY '{key}' not in models.json\n"); sys.exit(3)
def out(k, v): print(f"{k}={shlex.quote(str(v))}")
out("HF_MODEL", m["hf_model"])
out("SERVED_NAME", m.get("served_name", m["hf_model"]))
out("TOOL_PARSER", m.get("tool_parser", ""))
out("MODEL_MAX_LEN", m.get("max_model_len", 32768))
out("MODEL_QUANT", m.get("quant", ""))
out("KV_DTYPE", m.get("kv_cache_dtype", ""))
out("REASONING_PARSER", m.get("reasoning_parser", ""))
out("MODEL_URI", m.get("model_uri", ""))
out("LOAD_FORMAT", m.get("load_format", ""))
out("SPEC_CONFIG", m.get("speculative_config", ""))
out("ENFORCE_EAGER", "1" if m.get("enforce_eager") else "")
out("TRUST_REMOTE", "1" if m.get("trust_remote_code") else "")
out("GPU_UTIL_MODEL", m.get("gpu_memory_utilization", ""))
PY
)"
else
  echo "MODEL_KEY unset -> MODEL_NAME env"
  HF_MODEL="${MODEL_NAME:?set MODEL_KEY or MODEL_NAME}"
  SERVED_NAME="$MODEL_NAME"; TOOL_PARSER="${TOOL_PARSER:-}"
  MODEL_MAX_LEN="${MAX_MODEL_LEN:-32768}"; MODEL_QUANT="${QUANT:-}"; KV_DTYPE=""; REASONING_PARSER=""
  MODEL_URI=""; LOAD_FORMAT=""; SPEC_CONFIG=""; ENFORCE_EAGER=""; TRUST_REMOTE=""; GPU_UTIL_MODEL=""
fi

# model source: prefer model_uri (e.g. s3://<bucket>/<model> for runai_streamer), env-expanded; else hf_model
MODEL_ARG="$HF_MODEL"
if [ -n "$MODEL_URI" ]; then
  MODEL_ARG=$(eval echo "$MODEL_URI")   # expand ${MODEL_S3_BUCKET} etc. from the task env
  case "$MODEL_ARG" in
    *'${'*)  echo "FATAL: model_uri '$MODEL_URI' has an unexpanded variable -> '$MODEL_ARG'; set MODEL_S3_BUCKET in the task env" >&2; exit 4 ;;
    s3:///*) echo "FATAL: model_uri expanded to '$MODEL_ARG' (empty bucket segment); set MODEL_S3_BUCKET" >&2; exit 4 ;;
  esac
fi
# per-model gpu util overrides the env default
GPU_UTIL="${GPU_UTIL_MODEL:-${GPU_MEMORY_UTILIZATION:-0.92}}"
PORT="${VLLM_PORT:-8000}"

# Layer-2 backstop: absolute max-warm self-down. If MAX_WARM_HOURS>0 (taskdef), a background timer
# scales THIS service to 0 after that long — so a warm box downs itself even if the client that ran
# `up` vanished without `down`. Inert unless MAX_WARM_HOURS + SELF_CLUSTER are set (safe on deploys
# that don't opt in). Needs boto3 (Dockerfile) + task-role IAM (server/self-down-iam.json) +
# SELF_CLUSTER/SELF_SERVICE[/SELF_ASG/SELF_SCALABLE] in the taskdef. Complements the client idle
# reaper (Layer 1): Layer 1 downs on idle while the client lives; this is a client-independent cap.
if [ "${MAX_WARM_HOURS:-0}" != "0" ] && [ -n "${SELF_CLUSTER:-}" ]; then
  (
    secs=$(python3 -c "import sys; print(int(float(sys.argv[1])*3600))" "$MAX_WARM_HOURS" 2>/dev/null || echo 0)
    if [ "${secs:-0}" -gt 0 ] 2>/dev/null; then
      sleep "$secs"
      echo "[max-warm] ${MAX_WARM_HOURS}h reached — self-down $(date -u +%H:%M:%SZ)" >&2
      python3 /app/self_down.py
    fi
  ) &
  echo "[max-warm] backstop armed: self-down after ${MAX_WARM_HOURS}h"
fi

echo "starting vLLM: model=$MODEL_ARG served=$SERVED_NAME maxlen=$MODEL_MAX_LEN quant=${MODEL_QUANT:-none} load_format=${LOAD_FORMAT:-default} parser=${TOOL_PARSER:-none} reasoning=${REASONING_PARSER:-none} kv=${KV_DTYPE:-auto} spec=${SPEC_CONFIG:+mtp} eager=${ENFORCE_EAGER:+yes}"
# build argv as an array so the --speculative-config JSON passes as ONE arg (no word-splitting)
args=( --model "$MODEL_ARG" --served-model-name "$SERVED_NAME"
       --max-model-len "$MODEL_MAX_LEN" --gpu-memory-utilization "$GPU_UTIL"
       --host 0.0.0.0 --port "$PORT" )
[ -n "$MODEL_QUANT" ] && [ "$MODEL_QUANT" != "none" ] && args+=( --quantization "$MODEL_QUANT" )
[ -n "$LOAD_FORMAT" ]      && args+=( --load-format "$LOAD_FORMAT" )
[ -n "$KV_DTYPE" ] && [ "$KV_DTYPE" != "auto" ] && args+=( --kv-cache-dtype "$KV_DTYPE" )
[ -n "$TOOL_PARSER" ]      && args+=( --enable-auto-tool-choice --tool-call-parser "$TOOL_PARSER" )
[ -n "$REASONING_PARSER" ] && args+=( --reasoning-parser "$REASONING_PARSER" )
[ -n "$TRUST_REMOTE" ]     && args+=( --trust-remote-code )
[ -n "$ENFORCE_EAGER" ]    && args+=( --enforce-eager )
[ -n "$SPEC_CONFIG" ]      && args+=( --speculative-config "$SPEC_CONFIG" )
exec python3 -m vllm.entrypoints.openai.api_server "${args[@]}"
