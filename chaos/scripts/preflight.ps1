[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedContext
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$requiredCommands = 'kubectl', 'istioctl', 'k6'
$missing = $requiredCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing) {
    throw "Faltan herramientas: $($missing -join ', ')"
}

$context = (kubectl config current-context).Trim()
if ($context -ne $ExpectedContext) {
    throw "Contexto inseguro: actual='$context', esperado='$ExpectedContext'."
}

$namespaces = 'services', 'data-service', 'observability'
foreach ($namespace in $namespaces) {
    kubectl get namespace $namespace -o name | Out-Null
}

kubectl get deployment service-a -n services -o name | Out-Null
kubectl get deployment service-b -n services -o name | Out-Null
kubectl get deployment data-service -n data-service -o name | Out-Null
kubectl get deployment otel-collector -n observability -o name | Out-Null

foreach ($namespace in 'services', 'data-service') {
    $notReady = kubectl get pods -n $namespace -o json | ConvertFrom-Json |
        Select-Object -ExpandProperty items |
        Where-Object { $_.status.phase -ne 'Running' }
    if ($notReady) {
        throw "Hay pods que no están Running en '$namespace'."
    }
}

istioctl proxy-status
kubectl get virtualservices.networking.istio.io -A

Write-Output "PREFLIGHT_OK_UTC=$([DateTime]::UtcNow.ToString('o'))"
Write-Output "CONTEXT=$context"
