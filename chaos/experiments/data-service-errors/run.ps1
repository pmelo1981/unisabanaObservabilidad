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
$currentContext = (kubectl config current-context).Trim()

if ($currentContext -ne $ExpectedContext) {
    throw "Contexto inseguro: actual='$currentContext', esperado='$ExpectedContext'."
}

kubectl auth can-i get pods -n data-service | Out-Null
kubectl auth can-i create pods/exec -n data-service | Out-Null
kubectl get service data-service -n data-service -o name | Out-Null

$pods = @(
    kubectl get pods -n data-service `
        -l app.kubernetes.io/name=data-service -o json |
        ConvertFrom-Json |
        Select-Object -ExpandProperty items |
        Where-Object { $_.status.phase -eq 'Running' } |
        ForEach-Object { $_.metadata.name }
)
if (-not $pods) { throw 'No hay pods Running de data-service.' }

$requestCode = @'
import sys, urllib.request
method, url, payload = sys.argv[1:4]
data = payload.encode() if payload else None
req = urllib.request.Request(url, data=data, method=method)
if data:
    req.add_header("Content-Type", "application/json")
with urllib.request.urlopen(req, timeout=10) as response:
    print(response.read().decode())
'@

function Invoke-ChaosApi {
    param([string]$Pod, [string]$Method, [string]$Path, [string]$Payload = '')
    kubectl exec -n data-service $Pod -c data-service -- `
        python -c $requestCode $Method "http://127.0.0.1:8080$Path" $Payload
}

$statuses = foreach ($pod in $pods) {
    $raw = Invoke-ChaosApi -Pod $pod -Method GET -Path '/chaos/status'
    $status = $raw | ConvertFrom-Json
    [pscustomobject]@{
        pod = $pod
        control_enabled = $status.control_enabled
        enabled = $status.experiment.enabled
        scenario = $status.experiment.scenario
        error_rate = $status.experiment.error_rate
        error_status_code = $status.experiment.error_status_code
    }
}
$statuses | Format-Table | Out-String | Write-Output

if ($Action -eq 'Validate') {
    $invalid = @($statuses | Where-Object {
        -not $_.control_enabled -or $_.enabled -or $_.scenario -ne 'normal'
    })
    if ($invalid) {
        throw 'D2 no es seguro: control deshabilitado o existe caos activo.'
    }
    Write-Output "VALIDADO: D2 de aplicación puede ejecutarse en '$currentContext' sobre $($pods.Count) pod(s)."
    exit 0
}

if ($Confirmation -ne 'MODULO-D-SANDBOX') {
    throw 'Se requiere -Confirmation MODULO-D-SANDBOX para modificar el estado.'
}

if ($Action -eq 'Apply') {
    $payload = '{"scenario":"transient_errors","latency_ms":0,"latency_rate":0,"error_rate":0.10,"error_status_code":500,"error_message":"Module D controlled HTTP 500"}'
    foreach ($pod in $pods) {
        Invoke-ChaosApi -Pod $pod -Method POST -Path '/chaos/experiment' -Payload $payload
    }
    Write-Output "D2_APPLIED_UTC=$([DateTime]::UtcNow.ToString('o'))"
    exit 0
}

foreach ($pod in $pods) {
    Invoke-ChaosApi -Pod $pod -Method POST -Path '/chaos/reset' -Payload '{}'
}

$remaining = foreach ($pod in $pods) {
    (Invoke-ChaosApi -Pod $pod -Method GET -Path '/chaos/status' |
        ConvertFrom-Json).experiment.enabled
}
if ($remaining -contains $true) {
    throw 'Rollback incompleto: al menos un pod conserva caos activo.'
}
Write-Output "D2_ROLLBACK_CONFIRMED_UTC=$([DateTime]::UtcNow.ToString('o'))"
