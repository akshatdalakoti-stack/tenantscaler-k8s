# Runbook

Operating TenantScaler on one PC. `README.md` says what it is and how to start it; this file is for when you want to change something, or when something is wrong.

## What `up.ps1` actually does

Worth knowing, because each step is also the thing to check when it fails.

1. **Preflight.** `docker`, `kind`, `kubectl` on PATH and the Docker daemon answering. `go` too, unless `-SkipBuild`.
2. **Keys.** Writes `%UserProfile%\.tenantscaler\kind.env` if absent, with five random values: `TS_TENANT_KEYS` (which key is which tenant), `TS_ADMIN_KEY`, and `TS_KEY_A/B/C` one per tenant pod. Never printed. Outside the repository, so nothing commits them.
3. **Model.** Checks `.cache/models/qwen2.5-0.5b-instruct-q4_k_m.gguf` against its pinned SHA-256 and downloads it (~400 MB) only if it does not match.
4. **Image.** `docker build -t tenantscaler:dev .` — one static binary on distroless, every component a subcommand of it.
5. **Cluster.** `kind create cluster --config deploy/kind/kind-config.yaml` if it is not already there. One node, three node ports bound to 127.0.0.1.
6. **Load.** `kind load docker-image` puts the image in the node, so no registry is involved.
7. **Model onto the node.** `docker cp` into `/var/lib/tenantscaler/models`, then re-hashes it *on the node* and refuses to go on if it does not match. Skipped when the node already holds the right bytes.
8. **CRD, then Secret, then manifests.** The CRD must be Established before any `TenantScaler` can exist. The Secret is built with `--dry-run=client` and swapped in with `replace`, so the old one survives until a valid replacement exists, and no copy of the keys ends up in a `last-applied` annotation.
9. **llama swap.** `deploy/kind/05-models.yaml` and `10-model-pool.yaml` replace the simulated pool under the same name and labels.
10. **Restart and wait.** Same image tag with new contents, and keys are read only at start, so every pod running our binary is restarted deliberately.

## Changing the sizing

The budget, the tenants, their guarantees, caps, priorities and SLOs all live in **one** place: `deploy/k8s/15-config.yaml`. The `TenantScaler` resources in `40-tenants.yaml` must list the same tenants with the same specs — `internal/k8s` tests compare the two and fail if they drift, so run `go test ./internal/k8s/` after editing either.

Changing the budget means three files agreeing:

| Where | What |
|---|---|
| `15-config.yaml` | `pool.capacityReplicas` |
| `30-controller.yaml` | `-capacity` |
| `baselines/keda-scaledobject.yaml`, `baselines/hpa-cpu.yaml` | `maxReplicaCount` / `maxReplicas` |

Then:

```bash
kubectl apply -f deploy/k8s/
kubectl -n tenantscaler rollout restart deployment/gateway deployment/tenantscaler-controller
```

A smaller machine wants a smaller budget. Each llama pod asks for 2 CPUs and 1 GiB and gets both as limits, so a budget of 4 reserves 8 CPUs and 4 GiB inside Docker's VM. If pods sit in `Pending`, that is why — `kubectl -n tenantscaler describe pod <name>` will say `Insufficient cpu`. Drop the budget to 2 and give the tenants a guarantee of 1 and a cap of 2.

## Watching it

```bash
kubectl -n tenantscaler get tenantscalers -w          # Grant / Demand / Shedding per tenant
kubectl -n tenantscaler get deployment model-pool -w  # the replica count the controller sets
kubectl -n tenantscaler get pods -w
kubectl -n tenantscaler logs -f deployment/tenant-c   # requests, 429s, p99 TTFT every 30 s
kubectl -n tenantscaler logs deployment/gateway | grep "endpoints changed"
curl -s 127.0.0.1:18090/decisions | python -m json.tool
curl -s 127.0.0.1:18090/status | python -m json.tool
```

`./scripts/demo/explain.ps1` narrates the same thing in plain words in a terminal beside the dashboard, reading only the dashboard's own API. Its CPU section expects host processes, so against the cluster use `kubectl -n tenantscaler top pods` instead (needs metrics-server, which kind does not install).

## When something is wrong

**The Docker daemon is not answering.** Docker Desktop 4.90.0 on this machine crashes at startup on a socket it cannot rename: `initializing Ingest server: ... rename sailor-ingest.sock sailor-ingest.sock.stale: The file cannot be accessed by the system`. Both the socket and its `.stale` target exist, so the rename has nowhere to go. With Docker Desktop not running:

```powershell
Remove-Item "$env:LOCALAPPDATA\Docker\run\*.stale" -Force
```

Then start Docker Desktop and wait for it to settle. Its error dialog also offers *Reset to factory defaults*, which works but throws away every image and container.

**Pods `Pending`.** Almost always CPU or memory. See *Changing the sizing* above. Docker Desktop's VM size is in its own settings (Resources).

**`model-pool` pods in `CrashLoopBackOff`.** Check the model actually arrived:

```bash
docker exec tenantscaler-control-plane ls -l /var/lib/tenantscaler/models
kubectl -n tenantscaler logs deployment/model-pool
```

An empty or truncated file gives a llama.cpp load error. `./scripts/up.ps1` re-hashes it on the node, so the quickest fix is to run it again.

**`model-pool` stuck `ContainerCreating` for minutes on a new cluster.** The first rollout pulls the 309 MB llama.cpp image into the node. `kubectl -n tenantscaler describe pod <name>` shows the `Pulling` event. It happens once per cluster.

**The gateway answers 400.** It does not know that tenant. Its tenants come from the `TenantScaler` resources, falling back to the mounted config; both must list `a`, `b`, `c` in lower case, because a resource name is the fairness id and Kubernetes names are lower case.

**The gateway answers 401 or 403.** The key is not one the gateway knows. Keys are read at start, so after `./scripts/keys.ps1 -Force` you must run `./scripts/up.ps1` again to install and reload the Secret.

**Everything is up but nothing is shed.** Shedding only happens while the pool is contended. If the budget is larger than the tenants can use, there is nothing to arbitrate — which is correct behaviour, not a bug. Lower the budget, or give c a longer spike by editing its `args` in `deploy/k8s/60-tenant-load.yaml` and re-applying:

```bash
kubectl apply -f deploy/k8s/60-tenant-load.yaml
kubectl -n tenantscaler rollout restart deployment/tenant-c
```

(There is no `kubectl set args`; `kubectl -n tenantscaler edit deployment/tenant-c` is the one-off equivalent, but an edit there is lost the next time `up` re-applies the file.)

**The controller's `/status` shows errors and nothing scales.** That is fail-static, on purpose: a cycle that cannot read the gateway's stats or the Deployment's status changes nothing rather than acting on a guess. `tenantscaler_controller_failstatic_total` counts it. Check the gateway is up and that `TS_ADMIN_KEY` matches in both pods.

**Port 8080 already taken.** A host-side `tenantscaler demo` uses the same port. Stop it, or change the `hostPort` in `deploy/kind/kind-config.yaml` and recreate the cluster.

## Teardown

```powershell
./scripts/down.ps1                 # delete the cluster; the node's model copy goes with it
./scripts/down.ps1 -KeepCluster    # delete only the namespace, CRD and PV — the faster loop
```

Neither touches `.cache/models` or the key file, so the next `up` does not download the model again. To invalidate the keys, `./scripts/keys.ps1 -Force` and then `up` again.

## The faster loop while developing

```powershell
go test ./internal/k8s/              # manifests: identities, overlays, security, ports, tenants
./scripts/up.ps1                     # rebuild the image, reload it, re-apply, restart
```

For a change that touches no manifest, `-SkipBuild` is not what you want (it reuses the old image); it is for when you want to re-apply manifests without Go installed. To iterate on the dashboard's JS alone, run it host-side against the cluster instead of rebuilding the image each time:

```powershell
# 15-config.yaml is a ConfigMap, so the config itself sits under
# data["config.yaml"]; -config wants that block, not the wrapper. Take it
# from the running cluster, which is the one that is definitely current:
New-Item -ItemType Directory -Force .run | Out-Null
kubectl -n tenantscaler get configmap tenantscaler-config -o jsonpath='{.data.config\.yaml}' > .run/config.yaml

$env:TS_ADMIN_KEY = (Select-String -Path "$env:USERPROFILE\.tenantscaler\kind.env" -Pattern '^TS_ADMIN_KEY=').Line.Split('=')[1]
bin/tenantscaler.exe demo -config .run/config.yaml -observe-gateway http://127.0.0.1:8081 -observe-controller http://127.0.0.1:18090 -observe-replicas llama -addr 127.0.0.1:8090
```

(In the pods there is no such step: the volume mount exposes the ConfigMap's key as the file `/etc/tenantscaler/config.yaml` directly.)

That reaches the cluster through the node ports and serves the dashboard from your working tree, so a reload picks up edits. Note it needs a port other than 8080, which the cluster's dashboard already has.
