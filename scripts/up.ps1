# Bring the whole thing up on this PC, in Kubernetes, with one command.
#
#   ./scripts/up.ps1               # real llama.cpp replicas
#   ./scripts/up.ps1 -Simulated    # no model needed, latencies simulated
#   ./scripts/up.ps1 -Recreate     # throw the cluster away and build it again
#
# It is safe to run again: the cluster, the keys and the model are reused if
# they are already there, and only the image and the manifests are refreshed.
#
# What ends up running (deploy/k8s, deploy/kind):
#   model-pool    the replicas the controller scales, 1..4 of them
#   gateway       the token-fair gateway every request goes through
#   controller    the arbiter, one cycle every 10 s
#   dashboard     watches the two above; the page you open
#   tenant-a/b/c  three load generators: steady, periodic, spiky
param(
    [switch]$Simulated,
    [switch]$Recreate,
    [switch]$SkipBuild,
    [string]$Keys = (Join-Path $env:USERPROFILE '.tenantscaler/kind.env')
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$cluster = 'tenantscaler'
$ns = 'tenantscaler'
$image = 'tenantscaler:dev'
$modelName = 'qwen2.5-0.5b-instruct-q4_k_m.gguf'
$modelSha = '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db'
$modelUrl = 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf'
$nodeModels = '/var/lib/tenantscaler/models'

function Step($text) { Write-Output "==> $text" }
function Need($exe, $hint) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { throw "$exe is not on PATH. $hint" }
}
function Run($exe, $argv) {
    & $exe @argv
    if ($LASTEXITCODE -ne 0) { throw "$exe $($argv -join ' ') failed with exit code $LASTEXITCODE" }
}
# Probe runs a command we EXPECT may fail, and reports the exit code instead
# of throwing. It exists because of a Windows PowerShell 5.1 trap: when a
# native command's stderr is redirected, each stderr line is wrapped in a
# NativeCommandError, which $ErrorActionPreference = 'Stop' then turns into
# a thrown exception. `docker info` on a dead daemon and `kubectl get` on an
# absent object both write to stderr as their normal way of saying no, so
# redirecting their output would abort the script on the ordinary path.
function Probe($exe, $argv) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $exe @argv 2>&1 | Out-String } finally { $ErrorActionPreference = $old }
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out }
}

# ---------------------------------------------------------------- preflight
Step 'checking the tools'
Need docker  'Install Docker Desktop, or point DOCKER_HOST at any Docker daemon.'
Need kind    'Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/'
Need kubectl 'Install kubectl: https://kubernetes.io/docs/tasks/tools/'
if (-not (Probe docker @('info')).Ok) {
    throw 'The Docker daemon is not answering. Start Docker Desktop, wait for it to settle, then run this again.'
}
if (-not $SkipBuild) { Need go 'Install Go 1.27, or pass -SkipBuild to reuse the image already in Docker.' }

# ------------------------------------------------------------------ the keys
if (-not (Test-Path $Keys)) {
    Step "creating the key file $Keys"
    & (Join-Path $PSScriptRoot 'keys.ps1') -Path $Keys
}
foreach ($k in 'TS_TENANT_KEYS', 'TS_ADMIN_KEY', 'TS_KEY_A', 'TS_KEY_B', 'TS_KEY_C') {
    if (-not (Select-String -Path $Keys -Pattern "^$k=" -Quiet)) {
        throw "$Keys has no $k= line. Run ./scripts/keys.ps1 -Force to write a new one."
    }
}

# ----------------------------------------------------------------- the model
$modelDir = Join-Path (Get-Location) '.cache/models'
$modelPath = Join-Path $modelDir $modelName
if (-not $Simulated) {
    $have = (Test-Path $modelPath) -and ((Get-FileHash -Algorithm SHA256 $modelPath).Hash.ToLower() -eq $modelSha)
    if (-not $have) {
        Step 'downloading the model (about 400 MB, once) into .cache/models'
        New-Item -ItemType Directory -Force $modelDir | Out-Null
        Run curl.exe @('-L', '--fail', '--retry', '3', '--max-time', '3600', '-o', "$modelPath.part", $modelUrl)
        if ((Get-FileHash -Algorithm SHA256 "$modelPath.part").Hash.ToLower() -ne $modelSha) {
            Remove-Item "$modelPath.part"
            throw 'SHA-256 mismatch: the downloaded model is not the pinned one.'
        }
        Move-Item -Force "$modelPath.part" $modelPath
    }
    Write-Output "    model: $modelPath (SHA-256 verified)"
}

# ----------------------------------------------------------------- the image
if (-not $SkipBuild) {
    Step "building the image $image"
    Run docker @('build', '-t', $image, '.')
}

# --------------------------------------------------------------- the cluster
# kind prints one cluster name per line, and PowerShell hands a native
# command's output back as an array of lines already.
$existing = @(kind get clusters | ForEach-Object { $_.Trim() })
if ($Recreate -and ($existing -contains $cluster)) {
    Step "deleting the cluster $cluster"
    Run kind @('delete', 'cluster', '--name', $cluster)
    $existing = @()
}
if ($existing -contains $cluster) {
    Write-Output "==> cluster $cluster is already there"
} else {
    Step "creating the cluster $cluster"
    Run kind @('create', 'cluster', '--config', 'deploy/kind/kind-config.yaml')
}
Run kubectl @('config', 'use-context', "kind-$cluster")

Step "loading $image into the node"
Run kind @('load', 'docker-image', $image, '--name', $cluster)

if (-not $Simulated) {
    Step 'copying the model onto the node'
    $node = "$cluster-control-plane"
    Run docker @('exec', $node, 'mkdir', '-p', $nodeModels)
    # Only copy when the node does not already hold the right bytes: this is
    # 400 MB, and one cluster usually outlives several deploys.
    $hashCmd = "sha256sum $nodeModels/$modelName 2>/dev/null | cut -c1-64"
    $onNode = (docker exec $node sh -c $hashCmd)
    if ($onNode -ne $modelSha) {
        Run docker @('cp', $modelPath, "${node}:$nodeModels/$modelName")
        $onNode = (docker exec $node sh -c $hashCmd)
        if ($onNode -ne $modelSha) { throw "the model on the node hashes to $onNode, not the pinned $modelSha" }
    }
    Write-Output '    model on the node: SHA-256 verified'
}

# ------------------------------------------------------------- the manifests
Step 'applying the namespace and the CRD'
Run kubectl @('apply', '-f', 'deploy/k8s/00-namespace.yaml', '-f', 'deploy/k8s/01-crd.yaml')
Run kubectl @('wait', '--for=condition=Established', '--timeout=60s', 'crd/tenantscalers.scaling.tenantscaler.dev')

# The replacement Secret is built first and swapped in with one call, so the
# old one stays until a valid one exists. create/replace rather than apply:
# apply would keep a copy of every key in a last-applied annotation.
Step 'installing the keys as a Secret'
$tmp = [IO.Path]::GetTempFileName()
try {
    kubectl -n $ns create secret generic tenantscaler-keys --from-env-file=$Keys --dry-run=client -o yaml |
        Set-Content -Encoding utf8 $tmp
    if ($LASTEXITCODE -ne 0) { throw 'building the Secret failed' }
    # --ignore-not-found: an absent Secret comes back as empty output and
    # exit 0, rather than as an error on stderr. That keeps the first run,
    # where there is nothing to replace yet, on the ordinary path.
    $existingSecret = kubectl -n $ns get secret tenantscaler-keys --ignore-not-found -o name
    if ($LASTEXITCODE -ne 0) { throw 'could not ask the cluster about the Secret' }
    if ($existingSecret) { Run kubectl @('-n', $ns, 'replace', '-f', $tmp) }
    else { Run kubectl @('-n', $ns, 'create', '-f', $tmp) }
} finally { Remove-Item -Force $tmp -ErrorAction SilentlyContinue }

Step 'applying TenantScaler'
Run kubectl @('apply', '-f', 'deploy/k8s/')
if ($Simulated) {
    # deploy/k8s runs the simulated engine, so the dashboard badge must not
    # claim real inference.
    Run kubectl @('-n', $ns, 'set', 'env', 'deployment/dashboard', 'TS_OBSERVE_REPLICAS=simulated')
} else {
    Step 'swapping in the real llama.cpp replicas'
    Run kubectl @('apply', '-f', 'deploy/kind/05-models.yaml', '-f', 'deploy/kind/10-model-pool.yaml')
}

# Same image tag with new contents, and keys are only read at start: restart
# everything running our binary so no pod is left on the old one.
Step 'restarting the pods'
$ours = @('gateway', 'tenantscaler-controller', 'dashboard', 'tenant-a', 'tenant-b', 'tenant-c')
if ($Simulated) { $ours += 'model-pool' }
foreach ($d in $ours) { Run kubectl @('-n', $ns, 'rollout', 'restart', "deployment/$d") }

Step 'waiting for the rollout'
if (-not $Simulated) {
    Write-Output '    the first llama.cpp rollout also pulls a 309 MB image into the node, so give it a few minutes'
}
foreach ($d in $ours) { Run kubectl @('-n', $ns, 'rollout', 'status', "deployment/$d", '--timeout=420s') }
Run kubectl @('-n', $ns, 'rollout', 'status', 'deployment/model-pool', '--timeout=420s')

Write-Output ''
Run kubectl @('-n', $ns, 'get', 'tenantscalers,deployments,pods')
Write-Output ''
Write-Output 'Dashboard    http://127.0.0.1:8080'
Write-Output 'Gateway      http://127.0.0.1:8081   (needs a tenant key)'
Write-Output 'Controller   http://127.0.0.1:18090/decisions'
Write-Output ''
Write-Output 'Watch it decide:'
Write-Output '  kubectl -n tenantscaler get tenantscalers -w'
Write-Output '  kubectl -n tenantscaler logs -f deployment/tenant-c'
Write-Output 'Take it down:  ./scripts/down.ps1'
