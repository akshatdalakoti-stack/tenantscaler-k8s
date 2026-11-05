#!/usr/bin/env bash
# Take it down. This is scripts/down.ps1 for Linux and macOS.
#
#   ./scripts/down.sh                  # delete the whole kind cluster
#   ./scripts/down.sh --keep-cluster   # delete only what TenantScaler owns
#
# Neither touches the key file in your home directory, and neither touches
# .cache/models, so the next ./scripts/up.sh does not download the model
# again.
set -euo pipefail
cd "$(dirname "$0")/.."

cluster=tenantscaler
ns=tenantscaler
keep=0
while [ $# -gt 0 ]; do
	case "$1" in
	--keep-cluster) keep=1 ;;
	*) echo "usage: down.sh [--keep-cluster]" >&2; exit 2 ;;
	esac
	shift
done

step() { echo "==> $*"; }

if [ "$keep" -eq 1 ]; then
	step "deleting the namespace $ns (pods, Secret, tenants)"
	kubectl delete namespace "$ns" --ignore-not-found --wait
	step 'deleting the CRD and the model volume'
	kubectl delete crd tenantscalers.scaling.tenantscaler.dev --ignore-not-found
	kubectl delete pv tenantscaler-llama-models --ignore-not-found
	echo
	echo "The cluster $cluster is still running. Bring it back with ./scripts/up.sh"
	exit 0
fi

if kind get clusters | grep -qx "$cluster"; then
	step "deleting the cluster $cluster"
	kind delete cluster --name "$cluster"
else
	echo "==> no cluster named $cluster"
fi
echo
echo 'Gone. The model stays in .cache/models.'
