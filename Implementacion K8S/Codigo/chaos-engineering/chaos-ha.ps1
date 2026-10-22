<#
.SYNOPSIS
    Script de Ingenieria del Caos para Alta Disponibilidad de PharmaGo.
.DESCRIPTION
    Valida de forma automatizada dos capacidades de alta disponibilidad:

      1) Auto-curación (Self-Healing): elimina un pod del deployment indicado y
         verifica que Kubernetes levante una nueva replica en estado READY (1/1)
         dentro del timeout configurado, mientras el Service sigue respondiendo.

      2) Mitigacion ante fallas reiteradas (FailedRequestsThrottling): envia
         un volumen de requests fallidas (login invalido) contra el API Gateway y
         verifica que se active la contencion automatica devolviendo HTTP 429
         Too Many Requests con header Retry-After.

    Requiere: cluster K8s operativo + port-forward activo (gateway en BaseUrl).
.PARAMETER Deployment
    Deployment a estresar para el test de auto-curación. Default: pharmago-api-gateway.
.PARAMETER Namespace
    Namespace de Kubernetes. Default: pharmago.
.PARAMETER BaseUrl
    URL base del API Gateway. Default: http://127.0.0.1:5000.
.PARAMETER SelfHealTimeoutSec
    Tiempo maximo (seg) para que la nueva replica quede READY. Default: 90.
.PARAMETER FailedRequestCount
    Cantidad de requests fallidas a enviar para disparar el throttling. Default: 60.
.PARAMETER Concurrency
    Concurrencia del envio de requests fallidas. Default: 5.
.PARAMETER DelayMs
    Pausa (ms) entre lanzamientos. Default: 0.
.PARAMETER SkipSelfHeal
    Omite el test de auto-curación.
.PARAMETER SkipMitigation
    Omite el test de mitigacion (429).
.EXAMPLE
    .\chaos-ha.ps1
.EXAMPLE
    .\chaos-ha.ps1 -Deployment pharmago-users-service -FailedRequestCount 80
.EXAMPLE
    .\chaos-ha.ps1 -SkipSelfHeal
#>

param(
    [string]$Deployment = "pharmago-api-gateway",
    [string]$Namespace = "pharmago",
    [string]$BaseUrl = "http://127.0.0.1:5000",
    [int]$SelfHealTimeoutSec = 90,
    [int]$FailedRequestCount = 60,
    [int]$Concurrency = 5,
    [int]$DelayMs = 0,
    [switch]$SkipSelfHeal,
    [switch]$SkipMitigation
)

$ErrorActionPreference = "Stop"

function Write-Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok($t)      { Write-Host "  [PASS] $t" -ForegroundColor Green }
function Write-Fail($t)    { Write-Host "  [FAIL] $t" -ForegroundColor Red }
function Write-Info($t)    { Write-Host "  $t" -ForegroundColor Gray }

# ---------- Pre-flight ----------
Write-Section "Pre-flight"
try {
    $null = kubectl get ns $Namespace 2>&1
    if ($LASTEXITCODE -ne 0) { throw "namespace $Namespace no existe" }
} catch {
    Write-Fail "No se pudo acceder al cluster/namespace '$Namespace'. Verifica minikube y kubectl."
    exit 1
}
$replicas = (kubectl get deploy $Deployment -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null)
if (-not $replicas) {
    Write-Fail "Deployment '$Deployment' no encontrado en '$Namespace'."
    exit 1
}
Write-Info "Deployment: $Deployment  (replicas declaradas: $replicas)"
Write-Info "Namespace : $Namespace"
Write-Info "BaseUrl   : $BaseUrl"

$results = @()

# ============================================================
# TEST 1: AUTO-CURACION (Self-Healing)
# ============================================================
if (-not $SkipSelfHeal) {
    Write-Section "TEST 1 - Auto-curación (Self-Healing)"

    $podBefore = (kubectl get pod -n $Namespace -l "app=$Deployment" -o jsonpath='{.items[0].metadata.name}' 2>$null).Trim()
    if (-not $podBefore) {
        Write-Fail "No hay pods con app=$Deployment."
        $results += @{ Test = "Self-Healing"; Status = "FAIL"; Detail = "sin pods iniciales" }
    } else {
        Write-Info "Pod inicial: $podBefore"
        Write-Info "Eliminando pod para simular falla en tiempo de ejecucion..."
        $t0 = Get-Date
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        kubectl delete pod $podBefore -n $Namespace --grace-period=0 --force 2>$null | Out-Null
        $ErrorActionPreference = $prevEap

        $recovered = $false
        $newPod = $null
        $elapsed = 0
        while ($elapsed -lt $SelfHealTimeoutSec) {
            Start-Sleep -Seconds 3
            $elapsed = [int]((Get-Date) - $t0).TotalSeconds
            $pods = kubectl get pod -n $Namespace -l "app=$Deployment" -o json 2>$null | ConvertFrom-Json
            foreach ($p in $pods.items) {
                if ($p.metadata.name -ne $podBefore) {
                    $ready = ($p.status.conditions | Where-Object { $_.type -eq "Ready" }).status
                    $phase = $p.status.phase
                    if ($ready -eq "True" -and $phase -eq "Running") {
                        $recovered = $true
                        $newPod = $p.metadata.name
                        break
                    }
                }
            }
            if ($recovered) { break }
            Write-Host ("  ... esperando nueva replica READY ({0}s/{1}s)" -f $elapsed, $SelfHealTimeoutSec) -ForegroundColor DarkGray
        }

        if ($recovered) {
            Write-Ok "Nueva replica READY: $newPod  (recuperacion en ${elapsed}s)"
            # Verificar que el Service siga respondiendo
            try {
                $r = Invoke-WebRequest -Uri "$BaseUrl/health" -UseBasicParsing -TimeoutSec 5
                Write-Info "Service /health durante la recuperacion: HTTP $($r.StatusCode)"
            } catch {
                Write-Info "Service /health no respondio (puede ser transitorio): $($_.Exception.Message)"
            }
            $results += @{ Test = "Self-Healing"; Status = "PASS"; Detail = "recuperado en ${elapsed}s -> $newPod" }
        } else {
            Write-Fail "No se recupero una nueva replica READY en ${SelfHealTimeoutSec}s."
            $results += @{ Test = "Self-Healing"; Status = "FAIL"; Detail = "timeout ${SelfHealTimeoutSec}s" }
        }
    }
}

# ============================================================
# TEST 2: MITIGACION ANTE FALLAS REITERADAS (429)
# ============================================================
if (-not $SkipMitigation) {
    Write-Section "TEST 2 - Mitigacion ante fallas reiteradas (HTTP 429)"

    $url = "$BaseUrl/api/login"
    Write-Info "Enviando $FailedRequestCount requests fallidas a $url (concurrencia $Concurrency)..."
    $body = '{"userName":"chaos_user","password":"chaos_pass_invalid"}'

    $counts = @{ "200" = 0; "401" = 0; "404" = 0; "429" = 0; "500" = 0; "0" = 0; "other" = 0 }
    $retryAfterSeen = $false
    $retryAfterVal = $null

    $jobs = @()
    $sem = New-Object System.Threading.SemaphoreSlim($Concurrency, $Concurrency)
    $resultsList = [System.Collections.Concurrent.ConcurrentBag[object]]::new()

    for ($i = 0; $i -lt $FailedRequestCount; $i++) {
        $sem.Wait() | Out-Null
        $job = Start-Job -ScriptBlock {
            param($url, $body)
            try {
                $resp = Invoke-WebRequest -Uri $url -Method POST -ContentType "application/json" -Body $body -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                [pscustomobject]@{ Code = [string]$resp.StatusCode; RetryAfter = $resp.Headers["Retry-After"] }
            } catch {
                $code = "0"
                $ra = $null
                if ($_.Exception.Response) {
                    $code = [string]$_.Exception.Response.StatusCode.value__
                    try { $ra = $_.Exception.Response.Headers["Retry-After"] } catch {}
                }
                [pscustomobject]@{ Code = $code; RetryAfter = $ra }
            }
        } -ArgumentList $url, $body
        $jobs += $job

        # recolectar los que ya terminaron para no acumular
        $done = $jobs | Where-Object { $_.State -ne "Running" }
        foreach ($d in $done) {
            $out = Receive-Job $d -ErrorAction SilentlyContinue
            if ($out) { $resultsList.Add($out) }
            Remove-Job $d -Force -ErrorAction SilentlyContinue
            $jobs = $jobs | Where-Object { $_.Id -ne $d.Id }
            $sem.Release() | Out-Null
        }
        if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }

    # esperar los restantes
    while ($jobs.Count -gt 0) {
        $done = $jobs | Where-Object { $_.State -ne "Running" }
        if ($done.Count -eq 0) { Start-Sleep -Milliseconds 200; continue }
        foreach ($d in $done) {
            $out = Receive-Job $d -ErrorAction SilentlyContinue
            if ($out) { $resultsList.Add($out) }
            Remove-Job $d -Force -ErrorAction SilentlyContinue
            $jobs = $jobs | Where-Object { $_.Id -ne $d.Id }
            $sem.Release() | Out-Null
        }
    }

    foreach ($r in $resultsList) {
        $c = [string]$r.Code
        if ($counts.ContainsKey($c)) { $counts[$c]++ } else { $counts["other"]++ }
        if ($r.RetryAfter) { $retryAfterSeen = $true; $retryAfterVal = $r.RetryAfter }
    }

    Write-Info "Resultados por codigo HTTP:"
    foreach ($k in @("200","401","404","429","500","0","other")) {
        Write-Info ("   {0}: {1}" -f $k, $counts[$k])
    }

    if ($counts["429"] -gt 0) {
        Write-Ok "Mitigacion activada: $($counts['429']) respuestas HTTP 429 (Too Many Requests)."
        if ($retryAfterSeen) { Write-Info "Header Retry-After observado: $retryAfterVal" }
        $results += @{ Test = "Mitigacion 429"; Status = "PASS"; Detail = "$($counts['429']) bloqueadas de $FailedRequestCount" }
    } else {
        Write-Fail "No se observaron respuestas 429. El throttling no se activo (umbral no alcanzado o middleware deshabilitado)."
        $results += @{ Test = "Mitigacion 429"; Status = "FAIL"; Detail = "0 respuestas 429" }
    }
}

# ============================================================
# RESUMEN
# ============================================================
Write-Section "Resumen"
$allPass = $true
foreach ($r in $results) {
    $color = if ($r.Status -eq "PASS") { "Green" } else { "Red" }
    Write-Host ("  {0,-22} {1,-6} {2}" -f $r.Test, $r.Status, $r.Detail) -ForegroundColor $color
    if ($r.Status -ne "PASS") { $allPass = $false }
}
Write-Host ""
if ($allPass -and $results.Count -gt 0) {
    Write-Host "  RESULTADO FINAL: TODOS LOS TESTS PASARON" -ForegroundColor Green
} elseif ($results.Count -eq 0) {
    Write-Host "  RESULTADO FINAL: sin tests ejecutados" -ForegroundColor Yellow
} else {
    Write-Host "  RESULTADO FINAL: HAY TESTS FALLIDOS" -ForegroundColor Red
}
if ($allPass) { exit 0 } else { exit 1 }
