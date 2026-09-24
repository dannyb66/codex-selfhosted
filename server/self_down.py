#!/usr/bin/env python3
# Layer-2 backstop: scale THIS ECS service (and its ASG) to zero from inside the GPU container.
# Called by entrypoint-gpu.sh's max-warm watchdog after MAX_WARM_HOURS, so a warm GPU box downs
# itself even if the client that ran `up` vanished without ever running `down` (e.g. closed laptop).
#
# This complements the client-side idle reaper (Layer 1 in bin/codex-selfhosted): Layer 1 downs on
# *idle* while the client is alive; Layer 2 is an *absolute* cap that does not depend on the client.
#
# DEPLOY MODES:
#   - image-entrypoint taskdefs (MODEL_KEY path): entrypoint-gpu.sh spawns the watchdog -> runs THIS file.
#   - entryPoint-OVERRIDE taskdefs (e.g. the devci coder-30b taskdef, which overrides the image
#     entrypoint and so bypasses entrypoint-gpu.sh): the watchdog ships as a non-essential SIDECAR
#     container that inlines this same logic. See server/max-warm-sidecar.json (the live-deployed shape).
#
# Requires (set in the taskdef) + the task role granted the matching permissions:
#   SELF_CLUSTER   ECS cluster name            (ecs:UpdateService)
#   SELF_SERVICE   ECS service name            (ecs:UpdateService)
#   SELF_SCALABLE  optional: application-autoscaling resource id  service/<cluster>/<service>
#                  (application-autoscaling:RegisterScalableTarget) — resets min-capacity to 0 so the
#                  `up`-set min=1 floor is lifted; without it, desired=0 may bounce back to min.
#   SELF_ASG       optional: ASG name          (autoscaling:UpdateAutoScalingGroup)
#   AWS_REGION     region (default us-east-2)
import os, sys

region = os.environ.get("AWS_REGION", "us-east-2")
cluster = os.environ.get("SELF_CLUSTER")
service = os.environ.get("SELF_SERVICE")
asg = os.environ.get("SELF_ASG")
scalable = os.environ.get("SELF_SCALABLE")

if not cluster or not service:
    sys.stderr.write("self_down: SELF_CLUSTER/SELF_SERVICE unset — nothing to do\n")
    sys.exit(0)

try:
    import boto3
except Exception as e:  # noqa: BLE001
    sys.stderr.write(f"self_down: boto3 unavailable ({e}) — cannot self-down\n")
    sys.exit(1)


def attempt(fn, what):
    try:
        fn()
        print(f"self_down: {what} ok", flush=True)
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

print("self_down: done", flush=True)
