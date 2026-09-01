[CmdletBinding()]
param(
    [string]$ExpectedContext = 'kind-otel-chaos'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$kubeconfig = Join-Path $repoRoot '.tools\kubeconfig'
$helm = Join-Path $repoRoot '.tools\helm\windows-amd64\helm.exe'
$env:KUBECONFIG = $kubeconfig

$context = (kubectl config current-context).Trim()
if ($context -ne $ExpectedContext) {
    throw "Contexto inseguro: actual='$context', esperado='$ExpectedContext'."
}

$passwordBytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Fill($passwordBytes)
$password = [Convert]::ToBase64String($passwordBytes).Replace('/', '_').Replace('+', '-')

function Apply-Secret {
    param([string]$Namespace, [string]$Name, [hashtable]$Literals)
    $args = @('create', 'secret', 'generic', $Name, '-n', $Namespace)
    foreach ($key in $Literals.Keys) {
        $args += "--from-literal=$key=$($Literals[$key])"
    }
    $yaml = & kubectl @args --dry-run=client -o yaml
    $yaml | kubectl apply -f - | Out-Null
}

Apply-Secret -Namespace services -Name local-postgres -Literals @{ password = $password }
Apply-Secret -Namespace data-service -Name local-postgres -Literals @{ password = $password }

$servicesDsn = "postgresql://postgres:$password@postgres.services.svc.cluster.local:5432/labdb"
Apply-Secret -Namespace services -Name service-a-db-secret -Literals @{ DATABASE_URL = $servicesDsn }
Apply-Secret -Namespace services -Name service-b-db-secret -Literals @{ DATABASE_URL = $servicesDsn }

kubectl apply -f (Join-Path $PSScriptRoot 'databases.yaml') | Out-Null
kubectl rollout status deployment/postgres -n services --timeout=180s
kubectl rollout status deployment/gcp-sim -n data-service --timeout=180s
kubectl rollout status deployment/rds-sim -n data-service --timeout=180s

$dashboardYaml = kubectl create configmap grafana-dashboards -n observability `
    --from-file="sli-dashboard.json=$(Join-Path $repoRoot 'grafana\dashboards\sli-dashboard.json')" `
    --dry-run=client -o yaml
$dashboardYaml | kubectl apply -f - | Out-Null

& $helm upgrade --install otel-stack (Join-Path $repoRoot 'helm\otel-stack') `
    -n observability -f (Join-Path $PSScriptRoot 'values-otel-stack.yaml') `
    --set-string grafana.adminPassword=$password --wait --timeout 10m

& $helm upgrade --install service-b (Join-Path $repoRoot 'helm\service-b') `
    -n services --set image.repository=otel-lab/service-b `
    --set image.tag=modulo-d-local --set image.pullPolicy=IfNotPresent `
    --set replicaCount=1 --set autoscaling.enabled=false --wait --timeout 5m

& $helm upgrade --install service-a (Join-Path $repoRoot 'helm\service-a') `
    -n services --set image.repository=otel-lab/service-a `
    --set image.tag=modulo-d-local --set image.pullPolicy=IfNotPresent `
    --set replicaCount=1 --set autoscaling.enabled=false --wait --timeout 5m

$gcpDsn = "postgresql://postgres:$password@gcp-sim.data-service.svc.cluster.local:5432/labdb"
$awsDsn = "postgresql://postgres:$password@rds-sim.data-service.svc.cluster.local:5432/labdb"
& $helm upgrade --install data-service (Join-Path $repoRoot 'helm\data-service') `
    -n data-service --set image.repository=otel-lab/data-service `
    --set image.tag=modulo-d-local --set image.pullPolicy=IfNotPresent `
    --set rdsSim.enabled=false --set-string db.cloudSqlDsn=$gcpDsn `
    --set-string db.awsRdsDsn=$awsDsn --set deploymentEnv=local `
    --set chaosControl.enabled=true `
    --wait --timeout 5m

kubectl get pods -A
Write-Output "LOCAL_DEPLOYMENT_OK_UTC=$([DateTime]::UtcNow.ToString('o'))"
Write-Output 'Grafana password was generated for this runtime and was not written to disk.'
