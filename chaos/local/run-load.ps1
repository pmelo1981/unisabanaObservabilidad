[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('d1', 'd2')]
    [string]$Experiment,
    [string]$ExpectedContext = 'kind-otel-chaos',
    [ValidatePattern('^[0-9]+[smh]$')]
    [string]$Duration = '5m',
    [ValidateRange(1, 100)]
    [int]$Rate = 5,
    [string]$RunId = '',
    [string]$KubeconfigPath = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
if ($KubeconfigPath) {
    $env:KUBECONFIG = (Resolve-Path $KubeconfigPath).Path
} elseif ($ExpectedContext -eq 'kind-otel-chaos') {
    $env:KUBECONFIG = Join-Path $repoRoot '.tools\kubeconfig'
}
$context = (kubectl config current-context).Trim()
if ($context -ne $ExpectedContext) {
    throw "Contexto inseguro: actual='$context', esperado='$ExpectedContext'."
}

if (-not $RunId) {
    $RunId = "$([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH-mm-ssZ'))-$Experiment"
}

$scriptName = if ($Experiment -eq 'd1') { 'd1-service-b.js' } else { 'd2-data-service.js' }
$baseUrl = if ($Experiment -eq 'd1') {
    'http://service-a.services.svc.cluster.local:8000'
} else {
    'http://data-service.data-service.svc.cluster.local:8080'
}
$jobName = "k6-$Experiment-$([DateTime]::UtcNow.ToString('HHmmss'))".ToLowerInvariant()

$namespaceYaml = @"
apiVersion: v1
kind: Namespace
metadata:
  name: chaos-load
  labels:
    istio-injection: enabled
"@
$namespaceYaml | kubectl apply -f - | Out-Null

$loadScriptPath = Join-Path $repoRoot "chaos\load\$scriptName"
$configYaml = kubectl create configmap modulo-d-k6-scripts -n chaos-load `
    --from-file=$loadScriptPath `
    --dry-run=client -o yaml
$configYaml | kubectl apply -f - | Out-Null

$jobYaml = @"
apiVersion: batch/v1
kind: Job
metadata:
  name: $jobName
  namespace: chaos-load
  labels:
    app: k6
    experiment: $Experiment
    run-id: $($RunId.ToLowerInvariant())
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: k6
        experiment: $Experiment
        run-id: $($RunId.ToLowerInvariant())
      annotations:
        sidecar.istio.io/inject: "true"
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:1.7.1
          args: ["run", "/scripts/$scriptName"]
          env:
            - name: BASE_URL
              value: "$baseUrl"
            - name: DURATION
              value: "$Duration"
            - name: RATE
              value: "$Rate"
            - name: RUN_ID
              value: "$RunId"
          volumeMounts:
            - name: scripts
              mountPath: /scripts
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 256Mi
      volumes:
        - name: scripts
          configMap:
            name: modulo-d-k6-scripts
"@

$jobYaml | kubectl apply -f - | Out-Null
Write-Output "LOAD_STARTED_UTC=$([DateTime]::UtcNow.ToString('o'))"
Write-Output "JOB=$jobName"
Write-Output "RUN_ID=$RunId"

kubectl wait --for=condition=Ready pod -n chaos-load -l job-name=$jobName --timeout=180s | Out-Null

function Convert-DurationToSeconds([string]$Value) {
    $number = [int]$Value.Substring(0, $Value.Length - 1)
    switch ($Value[-1]) {
        's' { return $number }
        'm' { return $number * 60 }
        'h' { return $number * 3600 }
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds((Convert-DurationToSeconds $Duration) + 180)
$exitCode = $null
while ([DateTime]::UtcNow -lt $deadline) {
    $pod = kubectl get pod -n chaos-load -l job-name=$jobName -o json | ConvertFrom-Json |
        Select-Object -ExpandProperty items | Select-Object -First 1
    $k6Status = $pod.status.containerStatuses | Where-Object name -eq 'k6'
    if ($k6Status.state.terminated) {
        $exitCode = $k6Status.state.terminated.exitCode
        break
    }
    Start-Sleep -Seconds 5
}

kubectl logs -n chaos-load job/$jobName -c k6
if ($null -eq $exitCode) { throw 'k6 no terminó dentro de la ventana esperada.' }
if ($exitCode -ne 0) { throw "k6 terminó con exit code $exitCode." }
Write-Output "LOAD_FINISHED_UTC=$([DateTime]::UtcNow.ToString('o'))"
