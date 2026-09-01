[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('d1', 'd2')]
    [string]$Experiment,
    [Parameter(Mandatory = $true)]
    [datetime]$InjectionEffectiveUtc,
    [Parameter(Mandatory = $true)]
    [datetime]$AlertFiringUtc,
    [Parameter(Mandatory = $true)]
    [long]$TotalEvents,
    [Parameter(Mandatory = $true)]
    [long]$BadEvents,
    [double]$AvailabilitySlo = 0.995,
    [double]$ObservedP99Ms = 0,
    [double]$LatencySloMs = 2000
)

$ErrorActionPreference = 'Stop'
if ($TotalEvents -le 0) { throw 'TotalEvents debe ser mayor que cero.' }
if ($BadEvents -lt 0 -or $BadEvents -gt $TotalEvents) {
    throw 'BadEvents debe estar entre cero y TotalEvents.'
}
if ($AvailabilitySlo -le 0 -or $AvailabilitySlo -ge 1) {
    throw 'AvailabilitySlo debe expresarse como fracción entre cero y uno.'
}

$errorRate = $BadEvents / $TotalEvents
$availability = 1 - $errorRate
$allowedErrorRate = 1 - $AvailabilitySlo
$burnRate = $errorRate / $allowedErrorRate
$mttdSeconds = ($AlertFiringUtc.ToUniversalTime() - $InjectionEffectiveUtc.ToUniversalTime()).TotalSeconds

$result = [ordered]@{
    experiment = $Experiment
    status = 'confirmed-from-inputs'
    injection_effective_utc = $InjectionEffectiveUtc.ToUniversalTime().ToString('o')
    alert_firing_utc = $AlertFiringUtc.ToUniversalTime().ToString('o')
    mttd_seconds = [math]::Round($mttdSeconds, 3)
    mttd_objective_met = $mttdSeconds -ge 0 -and $mttdSeconds -lt 120
    total_events = $TotalEvents
    bad_events = $BadEvents
    availability = [math]::Round($availability, 6)
    availability_slo = $AvailabilitySlo
    availability_slo_met = $availability -ge $AvailabilitySlo
    allowed_error_rate = [math]::Round($allowedErrorRate, 6)
    observed_error_rate = [math]::Round($errorRate, 6)
    burn_rate = [math]::Round($burnRate, 3)
    observed_p99_ms = $ObservedP99Ms
    latency_slo_ms = $LatencySloMs
    latency_slo_met = if ($ObservedP99Ms -gt 0) { $ObservedP99Ms -lt $LatencySloMs } else { $null }
    caveat = 'El consumo absoluto de error budget requiere además la ventana total y el número de eventos elegibles del SLO.'
}

$result | ConvertTo-Json -Depth 4
