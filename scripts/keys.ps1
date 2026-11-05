# Create the key file the cluster's Secret is built from. It lives OUTSIDE
# the repository and the keys are never printed.
#
#   ./scripts/keys.ps1          # create it (refuses to overwrite)
#   ./scripts/keys.ps1 -Force   # new keys, then run ./scripts/up.ps1 again
#
# Five values, all random 32-hex-character strings:
#   TS_TENANT_KEYS  which key is which tenant, for the gateway. Tenant c is
#                   capped at the sheddable class, so c cannot jump the
#                   queue by asking for critical.
#   TS_ADMIN_KEY    the gateway's /policy, /stats and /metrics. The
#                   controller sends it; the dashboard reads /stats with it.
#   TS_KEY_A/B/C    the same three tenant keys again, one per variable, so
#                   each tenant pod can take only its own
#                   (deploy/k8s/60-tenant-load.yaml).
#
# Everything runs on this PC and the node ports listen on 127.0.0.1 only, so
# these keys never cross the network. They still exist because the gateway
# decides WHICH TENANT a request belongs to from its key: without them any
# client could claim to be any tenant, and fairness would mean nothing.
param(
    [string]$Path = (Join-Path $env:USERPROFILE '.tenantscaler/kind.env'),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
# One absolute path for every call below: .NET's [IO.File] does not follow
# Set-Location.
$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)

function New-Key {
    $bytes = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    $rng.Dispose()
    -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

if ((Test-Path $Path) -and -not $Force) {
    Write-Output "$Path exists; keeping it (use -Force for new keys)."
    exit 0
}
New-Item -ItemType Directory -Force (Split-Path $Path) | Out-Null
$a = New-Key; $b = New-Key; $c = New-Key
$lines = @(
    "TS_TENANT_KEYS=a:standard=$a,b:standard=$b,c:sheddable=$c",
    "TS_ADMIN_KEY=$(New-Key)",
    "TS_KEY_A=$a",
    "TS_KEY_B=$b",
    "TS_KEY_C=$c"
)
# LF and no BOM: kubectl --from-env-file would otherwise keep a CR in every
# value, and the gateway would compare keys that end in an invisible byte.
[IO.File]::WriteAllText($Path, ($lines -join "`n") + "`n", (New-Object Text.UTF8Encoding $false))
Write-Output "Wrote $Path (keys not printed)."
