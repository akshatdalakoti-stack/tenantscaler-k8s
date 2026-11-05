# Take it down.
#
#   ./scripts/down.ps1                 # delete the whole kind cluster
#   ./scripts/down.ps1 -KeepCluster    # delete only what TenantScaler owns
#
# Deleting the cluster is the clean way: nothing of ours survives, the
# node's 400 MB model copy goes with it, and Docker reclaims the space.
# -KeepCluster is the faster loop while you are changing manifests, since
# it leaves the node, its image cache and the model in place.
#
# Neither touches the key file in your profile, and neither touches
# .cache/models. Run ./scripts/keys.ps1 -Force if you want new keys.
param(
    [switch]$KeepCluster
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$cluster = 'tenantscaler'
$ns = 'tenantscaler'

function Step($text) { Write-Output "==> $text" }

if ($KeepCluster) {
    Step "deleting the namespace $ns (pods, Secret, tenants)"
    kubectl delete namespace $ns --ignore-not-found --wait
    Step 'deleting the CRD and the model volume'
    kubectl delete crd tenantscalers.scaling.tenantscaler.dev --ignore-not-found
    kubectl delete pv tenantscaler-llama-models --ignore-not-found
    Write-Output ''
    Write-Output "The cluster $cluster is still running. Bring it back with ./scripts/up.ps1"
    exit 0
}

$existing = @(kind get clusters | ForEach-Object { $_.Trim() })
if ($existing -contains $cluster) {
    Step "deleting the cluster $cluster"
    kind delete cluster --name $cluster
} else {
    Write-Output "==> no cluster named $cluster"
}
Write-Output ''
Write-Output 'Gone. The model stays in .cache/models, so the next ./scripts/up.ps1 does not download it again.'
