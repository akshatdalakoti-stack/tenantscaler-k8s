#!/usr/bin/env python3
"""Measure the replica capacity C of the running cluster.

C is `controller.replicaCapacityTokensPerSec` in deploy/k8s/15-config.yaml:
the weighted tokens (input + 2 x output) one replica serves per second while
the whole budget is busy. The controller divides each tenant's demand by it
to turn a token rate into a replica count, so a C that is too high makes it
grant too few replicas and everyone queues.

The committed value was measured on bare metal with one CPU-pinned
llama-server per physical core. Pods in a kind node are neither pinned nor
on bare metal, so it has to be measured again here.

    python scripts/measure-capacity.py                 # levels 1,2,4
    python scripts/measure-capacity.py --levels 4      # just the full budget
    python scripts/measure-capacity.py --window 120    # longer, less noisy

What it does, and puts back afterwards:

  * scales the controller to 0, so it stops resizing the pool mid-measurement
  * scales tenants b and c to 0 and points tenant a at a long spike, so one
    standard-class tenant offers far more than the pool can serve
  * for each level: pins the pool, lets it settle, then reads each replica's
    own llamacpp:prompt_tokens_total and llamacpp:tokens_predicted_total
    counters over a window

The counters come from llama-server itself, through the API server's pod
proxy. That matters: the gateway's admittedWeightedTokensPerSec is arrivals
minus shed, measured at admission, so it is bounded by the arrival rate and
the shedding policy rather than by what the replicas actually got through.
Only the engine's own counters measure throughput.
"""

import argparse
import json
import re
import subprocess
import sys
import time

NS = "tenantscaler"
POOL = "model-pool"
PROMPT = "llamacpp:prompt_tokens_total"
PREDICTED = "llamacpp:tokens_predicted_total"
# One standard-class tenant, spiking for long enough to cover every level.
DRIVER_ARGS = ["loadgen", "-gateway", "http://gateway:8080", "-profile", "spike",
               "-report-every", "30s", "-spike-now", "-spike-duration", "3600s"]


def kubectl(*args, check=True):
    r = subprocess.run(["kubectl", "-n", NS, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit("kubectl %s failed: %s" % (" ".join(args), r.stderr.strip()))
    return r.stdout


def pool_pods():
    out = kubectl("get", "pods", "-l", "app.kubernetes.io/name=" + POOL,
                  "--field-selector=status.phase=Running",
                  "-o", "jsonpath={range .items[*]}{.metadata.name} {end}")
    return out.split()


def counters(pod):
    """The replica's own token counters, or None if it is not answering yet."""
    raw = subprocess.run(
        ["kubectl", "get", "--raw",
         "/api/v1/namespaces/%s/pods/%s:8000/proxy/metrics" % (NS, pod)],
        capture_output=True, text=True)
    if raw.returncode != 0:
        return None
    got = {}
    for line in raw.stdout.splitlines():
        m = re.match(r"^(\S+)\s+([0-9.e+-]+)$", line.strip())
        if m and m.group(1) in (PROMPT, PREDICTED):
            got[m.group(1)] = float(m.group(2))
    return got if len(got) == 2 else None


def weighted(c):
    """Weighted tokens: input + 2 x output, the project's demand unit."""
    return c[PROMPT] + 2 * c[PREDICTED]


def measure(level, settle, window):
    kubectl("scale", "deployment/" + POOL, "--replicas=%d" % level)
    kubectl("rollout", "status", "deployment/" + POOL, "--timeout=300s")
    print("  settling for %ds" % settle, flush=True)
    time.sleep(settle)

    pods = pool_pods()
    if len(pods) != level:
        print("  WARNING: %d running pods, expected %d" % (len(pods), level))
    first = {p: counters(p) for p in pods}
    missing = [p for p, c in first.items() if c is None]
    if missing:
        print("  WARNING: no counters from %s" % ", ".join(missing))
    t0 = time.time()
    print("  measuring for %ds" % window, flush=True)
    time.sleep(window)
    secs = time.time() - t0
    second = {p: counters(p) for p in pods}

    per = []
    for p in pods:
        a, b = first.get(p), second.get(p)
        if a is None or b is None:
            continue
        rate = (weighted(b) - weighted(a)) / secs
        per.append(rate)
        print("    %-44s %7.1f weighted tokens/s" % (p, rate))
    if not per:
        print("  no usable samples at level %d" % level)
        return None
    agg = sum(per)
    print("  level %d: aggregate %.1f, per replica %.1f (over %.0fs)"
          % (level, agg, agg / len(per), secs))
    return {"level": level, "replicas": len(per), "aggregate": agg,
            "perReplica": agg / len(per), "seconds": secs}


def main():
    ap = argparse.ArgumentParser(description="Measure replica capacity C on the running cluster.")
    ap.add_argument("--levels", default="1,2,4", help="replica counts to measure (default 1,2,4)")
    ap.add_argument("--window", type=int, default=60, help="measured window per level, seconds")
    ap.add_argument("--settle", type=int, default=30, help="wait before each window, seconds")
    ap.add_argument("--out", default="", help="also write the results here as JSON")
    args = ap.parse_args()
    levels = [int(x) for x in args.levels.split(",") if x.strip()]

    # Remember what to put back, so an interrupted run does not leave the
    # cluster driving one tenant at spike rate with no controller.
    driver = json.loads(kubectl("get", "deployment/tenant-a", "-o",
                                "jsonpath={.spec.template.spec.containers[0].args}") or "[]")
    print("freezing the controller and pointing tenant a at a saturating load")
    kubectl("scale", "deployment/tenantscaler-controller", "--replicas=0")
    for t in ("tenant-b", "tenant-c"):
        kubectl("scale", "deployment/" + t, "--replicas=0")
    kubectl("patch", "deployment/tenant-a", "--type=json", "-p",
            json.dumps([{"op": "replace",
                         "path": "/spec/template/spec/containers/0/args",
                         "value": DRIVER_ARGS}]))
    kubectl("rollout", "status", "deployment/tenant-a", "--timeout=180s")

    results = []
    try:
        for level in levels:
            print("\n== %d replica%s ==" % (level, "" if level == 1 else "s"), flush=True)
            r = measure(level, args.settle, args.window)
            if r:
                results.append(r)
    finally:
        print("\nputting the cluster back")
        kubectl("patch", "deployment/tenant-a", "--type=json", "-p",
                json.dumps([{"op": "replace",
                             "path": "/spec/template/spec/containers/0/args",
                             "value": driver}]), check=False)
        for t in ("tenant-b", "tenant-c"):
            kubectl("scale", "deployment/" + t, "--replicas=1", check=False)
        kubectl("scale", "deployment/tenantscaler-controller", "--replicas=1", check=False)

    if not results:
        raise SystemExit("nothing measured")
    print("\n%-8s %-9s %-12s %-13s" % ("level", "replicas", "aggregate", "per replica"))
    for r in results:
        print("%-8d %-9d %-12.1f %-13.1f" % (r["level"], r["replicas"], r["aggregate"], r["perReplica"]))
    full = max(results, key=lambda r: r["level"])
    print("\nreplicaCapacityTokensPerSec for deploy/k8s/15-config.yaml: %d"
          % round(full["perReplica"]))
    print("(from the largest level measured, %d replicas, which is how C is defined:"
          % full["level"])
    print(" per-replica throughput while the whole budget is busy)")
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(results, f, indent=2)
        print("\nwritten to %s" % args.out)


if __name__ == "__main__":
    sys.exit(main())
