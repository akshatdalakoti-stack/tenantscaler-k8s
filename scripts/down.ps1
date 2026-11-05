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
# As in up.ps1: these commands report progress on stderr, and once that
# stream is redirected or piped, Windows PowerShell 5.1 turns each line into
# a NativeCommandError that $ErrorActionPreference = 'Stop' makes
# terminating. The exit code is what decides.
function Run($exe, $argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @argv 2>&1 | ForEach-Object {
            if ($_ -is [Management.Automation.ErrorRecord]) { Write-Output $_.Exception.Message }
            else { Write-Output $_ }
        }
    } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw "$exe $($argv -join ' ') failed with exit code $LASTEXITCODE" }
}

if ($KeepCluster) {
    Step "deleting the namespace $ns (pods, Secret, tenants)"
    Run kubectl @('delete', 'namespace', $ns, '--ignore-not-found', '--wait')
    Step 'deleting the CRD and the model volume'
    Run kubectl @('delete', 'crd', 'tenantscalers.scaling.tenantscaler.dev', '--ignore-not-found')
    Run kubectl @('delete', 'pv', 'tenantscaler-llama-models', '--ignore-not-found')
    Write-Output ''
    Write-Output "The cluster $cluster is still running. Bring it back with ./scripts/up.ps1"
    exit 0
}

$existing = @(kind get clusters | ForEach-Object { $_.Trim() })
if ($existing -contains $cluster) {
    Step "deleting the cluster $cluster"
    Run kind @('delete', 'cluster', '--name', $cluster)
} else {
    Write-Output "==> no cluster named $cluster"
}
Write-Output ''
Write-Output 'Gone. The model stays in .cache/models, so the next ./scripts/up.ps1 does not download it again.'
