#!/usr/bin/env bash
# Bring the whole thing up on this PC, in Kubernetes, with one command.
# This is scripts/up.ps1 for Linux and macOS; that file explains each step.
#
#   ./scripts/up.sh               # real llama.cpp replicas
#   ./scripts/up.sh --simulated   # no model needed, latencies simulated
#   ./scripts/up.sh --recreate    # throw the cluster away and build it again
#
# Safe to run again: the cluster, the keys and the model are reused when
# they are already there; only the image and the manifests are refreshed.
set -euo pipefail
cd "$(dirname "$0")/.."

cluster=tenantscaler
ns=tenantscaler
image=tenantscaler:dev
model_name=qwen2.5-0.5b-instruct-q4_k_m.gguf
model_sha=74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db
model_url=https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf
node_models=/var/lib/tenantscaler/models
model_path=".cache/models/$model_name"
keys="${TS_KEYS_FILE:-$HOME/.tenantscaler/kind.env}"
simulated=0
recreate=0
skip_build=0

while [ $# -gt 0 ]; do
	case "$1" in
	--simulated) simulated=1 ;;
	--recreate) recreate=1 ;;
	--skip-build) skip_build=1 ;;
	--keys) shift; keys="${1:?--keys needs a file}" ;;
	*) echo "usage: up.sh [--simulated] [--recreate] [--skip-build] [--keys <file>]" >&2; exit 2 ;;
	esac
	shift
done

step() { echo "==> $*"; }
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "$1 is not on PATH. $2" >&2; exit 1; }
}
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64
	else shasum -a 256 "$1" | cut -c1-64; fi
}

# ---------------------------------------------------------------- preflight
step 'checking the tools'
need docker 'Install Docker, or point DOCKER_HOST at a daemon.'
need kind 'Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/'
need kubectl 'Install kubectl: https://kubernetes.io/docs/tasks/tools/'
docker info >/dev/null 2>&1 || { echo 'The Docker daemon is not answering. Start it and run this again.' >&2; exit 1; }
[ "$skip_build" -eq 1 ] || need go 'Install Go 1.27, or pass --skip-build to reuse the image already in Docker.'

# ------------------------------------------------------------------ the keys
if [ ! -e "$keys" ]; then
	step "creating the key file $keys"
	bash "$(dirname "$0")/keys.sh" --path "$keys"
fi
for k in TS_TENANT_KEYS TS_ADMIN_KEY TS_KEY_A TS_KEY_B TS_KEY_C; do
	grep -q "^$k=" "$keys" || { echo "$keys has no $k= line. Run ./scripts/keys.sh --force." >&2; exit 1; }
done

# ----------------------------------------------------------------- the model
if [ "$simulated" -eq 0 ]; then
	if [ ! -e "$model_path" ] || [ "$(sha256_of "$model_path")" != "$model_sha" ]; then
		step 'downloading the model (about 400 MB, once) into .cache/models'
		mkdir -p .cache/models
		curl -L --fail --retry 3 --max-time 3600 -o "$model_path.part" "$model_url"
		got=$(sha256_of "$model_path.part")
		[ "$got" = "$model_sha" ] || { rm -f "$model_path.part"; echo "SHA-256 mismatch: got $got" >&2; exit 1; }
		mv -f "$model_path.part" "$model_path"
	fi
	echo "    model: $model_path (SHA-256 verified)"
fi

# ----------------------------------------------------------------- the image
if [ "$skip_build" -eq 0 ]; then
	step "building the image $image"
	docker build -t "$image" .
fi

# --------------------------------------------------------------- the cluster
if [ "$recreate" -eq 1 ] && kind get clusters | grep -qx "$cluster"; then
	step "deleting the cluster $cluster"
	kind delete cluster --name "$cluster"
fi
if kind get clusters | grep -qx "$cluster"; then
	echo "==> cluster $cluster is already there"
else
	step "creating the cluster $cluster"
	kind create cluster --config deploy/kind/kind-config.yaml
fi
kubectl config use-context "kind-$cluster"

step "loading $image into the node"
kind load docker-image "$image" --name "$cluster"

if [ "$simulated" -eq 0 ]; then
	step 'copying the model onto the node'
	node="$cluster-control-plane"
	docker exec "$node" mkdir -p "$node_models"
	hash_cmd="sha256sum $node_models/$model_name 2>/dev/null | cut -c1-64"
	on_node=$(docker exec "$node" sh -c "$hash_cmd" || true)
	if [ "$on_node" != "$model_sha" ]; then
		docker cp "$model_path" "$node:$node_models/$model_name"
		on_node=$(docker exec "$node" sh -c "$hash_cmd")
		[ "$on_node" = "$model_sha" ] || { echo "the model on the node hashes to $on_node" >&2; exit 1; }
	fi
	echo '    model on the node: SHA-256 verified'
fi

# ------------------------------------------------------------- the manifests
step 'applying the namespace and the CRD'
kubectl apply -f deploy/k8s/00-namespace.yaml -f deploy/k8s/01-crd.yaml
kubectl wait --for=condition=Established --timeout=60s crd/tenantscalers.scaling.tenantscaler.dev

step 'installing the keys as a Secret'
secret=$(mktemp)
trap 'rm -f "$secret"' EXIT
kubectl -n "$ns" create secret generic tenantscaler-keys --from-env-file="$keys" --dry-run=client -o yaml >"$secret"
if kubectl -n "$ns" get secret tenantscaler-keys >/dev/null 2>&1; then
	kubectl -n "$ns" replace -f "$secret"
else
	kubectl -n "$ns" create -f "$secret"
fi

step 'applying TenantScaler'
kubectl apply -f deploy/k8s/
ours="gateway tenantscaler-controller dashboard tenant-a tenant-b tenant-c"
if [ "$simulated" -eq 1 ]; then
	kubectl -n "$ns" set env deployment/dashboard TS_OBSERVE_REPLICAS=simulated
	ours="$ours model-pool"
else
	step 'swapping in the real llama.cpp replicas'
	kubectl apply -f deploy/kind/05-models.yaml -f deploy/kind/10-model-pool.yaml
fi

step 'restarting the pods'
for d in $ours; do kubectl -n "$ns" rollout restart "deployment/$d"; done

step 'waiting for the rollout'
[ "$simulated" -eq 1 ] || echo '    the first llama.cpp rollout also pulls a 309 MB image into the node, so give it a few minutes'
for d in $ours; do kubectl -n "$ns" rollout status "deployment/$d" --timeout=420s; done
kubectl -n "$ns" rollout status deployment/model-pool --timeout=420s

echo
kubectl -n "$ns" get tenantscalers,deployments,pods
cat <<'URLS'

Dashboard    http://127.0.0.1:8080
Gateway      http://127.0.0.1:8081   (needs a tenant key)
Controller   http://127.0.0.1:18090/decisions

Watch it decide:
  kubectl -n tenantscaler get tenantscalers -w
  kubectl -n tenantscaler logs -f deployment/tenant-c
Take it down:  ./scripts/down.sh
URLS
