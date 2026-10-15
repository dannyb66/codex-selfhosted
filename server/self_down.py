#!/usr/bin/env python3
# Layer-2 backstop: watch THIS GPU box from inside the container and scale its ECS service (+ASG) to zero
# on IDLE (no vLLM activity for IDLE_MINUTES) OR an absolute MAX_WARM_HOURS cap — whichever comes first — so
# a warm box downs itself even if the client that ran `up` vanished without `down` (e.g. closed laptop).
#
# This is the server-side teardown (Layer 2); it complements the client-side idle reaper (Layer 1 in
# bin/codex-selfhosted). Layer 1 downs on idle *while the client is alive*; Layer 2 is client-independent:
# it enforces the same idle timeout AND a hard ceiling from inside the task, no matter how the box was upped.
#
# DEPLOY MODES:
#   - image-entrypoint taskdefs (MODEL_KEY path): entrypoint-gpu.sh runs THIS file in the background.
#   - entryPoint-OVERRIDE taskdefs (bypass entrypoint-gpu.sh): the watchdog ships as a non-essential SIDECAR
#     container that inlines this same logic — see server/max-warm-sidecar.json. Keep the two in sync.
#
# Env (taskdef) + task role granted the matching IAM (server/self-down-iam.json):
#   IDLE_MINUTES   idle teardown threshold, minutes; 0 disables idle-down         (default 30)
#   MAX_WARM_HOURS absolute warm-time ceiling, hours; 0 disables the ceiling       (default 0)
#   IDLE_POLL_SEC  /metrics poll interval, seconds                                 (default 60)
#   VLLM_PORT      vLLM port for the /metrics scrape                               (default 8000)
#   SELF_CLUSTER   ECS cluster name            (ecs:UpdateService)
#   SELF_SERVICE   ECS service name            (ecs:UpdateService)
#   SELF_SCALABLE  optional application-autoscaling resource id  service/<cluster>/<service>
#                  (application-autoscaling:RegisterScalableTarget) — lifts the `up`-set min=1 floor.
#   SELF_ASG       optional ASG name           (autoscaling:UpdateAutoScalingGroup)
#   AWS_REGION     region (default us-east-2)
import os, sys, time, urllib.request

region = os.environ.get("AWS_REGION", "us-east-2")
cluster = os.environ.get("SELF_CLUSTER")
service = os.environ.get("SELF_SERVICE")
asg = os.environ.get("SELF_ASG")
scalable = os.environ.get("SELF_SCALABLE")
idle_s = float(os.environ.get("IDLE_MINUTES", "30")) * 60
max_s = float(os.environ.get("MAX_WARM_HOURS", "0")) * 3600
poll = int(os.environ.get("IDLE_POLL_SEC", "60"))
port = os.environ.get("VLLM_PORT", "8000")

if not cluster or not service:
    sys.stderr.write("self_down: SELF_CLUSTER/SELF_SERVICE unset — nothing to do\n")
    sys.exit(0)
if idle_s <= 0 and max_s <= 0:
    sys.stderr.write("self_down: IDLE_MINUTES and MAX_WARM_HOURS both 0 — watchdog disabled\n")
    sys.exit(0)


def activity():
    # Same signal as the client reaper (cmd_reap): in-flight requests, or a rising success counter.
    try:
        m = urllib.request.urlopen(f"http://localhost:{port}/metrics", timeout=5).read().decode()
    except Exception:
        return None  # vLLM not reachable yet (warmup) or a transient error — treated as "no new activity"
    run = succ = 0.0
    for ln in m.splitlines():
        if ln[:1] == "#":
            continue
        if ln.startswith("vllm:num_requests_running") or ln.startswith("vllm:num_requests_waiting"):
            try: run += float(ln.rsplit(" ", 1)[-1])
            except Exception: pass
        elif ln.startswith("vllm:request_success_total"):
            try: succ += float(ln.rsplit(" ", 1)[-1])
            except Exception: pass
    return run, succ


print(f"[self_down] watchdog armed: idle-down {idle_s/60:.0f}m, max-warm {max_s/3600:.1f}h (0=off), poll {poll}s", flush=True)
start = time.time(); last = None; prev = None; reason = None
while True:
    time.sleep(poll)
    now = time.time(); a = activity()
    if a is not None:
        run, succ = a
        if last is None:
            last = now  # start the idle clock once vLLM is reachable (i.e. past warmup)
        if run > 0 or (prev is not None and succ != prev):
            last = now
        prev = succ
    if last is not None and idle_s > 0 and (now - last) >= idle_s:
        reason = f"idle {int(now - last)}s >= {int(idle_s)}s"; break
    if max_s > 0 and (now - start) >= max_s:
        reason = f"max-warm {int(now - start)}s >= {int(max_s)}s"; break

print(f"[self_down] firing self-down ({reason})", flush=True)
try:
    import boto3
except Exception as e:  # noqa: BLE001
    sys.stderr.write(f"self_down: boto3 unavailable ({e}) — cannot self-down\n")
    sys.exit(1)


def attempt(fn, what):
    try:
        fn()
        print(f"[self_down] {what} ok", flush=True)
    except Exception as e:  # noqa: BLE001 — best-effort; keep going so one failure doesn't block the rest
        sys.stderr.write(f"self_down: {what} failed: {e}\n")


# Order mirrors the client `scale_to_zero`: lift the min floor first, then desired=0, then the ASG.
if scalable:
    aas = boto3.client("application-autoscaling", region_name=region)
    attempt(lambda: aas.register_scalable_target(
        ServiceNamespace="ecs", ResourceId=scalable,
        ScalableDimension="ecs:service:DesiredCount", MinCapacity=0), "min-capacity=0")

ecs = boto3.client("ecs", region_name=region)
attempt(lambda: ecs.update_service(cluster=cluster, service=service, desiredCount=0), "service desired=0")

if asg:
    asg_c = boto3.client("autoscaling", region_name=region)
    attempt(lambda: asg_c.update_auto_scaling_group(
        AutoScalingGroupName=asg, MinSize=0, DesiredCapacity=0), "asg min/desired=0")

print("[self_down] done", flush=True)
