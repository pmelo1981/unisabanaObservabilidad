[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExpectedContext,
    [ValidateSet('Validate', 'Apply', 'Rollback')]
    [string]$Action = 'Validate',
    [string]$Confirmation = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$manifest = Join-Path $PSScriptRoot 'virtual-service.yaml'
$currentContext = (kubectl config current-context).Trim()

if ($currentContext -ne $ExpectedContext) {
    throw "Contexto inseguro: actual='$currentContext', esperado='$ExpectedContext'."
}

kubectl auth can-i get virtualservices.networking.istio.io -n services | Out-Null
kubectl get namespace services -o name | Out-Null
kubectl get service service-b -n services -o name | Out-Null
kubectl get deployment service-b -n services -o name | Out-Null
kubectl apply --dry-run=server -f $manifest | Out-Null

if ($Action -eq 'Validate') {
    Write-Output "VALIDADO: D1 puede aplicarse en '$currentContext'; no se realizaron cambios."
    exit 0
}

if ($Confirmation -ne 'MODULO-D-SANDBOX') {
    throw "Se requiere -Confirmation MODULO-D-SANDBOX para modificar el clúster."
}

if ($Action -eq 'Apply') {
    kubectl apply -f $manifest
    kubectl get virtualservice chaos-d1-service-b-latency -n services -o yaml
    Write-Output "D1_APPLIED_UTC=$([DateTime]::UtcNow.ToString('o'))"
    exit 0
}

kubectl delete -f $manifest --ignore-not-found=true
if (kubectl get virtualservice chaos-d1-service-b-latency -n services --ignore-not-found) {
    throw 'Rollback incompleto: el VirtualService D1 todavía existe.'
}
Write-Output "D1_ROLLBACK_CONFIRMED_UTC=$([DateTime]::UtcNow.ToString('o'))"
