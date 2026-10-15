#!/bin/bash -lc
# Idle + max-warm self-down, INLINED into the max-warm-watchdog sidecar container's entryPoint in
# server/max-warm-sidecar.json (the gpu-stream streaming image does not bake server/self_down.py, so the
# override-path sidecar cannot call it — it carries the identical logic here). Keep this and self_down.py
# in sync. Scales THIS ECS service (+ASG) to zero after IDLE_MINUTES of no vLLM activity OR MAX_WARM_HOURS,
# whichever first. Same /metrics activity signal the client reaper (bin/codex-selfhosted cmd_reap) uses.
IDLE_MIN="${IDLE_MINUTES:-30}"; H="${MAX_WARM_HOURS:-0}"
if [ "$IDLE_MIN" = 0 ] && [ "$H" = 0 ]; then echo '[max-warm] disabled (IDLE_MINUTES=0 and MAX_WARM_HOURS=0)'; exec sleep infinity; fi
echo "[max-warm] armed: idle-down after ${IDLE_MIN}m of no vLLM activity; hard ceiling ${H}h (0=none); poll ${IDLE_POLL_SEC:-60}s"
python3 - <<'PYEOF'
import os, time, urllib.request
idle_s = float(os.environ.get('IDLE_MINUTES', '30')) * 60
max_s  = float(os.environ.get('MAX_WARM_HOURS', '0')) * 3600
poll   = int(os.environ.get('IDLE_POLL_SEC', '60'))
def scrape():
    try: m = urllib.request.urlopen('http://localhost:8000/metrics', timeout=5).read().decode()
    except Exception: return None
    run = succ = 0.0
    for ln in m.splitlines():
        if ln[:1] == '#': continue
        if ln.startswith('vllm:num_requests_running') or ln.startswith('vllm:num_requests_waiting'):
            try: run += float(ln.rsplit(' ', 1)[-1])
            except Exception: pass
        elif ln.startswith('vllm:request_success_total'):
            try: succ += float(ln.rsplit(' ', 1)[-1])
            except Exception: pass
    return run, succ
start = time.time(); last = None; prev = None; reason = None
while True:
    time.sleep(poll)
    now = time.time(); s = scrape()
    if s is not None:
        run, succ = s
        if last is None: last = now
        if run > 0 or (prev is not None and succ != prev): last = now
        prev = succ
    if last is not None and idle_s > 0 and (now - last) >= idle_s:
        reason = 'idle %ds >= %ds' % (int(now - last), int(idle_s)); break
    if max_s > 0 and (now - start) >= max_s:
        reason = 'max-warm %ds >= %ds' % (int(now - start), int(max_s)); break
print('[max-warm] firing self-down (%s)' % reason, flush=True)
import boto3
r = os.environ.get('AWS_REGION', 'us-east-2')
def t(f, w):
    try: f(); print('[max-warm]', w, 'ok', flush=True)
    except Exception as e: print('[max-warm]', w, 'ERR', e, flush=True)
sc = os.environ.get('SELF_SCALABLE'); a = os.environ.get('SELF_ASG')
if sc: t(lambda: boto3.client('application-autoscaling', region_name=r).register_scalable_target(ServiceNamespace='ecs', ResourceId=sc, ScalableDimension='ecs:service:DesiredCount', MinCapacity=0), 'min=0')
t(lambda: boto3.client('ecs', region_name=r).update_service(cluster=os.environ['SELF_CLUSTER'], service=os.environ['SELF_SERVICE'], desiredCount=0), 'desired=0')
if a: t(lambda: boto3.client('autoscaling', region_name=r).update_auto_scaling_group(AutoScalingGroupName=a, MinSize=0, DesiredCapacity=0), 'asg=0')
print('[max-warm] self-down done', flush=True)
PYEOF
echo '[max-warm] sidecar exiting'; sleep 30
