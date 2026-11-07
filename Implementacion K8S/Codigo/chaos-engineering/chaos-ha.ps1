<#
.SYNOPSIS
    Script unico de caos para PharmaGo: 6 escenarios en un solo archivo.

.DESCRIPTION
    Ejecuta (o simula con -DryRun) los escenarios de la rubrica:
      1. request    : inyeccion de requests (trafico valido + 4xx + 429)
      2. cpu        : sobrecarga de CPU en un pod
      3. memory     : sobrecarga de memoria en un pod
      4. storage    : llenado de disco efimero
      5. network    : interrupcion de trafico (tc netem o NetworkPolicy)
      6. disconnect : desconexion de un componente interno (scale o Service selector)
      7. gametime   : Game Day - trafico constante de requests (-Rate req/s, 20 por
                      defecto) mientras se disparan eventos de caos aleatorios:
                      cpu-spike, memory-spike, kill-pod, scale-zero, db-disconnect,
                      disk-fill, blackout (netem loss), latency-spike (netem delay
                      2000ms) y throttle-burst (ola de 429).

    Es autocontenido: incluye el generador de trafico HTTP (antes
    traffic-generator.ps1, ahora Invoke-TrafficLoad) y los helpers de kubectl y
    Prometheus (antes lib/). Cada escenario captura baseline/impacto en
    Prometheus y kubectl, deja un reporte en reports/ y devuelve PASS/FAIL.
    El exit code es 1 si algo falla.

.EXAMPLE
    .\chaos-ha.ps1 -Scenario all -Force

.EXAMPLE
    .\chaos-ha.ps1 -Scenario cpu -Target pharmago-api-gateway -Intensity high -DurationSec 30 -Force

.EXAMPLE
    .\chaos-ha.ps1 -Scenario request -LoadTotalRequests 300 -LoadConcurrency 20 -LoadDurationSec 300 -SkipRateLimitTest -Force

.EXAMPLE
    .\chaos-ha.ps1 -Scenario network -Target pharmago-api-gateway -NetworkMode tc -DurationSec 30 -Force

.EXAMPLE
    .\chaos-ha.ps1 -Scenario disconnect -Target pharmago-db -DisconnectMode service -DurationSec 30 -Force

.EXAMPLE
    .\chaos-ha.ps1 -Scenario gametime -GameTimeSec 300 -Rate 20 -Force
#>

[CmdletBinding()]
param(
    [ValidateSet("all", "request", "cpu", "memory", "storage", "network", "disconnect", "gametime")]
    [string]$Scenario = "all",

    [string]$Namespace = "pharmago",
    [string]$Target = "pharmago-api-gateway",
    [int]$DurationSec = 60,
    [ValidateSet("low", "medium", "high")]
    [string]$Intensity = "medium",

    [int]$SizeMB = 0,
    [ValidateSet("tc", "netpol")]
    [string]$NetworkMode = "tc",
    [ValidateSet("scale", "service")]
    [string]$DisconnectMode = "scale",

    [string]$BaseUrl = "http://127.0.0.1:5000",
    [string]$UsersServiceUrl = "http://127.0.0.1:5001",
    [string]$PrometheusUrl = "http://127.0.0.1:9090",
    [string]$ReportRoot = "",

    # Parametros de carga HTTP (escenario request): generador integrado.
    [int]$LoadTotalRequests = 0,
    [int]$LoadConcurrency = 15,
    [int]$LoadNormalDelayMs = 0,
    [int]$LoadDurationSec = 0,
    [switch]$SkipRateLimitTest,

    # Parametros del Game Day (escenario gametime): trafico constante + eventos de caos aleatorios
    [int]$GameTimeSec = 600,
    [int]$Rate = 20,
    [string]$ChaosTarget = "pharmago-users-service",

    [switch]$Force,
    [switch]$DryRun,
    [switch]$SkipPreflight
)

$ErrorActionPreference = "Stop"

if (-not $ReportRoot) { $ReportRoot = Join-Path $PSScriptRoot "reports" }
if ($DurationSec -lt 5) { $DurationSec = 5 }
if ($DurationSec -gt 300) { $DurationSec = 300 }
if ($GameTimeSec -lt 120) { $GameTimeSec = 120 }
if ($GameTimeSec -gt 1800) { $GameTimeSec = 1800 }
if ($Rate -lt 5) { $Rate = 5 }
if ($Rate -gt 200) { $Rate = 200 }
if (-not $ChaosTarget) { $ChaosTarget = "pharmago-users-service" }

# ============================================================
# Helpers de consola / kubectl (antes lib/common.ps1)
# ============================================================
function Write-Section([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text)      { Write-Host "  [PASS] $Text" -ForegroundColor Green }
function Write-Fail([string]$Text)    { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text)    { Write-Host "  $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text)    { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Falta el comando '$Name' en PATH."
    }
}

function Test-Url {
    param([string]$Url, [int]$TimeoutSec = 5)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutSec
        return [pscustomobject]@{ Ok = $true; StatusCode = [int]$resp.StatusCode; Error = $null }
    } catch {
        $status = 0
        try { if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } } catch { }
        return [pscustomobject]@{ Ok = $false; StatusCode = $status; Error = $_.Exception.Message }
    }
}

function Get-TargetPods {
    param([string]$Namespace, [string]$Deployment)
    $pods = @((kubectl get pods -n $Namespace -l "app=$Deployment" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>$null | Out-String).Trim() -split '\s+' | Where-Object { $_ })
    if ($pods.Count -eq 0) {
        throw "No hay pods Running para '$Deployment' en el namespace '$Namespace'."
    }
    return $pods
}

function Wait-DeploymentReady {
    param([string]$Namespace, [string]$Deployment, [int]$TimeoutSec = 120)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = kubectl rollout status "deployment/$Deployment" -n $Namespace --timeout="${TimeoutSec}s" 2>&1
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Warn "rollout status de $Deployment no llego a READY en ${TimeoutSec}s: $out"
    return $false
}

function Get-IntensityWorkers {
    param([string]$Intensity)
    switch ($Intensity) {
        "low"    { return 2 }
        "high"   { return 8 }
        default  { return 4 }
    }
}

function Get-IntensityMemoryMB {
    param([string]$Intensity)
    switch ($Intensity) {
        "low"    { return 256 }
        "high"   { return 512 }
        default  { return 384 }
    }
}

function Get-IntensityStorageMB {
    param([string]$Intensity)
    switch ($Intensity) {
        "low"    { return 200 }
        "high"   { return 1024 }
        default  { return 500 }
    }
}

function New-ReportDir {
    param([string]$Root, [string]$Scenario)
    $dir = Join-Path $Root $Scenario
    foreach ($sub in @("http", "prometheus", "kubectl", "manifests")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null
    }
    return $dir
}

function Save-KubectlSnapshot {
    param(
        [string]$Namespace,
        [string]$ReportDir,
        [string]$Tag,
        [string]$Pod = ""
    )
    $kubectlDir = Join-Path $ReportDir "kubectl"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        kubectl get pods -n $Namespace -o wide 2>&1 | Out-String |
            Set-Content -Path (Join-Path $kubectlDir "pods-$Tag.txt") -Encoding utf8
        kubectl top pods -n $Namespace 2>&1 | Out-String |
            Set-Content -Path (Join-Path $kubectlDir "top-$Tag.txt") -Encoding utf8
        kubectl get events -n $Namespace --sort-by=.lastTimestamp 2>&1 |
            Select-Object -Last 120 | Out-String |
            Set-Content -Path (Join-Path $kubectlDir "events-$Tag.txt") -Encoding utf8
        if ($Pod) {
            kubectl describe pod $Pod -n $Namespace 2>&1 | Out-String |
                Set-Content -Path (Join-Path $kubectlDir "describe-$Tag.txt") -Encoding utf8
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Get-JobName {
    param([string]$Target)
    switch ($Target) {
        "pharmago-api-gateway"      { return "api-gateway" }
        "pharmago-users-service"    { return "users-service" }
        "pharmago-pharmacy-service" { return "pharmacy-service" }
        default                     { return $Target }
    }
}

# ============================================================
# Helpers de Prometheus (antes lib/prometheus.ps1)
# ============================================================
function Invoke-PromQuery {
    param([string]$BaseUrl, [string]$Query)
    try {
        $encoded = [uri]::EscapeDataString($Query)
        $resp = Invoke-RestMethod -Uri "$BaseUrl/api/v1/query?query=$encoded" -TimeoutSec 10
        if ($resp.status -eq "success") { return @($resp.data.result) }
        return @()
    } catch {
        return @()
    }
}

function Invoke-PromRange {
    param(
        [string]$BaseUrl,
        [string]$Query,
        [long]$Start,
        [long]$End,
        [string]$Step = "15s"
    )
    try {
        $encoded = [uri]::EscapeDataString($Query)
        $uri = "$BaseUrl/api/v1/query_range?query=$encoded&start=$Start&end=$End&step=$Step"
        $resp = Invoke-RestMethod -Uri $uri -TimeoutSec 15
        if ($resp.status -eq "success") { return @($resp.data.result) }
        return @()
    } catch {
        return @()
    }
}

function Get-PromScalar {
    param($Result)
    if ($Result -and $Result.Count -gt 0 -and $Result[0].value) {
        return [double]$Result[0].value[1]
    }
    return $null
}

function Get-PromRangeMax {
    param([string]$BaseUrl, [string]$Query, [long]$Start, [long]$End, [string]$Step = "15s")
    $result = Invoke-PromRange -BaseUrl $BaseUrl -Query $Query -Start $Start -End $End -Step $Step
    $values = @()
    foreach ($series in $result) {
        foreach ($point in $series.values) { $values += [double]$point[1] }
    }
    if ($values.Count -eq 0) { return $null }
    return ($values | Measure-Object -Maximum).Maximum
}

function Get-PromRangeMin {
    param([string]$BaseUrl, [string]$Query, [long]$Start, [long]$End, [string]$Step = "15s")
    $result = Invoke-PromRange -BaseUrl $BaseUrl -Query $Query -Start $Start -End $End -Step $Step
    $values = @()
    foreach ($series in $result) {
        foreach ($point in $series.values) { $values += [double]$point[1] }
    }
    if ($values.Count -eq 0) { return $null }
    return ($values | Measure-Object -Minimum).Minimum
}

function Save-PromSnapshot {
    param(
        [string]$BaseUrl,
        [string]$Namespace,
        [string]$Target,
        [string]$JobName,
        [string]$ReportDir,
        [string]$Tag
    )
    $queries = [ordered]@{
        cpu_cores          = "sum(rate(container_cpu_usage_seconds_total{namespace=`"$Namespace`",pod=~`"$Target.*`",container!=`"POD`"}[1m]))"
        memory_bytes       = "sum(container_memory_working_set_bytes{namespace=`"$Namespace`",pod=~`"$Target.*`",container!=`"POD`"})"
        network_rx_bps     = "sum(rate(container_network_receive_bytes_total{namespace=`"$Namespace`",pod=~`"$Target.*`"}[1m]))"
        http_5xx_rate      = "sum(rate(pharmago_http_requests_total{status_code=~`"5..`"}[1m]))"
        http_requests_rate = "sum(rate(pharmago_http_requests_total[1m]))"
        up_target          = "up{job=`"$JobName`"}"
        node_fs_avail      = "node_filesystem_avail_bytes{mountpoint=`"/`"}"
    }

    $snapshot = [ordered]@{
        timestamp = (Get-Date).ToString("o")
        target    = $Target
        job       = $JobName
        queries   = [ordered]@{}
    }
    foreach ($key in $queries.Keys) {
        $snapshot.queries[$key] = [ordered]@{
            query  = $queries[$key]
            result = @(Invoke-PromQuery -BaseUrl $BaseUrl -Query $queries[$key])
        }
    }
    $path = Join-Path $ReportDir "prometheus\$Tag.json"
    $snapshot | ConvertTo-Json -Depth 12 | Set-Content -Path $path -Encoding utf8
    return $snapshot
}

function Get-SnapshotScalar {
    param($Snapshot, [string]$Key)
    if (-not $Snapshot -or -not $Snapshot.queries.Contains($Key)) { return $null }
    return Get-PromScalar $Snapshot.queries[$Key].result
}

# ============================================================
# Generador de trafico HTTP (antes traffic-generator.ps1)
# ============================================================
function Invoke-TrafficLoad {
    <#
    .SYNOPSIS
        Genera trafico HTTP mixto (200 y 4XX) contra Users y Pharmacy a traves del API Gateway.
    .DESCRIPTION
        Crea una cola de peticiones ponderada que mezcla endpoints publicos y protegidos,
        validos e invalidos, para producir codigos 200, 400, 401, 404 y 429 (rate limit).
        Usa las credenciales sembradas para obtener tokens JWT de sesion y ejercitar
        endpoints protegidos. Ejecuta con un pool de runspaces para generar carga concurrente.
    #>
    [CmdletBinding()]
    param(
        [string]$BaseUrl = "http://127.0.0.1:5000",
        [string]$UsersServiceUrl = "http://127.0.0.1:5001",
        [int]$TotalRequests = 200,
        [int]$Concurrency = 20,
        [int]$SuccessPercent = 60,
        [int]$ClientErrorPercent = 20,
        [int]$NormalDelayMs = 0,
        [string]$OutputCsv = "",
        [switch]$IncludeRateLimitTest,
        [int]$DurationSec = 0
    )

    Write-Host "=== PharmaGo Traffic Load (integrado en chaos-ha.ps1) ===" -ForegroundColor Cyan
    Write-Host "BaseUrl        : $BaseUrl"
    Write-Host "TotalRequests  : $TotalRequests"
    Write-Host "Concurrency    : $Concurrency"
    Write-Host "OutputCsv      : $OutputCsv"
    Write-Host ""

    # ---------------------------------------------------------------------------
    # 1. Obtener tokens de sesion con las credenciales sembradas
    # ---------------------------------------------------------------------------
    function Get-AuthToken {
        param([string]$UserName, [string]$Password)
        # Intentar primero contra el servicio directo de Users (evita el rate limit del gateway).
        foreach ($url in @($UsersServiceUrl, $BaseUrl)) {
            try {
                $body = @{ UserName = $UserName; Password = $Password } | ConvertTo-Json
                $resp = Invoke-RestMethod -Uri "$url/api/login" -Method Post -Body $body -ContentType "application/json" -TimeoutSec 30
                Write-Host "Login OK: $UserName -> token $($resp.token) (via $url)" -ForegroundColor Green
                return [string]$resp.token
            } catch {
                Write-Warning "Login fallo para $UserName via ${url}: $($_.Exception.Message)"
            }
        }
        return "invalid-token"
    }

    $adminToken = Get-AuthToken -UserName "admin" -Password "Abcdef12."
    $empToken   = Get-AuthToken -UserName "empleado01" -Password "Abcdef12."
    $ownerToken = Get-AuthToken -UserName "owner001" -Password "Abcdef12."

    # ---------------------------------------------------------------------------
    # 2. Escenarios por categoria (200, 4XX sin 429, 429)
    # ---------------------------------------------------------------------------
    $successScenarios = @(
        @{ Method = "GET";  Path = "/api/roles" },
        @{ Method = "GET";  Path = "/api/roles/test" },
        @{ Method = "GET";  Path = "/api/roles/ping" },
        @{ Method = "POST"; Path = "/api/login"; Body = '{"UserName":"admin","Password":"Abcdef12."}' },
        @{ Method = "GET";  Path = "/api/invitations"; Headers = @{ Authorization = $adminToken } },
        @{ Method = "GET";  Path = "/api/invitations/1"; Headers = @{ Authorization = $adminToken } },
        @{ Method = "GET";  Path = "/api/drug" },
        @{ Method = "GET";  Path = "/api/drug/1" },
        @{ Method = "GET";  Path = "/api/drug/User"; Headers = @{ Authorization = $empToken } },
        @{ Method = "GET";  Path = "/api/pharmacy" },
        @{ Method = "GET";  Path = "/api/pharmacy/1"; Headers = @{ Authorization = $adminToken } },
        @{ Method = "GET";  Path = "/api/purchases"; Headers = @{ Authorization = $empToken } }
    )

    $clientErrorScenarios = @(
        @{ Method = "POST"; Path = "/api/login"; Body = '{"UserName":"admin","Password":"wrongpassword"}' },
        @{ Method = "POST"; Path = "/api/users"; Body = '{"UserName":"","UserCode":"123","Email":"bad","Password":"weak","Address":"","RegistrationDate":"2026-01-01T00:00:00"}' },
        @{ Method = "GET";  Path = "/api/drug/9999" },
        @{ Method = "GET";  Path = "/api/drug/abc" },
        @{ Method = "GET";  Path = "/api/invitations" },
        @{ Method = "GET";  Path = "/api/pharmacy/1" },
        @{ Method = "GET";  Path = "/api/drug/User" },
        @{ Method = "GET";  Path = "/api/purchases" },
        @{ Method = "GET";  Path = "/api/export/exporters" },
        @{ Method = "POST"; Path = "/api/purchases"; Body = '{}' },
        @{ Method = "GET";  Path = "/api/presentations" }
    )

    $rateLimitScenarios = @(
        @{ Method = "GET"; Path = "/api/roles" }
    )

    # ---------------------------------------------------------------------------
    # 3. Bucle de carga sostenida (si -DurationSec > 0) o ejecucion unica
    # ---------------------------------------------------------------------------
    $allResults = New-Object System.Collections.ArrayList
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $iteration = 0

    do {
        $iteration++
        if ($DurationSec -gt 0) {
            Write-Host "`n===== Iteracion $iteration (elapsed $([int]$sw.Elapsed.TotalSeconds)s / ${DurationSec}s) =====" -ForegroundColor Magenta
        }

        $successCount = [int]($TotalRequests * $SuccessPercent / 100)
        $clientCount  = [int]($TotalRequests * $ClientErrorPercent / 100)

        # Bloque de rate-limit (429) solo si se solicita explicitamente. Sin el bloque
        # se genera carga sostenida con mayoria de respuestas 2xx/4xx.
        $rateCount = 0
        if ($IncludeRateLimitTest) {
            $rateCount = [math]::Max(202, $TotalRequests - $successCount - $clientCount)
            if ($rateCount -lt 202) { $rateCount = 202 }
        }

        $queue = New-Object System.Collections.ArrayList

        for ($i = 0; $i -lt $successCount; $i++) {
            $s = $successScenarios | Get-Random
            $item = $s.Clone()
            $item.DelayMs = $NormalDelayMs
            if (-not $item.Headers) { $item.Headers = @{} }
            # IP rotativa para no disparar el rate limit por IP ni el throttling de fallas
            $item.Headers["X-Real-IP"] = "10.0.0.$(Get-Random -Minimum 1 -Maximum 254)"
            [void]$queue.Add($item)
        }
        for ($i = 0; $i -lt $clientCount; $i++) {
            $s = $clientErrorScenarios | Get-Random
            $item = $s.Clone()
            $item.DelayMs = $NormalDelayMs
            if (-not $item.Headers) { $item.Headers = @{} }
            $item.Headers["X-Real-IP"] = "10.0.0.$(Get-Random -Minimum 1 -Maximum 254)"
            [void]$queue.Add($item)
        }
        if ($IncludeRateLimitTest) {
            for ($i = 0; $i -lt $rateCount; $i++) {
                $s = $rateLimitScenarios | Get-Random
                $item = $s.Clone()
                $item.DelayMs = 0
                # Una sola IP para disparar el rate limit (100 req/min por IP)
                $item.Headers = @{ "X-Real-IP" = "10.99.99.99" }
                [void]$queue.Add($item)
            }
        }

        # Mezclar para no enviar todos los 429 juntos
        $queue = $queue | Sort-Object { Get-Random }

        $totalReal = $successCount + $clientCount + $rateCount
        Write-Host "Cola generada: $totalReal peticiones" -ForegroundColor Yellow
        Write-Host "  200/4XX (mixtas)  : $($successCount + $clientCount)" -ForegroundColor Green
        if ($IncludeRateLimitTest) {
            Write-Host "  429 (rate limit)   : $rateCount" -ForegroundColor Yellow
        }
        Write-Host ""
        if (-not $IncludeRateLimitTest) {
            Write-Host "Nota: modo carga (sin bloque 429)." -ForegroundColor Gray
        } else {
            Write-Host "Nota: el bloque 429 usa una sola IP (10.99.99.99) para disparar el rate limit." -ForegroundColor Gray
        }
        Write-Host ""

        # -----------------------------------------------------------------------
        # 4. Scriptblock ejecutado en cada runspace
        # -----------------------------------------------------------------------
        $requestScript = {
            param($BaseUrl, $Method, $Path, $Body, $Headers)

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $statusCode = 0
            $errorText = ""
            try {
                $params = @{
                    Uri             = "$BaseUrl$Path"
                    Method          = $Method
                    UseBasicParsing = $true
                    TimeoutSec      = 30
                }
                if ($Body) {
                    $params.Body        = $Body
                    $params.ContentType = "application/json"
                }
                if ($Headers) {
                    $params.Headers = $Headers
                }
                $resp = Invoke-WebRequest @params
                $statusCode = [int]$resp.StatusCode
            } catch {
                if ($_.Exception.Response) {
                    try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = 0 }
                } else {
                    $statusCode = 0
                }
                $errorText = $_.Exception.Message
            }
            $sw.Stop()

            [pscustomobject]@{
                Method     = $Method
                Path       = $Path
                StatusCode = $statusCode
                ElapsedMs  = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                Error      = $errorText
            }
        }

        # -----------------------------------------------------------------------
        # 5. Ejecutar con pool de runspaces
        # -----------------------------------------------------------------------
        $pool = [runspacefactory]::CreateRunspacePool(1, $Concurrency)
        $pool.Open()

        $asyncResults = New-Object System.Collections.ArrayList
        foreach ($req in $queue) {
            if ($req.DelayMs -gt 0) { Start-Sleep -Milliseconds $req.DelayMs }
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($requestScript)
            [void]$ps.AddArgument($BaseUrl)
            [void]$ps.AddArgument($req.Method)
            [void]$ps.AddArgument($req.Path)
            [void]$ps.AddArgument($req.Body)
            [void]$ps.AddArgument($req.Headers)
            $handle = $ps.BeginInvoke()
            [void]$asyncResults.Add(@{ PS = $ps; Handle = $handle })
        }

        Write-Host "Ejecutando $($asyncResults.Count) peticiones con concurrencia $Concurrency..." -ForegroundColor Yellow

        $results = New-Object System.Collections.ArrayList
        $completed = 0
        while ($asyncResults.Count -gt 0) {
            $stillRunning = New-Object System.Collections.ArrayList
            foreach ($ar in $asyncResults) {
                if ($ar.Handle.IsCompleted) {
                    $output = $ar.PS.EndInvoke($ar.Handle)
                    foreach ($o in $output) {
                        [void]$results.Add($o)
                    }
                    $ar.PS.Dispose()
                    $completed++
                    if ($completed % 25 -eq 0 -or $completed -eq $queue.Count) {
                        Write-Host "  Completadas: $completed / $($queue.Count)" -ForegroundColor Gray
                    }
                } else {
                    [void]$stillRunning.Add($ar)
                }
            }
            $asyncResults = $stillRunning
            if ($asyncResults.Count -gt 0) {
                Start-Sleep -Milliseconds 100
            }
        }

        $pool.Close()
        $pool.Dispose()

        # Acumular resultados de esta iteracion
        foreach ($r in $results) { [void]$allResults.Add($r) }

        if ($DurationSec -gt 0) {
            $remaining = $DurationSec - $sw.Elapsed.TotalSeconds
            if ($remaining -le 0) { break }
            Write-Host "  Iteracion $iteration completada. Descanso 2s antes de la siguiente..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 2
        }
    } while ($DurationSec -gt 0 -and $sw.Elapsed.TotalSeconds -lt $DurationSec)

    $results = $allResults

    # ---------------------------------------------------------------------------
    # 6. Resumen y exportacion
    # ---------------------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Resumen por codigo de estado ===" -ForegroundColor Cyan
    $results | Group-Object StatusCode | Sort-Object Name | ForEach-Object {
        $color = if ($_.Name -eq "200") { "Green" } elseif ($_.Name -eq "0") { "Red" } else { "Yellow" }
        Write-Host ("  {0,4} : {1,5} peticiones" -f $_.Name, $_.Count) -ForegroundColor $color
    }

    $total = $results.Count
    $ok200 = ($results | Where-Object { $_.StatusCode -eq 200 }).Count
    $err4xx = ($results | Where-Object { $_.StatusCode -ge 400 -and $_.StatusCode -lt 500 }).Count
    $err5xx = ($results | Where-Object { $_.StatusCode -ge 500 }).Count
    $netErr = ($results | Where-Object { $_.StatusCode -eq 0 }).Count
    $avgMs  = [math]::Round(($results | Measure-Object -Property ElapsedMs -Average).Average, 2)

    Write-Host ""
    Write-Host "Total     : $total"
    Write-Host "200 OK    : $ok200  ($([math]::Round($ok200/$total*100,1))%)" -ForegroundColor Green
    Write-Host "4XX       : $err4xx  ($([math]::Round($err4xx/$total*100,1))%)" -ForegroundColor Yellow
    Write-Host "5XX       : $err5xx"
    Write-Host "Errores red: $netErr"
    Write-Host "Latencia media: $avgMs ms"

    Write-Host ""
    Write-Host "=== Resumen por endpoint ===" -ForegroundColor Cyan
    $results | Group-Object Method, Path | Sort-Object Count -Descending | ForEach-Object {
        $codes = ($_.Group | Group-Object StatusCode | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ", "
        Write-Host ("  {0,-6} {1,-32} {2,5}  [{3}]" -f $_.Group[0].Method, $_.Group[0].Path, $_.Count, $codes)
    }

    # Exportar CSV (opcional; sin OutputCsv solo hay log en consola)
    if (-not [string]::IsNullOrWhiteSpace($OutputCsv)) {
        $results | Select-Object Method, Path, StatusCode, ElapsedMs, Error |
            Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
        Write-Host ""
        Write-Host "Detalle exportado a: $OutputCsv" -ForegroundColor Green
    }
}

# ============================================================
# Game Day (escenario gametime): trafico constante + eventos de caos aleatorios
# ============================================================
# Request minima ejecutada en un runspace del pool. Ts = timestamp de lanzamiento
# (permite medir la tasa de envio aunque la respuesta tarde).
$GameTimeReqScript = {
    param($ReqBaseUrl, $ReqMethod, $ReqPath, $ReqBody, $ReqHeaders, $ReqTs)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 0
    $errText = ""
    try {
        $params = @{ Uri = "$ReqBaseUrl$ReqPath"; Method = $ReqMethod; UseBasicParsing = $true; TimeoutSec = 15 }
        if ($ReqBody) { $params.Body = $ReqBody; $params.ContentType = "application/json" }
        if ($ReqHeaders) { $params.Headers = $ReqHeaders }
        $resp = Invoke-WebRequest @params
        $status = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        }
        $errText = $_.Exception.Message
    }
    $sw.Stop()

    [pscustomobject]@{
        Ts         = $ReqTs
        Method     = $ReqMethod
        Path       = $ReqPath
        StatusCode = $status
        ElapsedMs  = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        Error      = $errText
    }
}

# Pacer de trafico: lanza 1 request cada IntervalMs desde su propio runspace y no
# se bloquea por lentos (pool de 8 runspaces absorbe las colas de timeout).
$GameTimePacerScript = {
    param($PacerBaseUrl, $IntervalMs, $Queue)

    $pool = [runspacefactory]::CreateRunspacePool(1, 8)
    $pool.Open()

    $req = {
        param($ReqBaseUrl, $ReqMethod, $ReqPath, $ReqBody, $ReqHeaders, $ReqTs)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $status = 0
        $errText = ""
        try {
            $params = @{ Uri = "$ReqBaseUrl$ReqPath"; Method = $ReqMethod; UseBasicParsing = $true; TimeoutSec = 15 }
            if ($ReqBody) { $params.Body = $ReqBody; $params.ContentType = "application/json" }
            if ($ReqHeaders) { $params.Headers = $ReqHeaders }
            $resp = Invoke-WebRequest @params
            $status = [int]$resp.StatusCode
        } catch {
            if ($_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
            }
            $errText = $_.Exception.Message
        }
        $sw.Stop()
        [pscustomobject]@{
            Ts         = $ReqTs
            Method     = $ReqMethod
            Path       = $ReqPath
            StatusCode = $status
            ElapsedMs  = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            Error      = $errText
        }
    }

    $paths = @(
        @{ Method = "GET";  Path = "/api/roles" },
        @{ Method = "GET";  Path = "/api/roles/ping" },
        @{ Method = "GET";  Path = "/api/drug" },
        @{ Method = "GET";  Path = "/api/pharmacy" },
        @{ Method = "GET";  Path = "/api/drug/1" },
        @{ Method = "POST"; Path = "/api/login"; Body = '{"UserName":"admin","Password":"wrongpassword"}' }
    )

    $pending = New-Object System.Collections.ArrayList
    while ($true) {
        # Recolectar respuestas terminadas y encolarlas
        for ($i = 0; $i -lt $pending.Count; $i++) {
            if ($pending[$i].Handle.IsCompleted) {
                try {
                    $out = $pending[$i].PS.EndInvoke($pending[$i].Handle)
                    foreach ($o in $out) { $Queue.Enqueue($o) }
                } catch { }
                $pending[$i].PS.Dispose()
                $pending.RemoveAt($i)
                $i--
            }
        }
        # Lanzar el siguiente request (tasa constante)
        $p = $paths[(Get-Random -Minimum 0 -Maximum $paths.Count)]
        $headers = @{ "X-Real-IP" = ("10.0." + (Get-Random -Minimum 1 -Maximum 254) + "." + (Get-Random -Minimum 1 -Maximum 254)) }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($req)
        [void]$ps.AddArgument($PacerBaseUrl)
        [void]$ps.AddArgument($p.Method)
        [void]$ps.AddArgument($p.Path)
        [void]$ps.AddArgument($p.Body)
        [void]$ps.AddArgument($headers)
        [void]$ps.AddArgument((Get-Date).ToString("o"))
        $pending.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
        Start-Sleep -Milliseconds $IntervalMs
    }
}

function Get-GameTimeStats {
    param($Records)
    $recs = @($Records)
    if ($recs.Count -eq 0) {
        return [pscustomobject]@{ Total = 0; Ok2xx = 0; Err4xx = 0; Err5xx = 0; NetErr = 0; P429 = 0; AvgMs = 0.0; P95Ms = 0.0 }
    }
    $codes = @($recs | ForEach-Object { [int]$_.StatusCode })
    $lat = @($recs | ForEach-Object { [double]$_.ElapsedMs } | Sort-Object)
    $p95 = 0.0
    if ($lat.Count -gt 0) { $p95 = $lat[[Math]::Min($lat.Count - 1, [int][Math]::Floor($lat.Count * 0.95))] }
    return [pscustomobject]@{
        Total  = $recs.Count
        Ok2xx  = @($codes | Where-Object { $_ -ge 200 -and $_ -lt 300 }).Count
        Err4xx = @($codes | Where-Object { $_ -ge 400 -and $_ -lt 500 }).Count
        Err5xx = @($codes | Where-Object { $_ -ge 500 }).Count
        NetErr = @($codes | Where-Object { $_ -eq 0 }).Count
        P429   = @($codes | Where-Object { $_ -eq 429 }).Count
        AvgMs  = [math]::Round(($lat | Measure-Object -Average).Average, 0)
        P95Ms  = [math]::Round($p95, 0)
    }
}

function Invoke-GtCpuSpike {
    $pods = Get-TargetPods -Namespace $Namespace -Deployment $ChaosTarget
    $workers = Get-IntensityWorkers $Intensity
    $remote = @'
i=0
while [ $i -lt {0} ]; do
  (end=$(( $(date +%s) + {1} )); while [ $(date +%s) -lt $end ]; do :; done) &
  i=$((i+1))
done
wait
'@ -f $workers, 45

    $jobs = @()
    foreach ($pod in $pods) {
        Write-Info "CPU spike en ${pod}: $workers worker(s) x 45s"
        $jobs += Start-Job -ScriptBlock { param($Ns, $Pod, $Script) & kubectl exec -n $Ns $Pod -- sh -c $Script 2>&1 } -ArgumentList $Namespace, $pod, $remote
    }
    $null = Wait-Job -Job $jobs -Timeout 105
    $jobs | Where-Object { $_.State -eq "Running" } | Stop-Job
    foreach ($j in $jobs) {
        Receive-Job $j | Out-Host
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    return "cpu-spike: $workers workers x $($pods.Count) pods x 45s"
}

function Invoke-GtMemorySpike {
    $pods = Get-TargetPods -Namespace $Namespace -Deployment $ChaosTarget
    $mb = Get-IntensityMemoryMB $Intensity
    $remote = @'
v=$(dd if=/dev/zero bs=1M count={0} 2>/dev/null | tr '\0' 'x')
echo "allocated_bytes={2}"
sleep {1}
'@ -f $mb, 30, '${#v}'

    $jobs = @()
    foreach ($pod in $pods) {
        Write-Info "Memory spike en ${pod}: ${mb}MB x 30s"
        $jobs += Start-Job -ScriptBlock { param($Ns, $Pod, $Script) & kubectl exec -n $Ns $Pod -- sh -c $Script 2>&1 } -ArgumentList $Namespace, $pod, $remote
    }
    $null = Wait-Job -Job $jobs -Timeout 90
    $jobs | Where-Object { $_.State -eq "Running" } | Stop-Job
    foreach ($j in $jobs) {
        Receive-Job $j | Out-Host
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 5
    $null = Wait-DeploymentReady -Namespace $Namespace -Deployment $ChaosTarget -TimeoutSec 90
    $oomHint = if ($mb -ge 384) { " (posible OOMKill: ${mb}MB vs limite 384Mi)" } else { "" }
    return "memory-spike: ${mb}MB x $($pods.Count) pods x 30s$oomHint"
}

function Invoke-GtKillPod {
    $pods = Get-TargetPods -Namespace $Namespace -Deployment $ChaosTarget
    $victim = $pods[(Get-Random -Minimum 0 -Maximum $pods.Count)]
    Write-Info "Eliminando pod $victim"
    kubectl delete pod $victim -n $Namespace --wait=false 2>&1 | Out-Host
    Start-Sleep -Seconds 5
    return "kill-pod: $victim eliminado (auto-curacion en marcha)"
}

function Invoke-GtScaleZero {
    $original = ([string](kubectl get deployment $ChaosTarget -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null | Out-String)).Trim()
    if ([string]::IsNullOrWhiteSpace($original) -or [int]$original -lt 1) { $original = "2" }
    Write-Info "Escalando $ChaosTarget a 0 replicas"
    kubectl scale deployment $ChaosTarget -n $Namespace --replicas=0 2>&1 | Out-Host
    Start-Sleep -Seconds 20
    Write-Info "Restaurando $ChaosTarget a $original replicas"
    kubectl scale deployment $ChaosTarget -n $Namespace --replicas=$original 2>&1 | Out-Host
    $null = Wait-DeploymentReady -Namespace $Namespace -Deployment $ChaosTarget -TimeoutSec 90
    return "scale-zero: $ChaosTarget sin replicas x 20s (original=$original)"
}

function Invoke-GtDbDisconnect {
    Write-Info "Desconectando el Service pharmago-db (selector a label inexistente)"
    $sel = ([string](kubectl get service pharmago-db -n $Namespace -o jsonpath='{.spec.selector}' 2>$null | Out-String)).Trim()
    if ([string]::IsNullOrWhiteSpace($sel)) { return "db-disconnect: no se pudo leer el selector del Service" }
    $patch = @{ spec = @{ selector = @{ app = "chaos-disconnected" } } } | ConvertTo-Json -Compress
    kubectl patch service pharmago-db -n $Namespace --type merge -p $patch 2>&1 | Out-Host
    Start-Sleep -Seconds 25
    Write-Info "Restaurando selector del Service pharmago-db"
    $restore = @{ spec = @{ selector = ($sel | ConvertFrom-Json) } } | ConvertTo-Json -Depth 5 -Compress
    kubectl patch service pharmago-db -n $Namespace --type merge -p $restore 2>&1 | Out-Host
    Start-Sleep -Seconds 5
    return "db-disconnect: Service de SQL Server aislado x 25s"
}

function Invoke-GtDiskFill {
    $pods = Get-TargetPods -Namespace $Namespace -Deployment $ChaosTarget
    $remote = @'
dd if=/dev/zero of=/tmp/gt_fill bs=1M count=300 2>/dev/null
sleep 20
rm -f /tmp/gt_fill
echo cleaned
'@
    $jobs = @()
    foreach ($pod in $pods) {
        Write-Info "Disk fill en ${pod}: 300MB x 20s"
        $jobs += Start-Job -ScriptBlock { param($Ns, $Pod, $Script) & kubectl exec -n $Ns $Pod -- sh -c $Script 2>&1 } -ArgumentList $Namespace, $pod, $remote
    }
    $null = Wait-Job -Job $jobs -Timeout 60
    $jobs | Where-Object { $_.State -eq "Running" } | Stop-Job
    foreach ($j in $jobs) {
        Receive-Job $j | Out-Null
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    return "disk-fill: 300MB en /tmp x $($pods.Count) pods x 20s"
}

function Invoke-GtNetem {
    param([ValidateSet("loss", "delay")][string]$Mode, [int]$Sec)

    $pods = Get-TargetPods -Namespace $Namespace -Deployment $ChaosTarget
    $arg = if ($Mode -eq "loss") { "loss 100%" } else { "delay 2000ms" }

    foreach ($pod in $pods) {
        $existing = ([string](kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.ephemeralContainers[*].name}' 2>$null | Out-String))
        if ($existing -notmatch "chaos-net") {
            Write-Info "Creando contenedor efimero chaos-net en $pod"
            kubectl debug -n $Namespace "pod/$pod" --profile=netadmin --image=nicolaka/netshoot --attach=false -c chaos-net -- sh -c "sleep $($Sec + 60)" 2>&1 | Out-Host
            $deadline = (Get-Date).AddSeconds(60)
            do {
                $readyAt = ([string](kubectl get pod $pod -n $Namespace -o jsonpath='{.status.ephemeralContainerStatuses[?(@.name=="chaos-net")].state.running.startedAt}' 2>$null))
                if (-not [string]::IsNullOrWhiteSpace($readyAt)) { break }
                Start-Sleep -Seconds 3
            } while ((Get-Date) -lt $deadline)
        }
        Write-Info "tc netem $arg en $pod"
        kubectl exec -n $Namespace $pod -c chaos-net -- tc qdisc add dev eth0 root netem $arg 2>&1 | Out-Host
    }

    Start-Sleep -Seconds $Sec

    foreach ($pod in $pods) {
        kubectl exec -n $Namespace $pod -c chaos-net -- tc qdisc del dev eth0 root 2>&1 | Out-Null
        kubectl delete pod $pod -n $Namespace --wait=false 2>&1 | Out-Null
    }
    $null = Wait-DeploymentReady -Namespace $Namespace -Deployment $ChaosTarget -TimeoutSec 120
    if ($Mode -eq "loss") { return "blackout: netem loss 100% x ${Sec}s x $($pods.Count) pods" }
    return "latency-spike: netem delay 2000ms x ${Sec}s x $($pods.Count) pods"
}

function Invoke-GtThrottleBurst {
    $count = 202
    $pool = [runspacefactory]::CreateRunspacePool(1, 16)
    $pool.Open()
    $pending = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $count; $i++) {
        $headers = @{ "X-Real-IP" = "10.99.99.99" }
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($GameTimeReqScript)
        [void]$ps.AddArgument($BaseUrl)
        [void]$ps.AddArgument("GET")
        [void]$ps.AddArgument("/api/roles")
        [void]$ps.AddArgument("")
        [void]$ps.AddArgument($headers)
        [void]$ps.AddArgument((Get-Date).ToString("o"))
        $pending.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })
    }
    $p429 = 0
    $deadline = (Get-Date).AddSeconds(90)
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        for ($i = 0; $i -lt $pending.Count; $i++) {
            if ($pending[$i].Handle.IsCompleted) {
                try {
                    $out = $pending[$i].PS.EndInvoke($pending[$i].Handle)
                    foreach ($o in $out) { if ([int]$o.StatusCode -eq 429) { $p429++ } }
                } catch { }
                $pending[$i].PS.Dispose()
                $pending.RemoveAt($i)
                $i--
            }
        }
        Start-Sleep -Milliseconds 100
    }
    $pool.Close()
    $pool.Dispose()
    return "throttle-burst: $count requests desde una IP -> $p429 respuestas 429"
}

function Invoke-GameTimeScenario {
    param([string]$ReportDir)

    $health = Test-Url "$BaseUrl/health"
    if (-not $health.Ok) {
        return [pscustomobject]@{
            Name    = "gametime"
            Passed  = $false
            Details = "API Gateway no responde en $BaseUrl/health. ¿Port-forward activo?"
        }
    }

    $intervalMs = [Math]::Max(20, [int](1000 / $Rate))
    $gameDir = Join-Path $ReportDir "gametime"
    foreach ($sub in @("traffic", "events", "kubectl", "prometheus")) {
        New-Item -ItemType Directory -Force -Path (Join-Path $gameDir $sub) | Out-Null
    }
    $csv = Join-Path $gameDir "traffic\traffic.csv"
    if (Test-Path $csv) { Remove-Item $csv -Force }

    # Vaciar la cola: persiste registros nuevos al CSV y los devuelve para stats.
    $drain = {
        $out = New-Object System.Collections.ArrayList
        $rec = $null
        while ($queue.TryDequeue([ref]$rec)) { [void]$out.Add($rec) }
        if ($out.Count -gt 0) { $out | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8 }
        return $out
    }

    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $pacer = [powershell]::Create()
    [void]$pacer.AddScript($GameTimePacerScript)
    [void]$pacer.AddArgument($BaseUrl)
    [void]$pacer.AddArgument($intervalMs)
    [void]$pacer.AddArgument($queue)
    $pacerHandle = $pacer.BeginInvoke()
    Write-Info "Pacer iniciado: $Rate req/s (intervalo ${intervalMs}ms) contra $BaseUrl"

    $eventNames = @("cpu-spike", "memory-spike", "kill-pod", "scale-zero", "db-disconnect", "disk-fill", "blackout", "latency-spike", "throttle-burst")
    $lastEvent = ""
    $eventRows = @()
    $eventNum = 0
    $gameStart = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $deadline = $gameStart + $GameTimeSec

    Write-Section "Game Day: $Rate req/s constantes + eventos de caos aleatorios"
    Write-Info "Duracion: ${GameTimeSec}s | ChaosTarget: $ChaosTarget | Intensidad: $Intensity"

    try {
        while ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt $deadline) {
            do { $name = $eventNames[(Get-Random -Minimum 0 -Maximum $eventNames.Count)] } while ($name -eq $lastEvent)
            $lastEvent = $name
            $eventNum++

            $null = & $drain
            Write-Section "Evento $eventNum - $name"
            $evDir = Join-Path $gameDir ("events\{0:D2}-{1}" -f $eventNum, $name)
            New-Item -ItemType Directory -Force -Path (Join-Path $evDir "kubectl") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $evDir "prometheus") | Out-Null

            $note = ""
            try {
                $note = switch ($name) {
                    "cpu-spike"      { Invoke-GtCpuSpike }
                    "memory-spike"   { Invoke-GtMemorySpike }
                    "kill-pod"       { Invoke-GtKillPod }
                    "scale-zero"     { Invoke-GtScaleZero }
                    "db-disconnect"  { Invoke-GtDbDisconnect }
                    "disk-fill"      { Invoke-GtDiskFill }
                    "blackout"       { Invoke-GtNetem -Mode loss -Sec 25 }
                    "latency-spike"  { Invoke-GtNetem -Mode delay -Sec 30 }
                    "throttle-burst" { Invoke-GtThrottleBurst }
                }
            } catch {
                $note = "ERROR: $($_.Exception.Message)"
            }

            $null = Save-PromSnapshot -BaseUrl $PrometheusUrl -Namespace $Namespace -Target $ChaosTarget -JobName (Get-JobName -Target $ChaosTarget) -ReportDir $evDir -Tag "impact"
            Save-KubectlSnapshot -Namespace $Namespace -ReportDir $evDir -Tag "impact" | Out-Null

            $records = & $drain
            $st = Get-GameTimeStats -Records $records
            $eventRows += [pscustomobject]@{
                N        = $eventNum
                Event    = $name
                Note     = $note
                Requests = $st.Total
                Ok2xx    = $st.Ok2xx
                Err4xx   = $st.Err4xx
                Err5xx   = $st.Err5xx
                NetErr   = $st.NetErr
                P429     = $st.P429
                P95Ms    = $st.P95Ms
                Dir      = $evDir
            }
            if ($st.Total -gt 0) {
                Write-Info "Impacto durante el evento: req=$($st.Total) ok=$($st.Ok2xx) 4xx=$($st.Err4xx) 5xx=$($st.Err5xx) netErr=$($st.NetErr) 429=$($st.P429) p95=$($st.P95Ms)ms"
            }

            # Descanso entre eventos: el trafico sigue, se drena cada 1s
            $gapSec = Get-Random -Minimum 10 -Maximum 26
            Write-Info "Descanso ${gapSec}s (el trafico sigue)"
            for ($i = 0; $i -lt $gapSec; $i++) {
                if ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $deadline) { break }
                Start-Sleep -Seconds 1
                $null = & $drain
            }
        }
    } catch {
        Write-Warn "Excepcion en el bucle de eventos: $($_.Exception.Message)"
    } finally {
        Write-Info "Deteniendo traffic pacer..."
        try { $pacer.Stop() } catch { }
        $pacer.Dispose()
        $null = & $drain

        # Restauraciones de emergencia (por si un evento quedo a mitad)
        try {
            $rep = ([string](kubectl get deployment $ChaosTarget -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null | Out-String)).Trim()
            if ($rep -eq "0") {
                Write-Warn "Restaurando $ChaosTarget a 2 replicas"
                kubectl scale deployment $ChaosTarget -n $Namespace --replicas=2 2>&1 | Out-Null
            }
            $selNow = ([string](kubectl get service pharmago-db -n $Namespace -o jsonpath='{.spec.selector.app}' 2>$null | Out-String)).Trim()
            if ($selNow -eq "chaos-disconnected") {
                Write-Warn "Restaurando selector del Service pharmago-db"
                $restore = @{ spec = @{ selector = @{ app = "pharmago-db" } } } | ConvertTo-Json -Compress
                kubectl patch service pharmago-db -n $Namespace --type merge -p $restore 2>&1 | Out-Null
            }
            $fill = Get-TargetPods -Namespace $Namespace -Deployment $ChaosTarget -ErrorAction SilentlyContinue
            foreach ($pod in @($fill)) {
                kubectl exec -n $Namespace $pod -- rm -f /tmp/gt_fill /tmp/chaos_fill 2>$null | Out-Null
            }
        } catch { }
        $null = Wait-DeploymentReady -Namespace $Namespace -Deployment $ChaosTarget -TimeoutSec 90
    }

    # --- Evaluacion final ---
    $rows = if (Test-Path $csv) { @(Import-Csv $csv) } else { @() }
    $total = $rows.Count
    $stats = Get-GameTimeStats -Records $rows

    $constancy = $null
    if ($total -gt 0) {
        $windows = @{}
        foreach ($r in $rows) {
            $bucket = [math]::Floor([DateTimeOffset]::Parse($r.Ts).ToUnixTimeSeconds() / 10)
            $windows[$bucket] = 1 + ($windows[$bucket] -as [int])
        }
        $expected = 10 * $Rate
        $inRange = @($windows.Values | Where-Object { $_ -ge [int]($expected * 0.8) -and $_ -le [int]($expected * 1.2) }).Count
        $constancy = $inRange / $windows.Count
    }

    $minEvents = [Math]::Max(3, [int][Math]::Floor($GameTimeSec / 60))
    $recovered = (Wait-DeploymentReady -Namespace $Namespace -Deployment $ChaosTarget -TimeoutSec 60) -and (Test-Url "$BaseUrl/health").Ok
    $impact = ($stats.Err5xx -gt 0) -or ($stats.NetErr -gt 0) -or ($stats.P429 -gt 0) -or ($stats.P95Ms -gt 1000)

    $passed = ($total -gt 0) -and ($null -ne $constancy -and $constancy -ge 0.9) -and ($eventNum -ge $minEvents) -and $impact -and $recovered

    # --- Reporte de detalle del game day ---
    $gtLines = @(
        "# Game Day report",
        "",
        "- Fecha: $((Get-Date).ToString('o'))",
        "- Duracion: ${GameTimeSec}s | Tasa objetivo: $Rate req/s | Intrvalo: ${intervalMs}ms",
        "- Requests totales: $total",
        "- Constantancia (ventanas 10s en 20% de $Rate*10): $(if ($null -ne $constancy) { '{0:P0}' -f $constancy } else { 'n/d' })",
        "- Totales: 2xx=$($stats.Ok2xx) 4xx=$($stats.Err4xx) 5xx=$($stats.Err5xx) netErr=$($stats.NetErr) 429=$($stats.P429)",
        "- Latencia: promedio=$($stats.AvgMs)ms p95=$($stats.P95Ms)ms",
        "- Eventos ejecutados: $eventNum (minimo requerido: $minEvents)",
        "- Recuperacion final: $recovered",
        "",
        "| # | Evento | Nota | Req | 2xx | 4xx | 5xx | NetErr | 429 | p95 ms |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|---:|"
    )
    foreach ($e in $eventRows) {
        $gtLines += "| $($e.N) | $($e.Event) | $($e.Note) | $($e.Requests) | $($e.Ok2xx) | $($e.Err4xx) | $($e.Err5xx) | $($e.NetErr) | $($e.P429) | $($e.P95Ms) |"
    }
    $gtLines += ""
    $gtLines += "CSV completo en traffic/traffic.csv; snapshots por evento en events/<n>-<evento>/."
    $gtSummary = Join-Path $gameDir "summary-gametime.md"
    $gtLines | Set-Content -Path $gtSummary -Encoding utf8
    Write-Info "Reporte del game day: $gtSummary"

    $constancyText = if ($null -ne $constancy) { "{0:P0}" -f $constancy } else { "n/d" }
    return [pscustomobject]@{
        Name    = "gametime"
        Passed  = $passed
        Details = "eventos=$eventNum/$minEvents requests=$total constancia=$constancyText 2xx=$($stats.Ok2xx) 5xx=$($stats.Err5xx) netErr=$($stats.NetErr) 429=$($stats.P429) p95=$($stats.P95Ms)ms recovered=$recovered"
    }
}

# ============================================================
# Preflight
# ============================================================
function Invoke-Preflight {
    Assert-Command "kubectl"
    $context = (& kubectl config current-context 2>$null | Out-String).Trim()
    Write-Info "Contexto kubectl: $context"
    if ($context -notmatch "minikube") {
        Write-Warn "El contexto no parece Minikube. Verifica que no sea un cluster real."
    }
    $null = kubectl get namespace $Namespace 2>&1
    if ($LASTEXITCODE -ne 0) { throw "No existe el namespace '$Namespace' o no hay acceso al cluster." }
    if ($Target -match "^(kube-system|default|kube-public)$") {
        throw "Target '$Target' no permitido por seguridad."
    }
    if ($Target -notmatch "^pharmago-") {
        Write-Warn "El target '$Target' no empieza con 'pharmago-'. Continuando bajo tu responsabilidad."
    }
    $health = Test-Url "$BaseUrl/health"
    if ($health.Ok) {
        Write-Info "API Gateway responde en $BaseUrl/health (HTTP $($health.StatusCode))."
    } else {
        Write-Warn "API Gateway no responde en $BaseUrl/health. Los escenarios HTTP pueden fallar."
    }
}

# ============================================================
# Escenarios
# ============================================================
function Invoke-RequestScenario {
    param([string]$ReportDir)

    $health = Test-Url "$BaseUrl/health"
    if (-not $health.Ok) {
        return [pscustomobject]@{
            Name    = "request"
            Passed  = $false
            Details = "API Gateway no responde en $BaseUrl/health. ¿Port-forward activo?"
        }
    }

    $total = if ($LoadTotalRequests -gt 0) { $LoadTotalRequests } else { switch ($Intensity) { "low" { 200 } "high" { 1000 } default { 500 } } }
    $concurrency = if ($LoadConcurrency -gt 0) { $LoadConcurrency } else { 8 }
    $csv = Join-Path $ReportDir "http\requests.csv"
    $rateLimit = -not $SkipRateLimitTest

    Write-Info "Generando carga HTTP (TotalRequests=$total, Concurrency=$concurrency, RateLimitTest=$rateLimit)"
    Invoke-TrafficLoad -BaseUrl $BaseUrl -UsersServiceUrl $UsersServiceUrl `
        -TotalRequests $total -Concurrency $concurrency -NormalDelayMs $LoadNormalDelayMs `
        -DurationSec $LoadDurationSec -IncludeRateLimitTest:$rateLimit -OutputCsv $csv | Out-Host

    if (-not (Test-Path $csv)) {
        return [pscustomobject]@{ Name = "request"; Passed = $false; Details = "No se genero $csv" }
    }

    $rows = @(Import-Csv $csv)
    $count429 = @($rows | Where-Object { [int]$_.StatusCode -eq 429 }).Count
    $count5xx = @($rows | Where-Object { [int]$_.StatusCode -ge 500 }).Count
    $countNet = @($rows | Where-Object { [int]$_.StatusCode -eq 0 }).Count

    $passed = ($rows.Count -gt 0) -and ($count5xx -eq 0)
    $criterio = "modo carga: se espera 5xx=0"
    if (-not $SkipRateLimitTest) {
        $passed = $passed -and ($count429 -gt 0)
        $criterio = "se espera 429>0 y 5xx=0"
    }

    # Verificar el header Retry-After en una respuesta 429 (mitigacion con aviso de reintento)
    $retryAfter = ""
    if ($count429 -gt 0) {
        try {
            $resp = Invoke-WebRequest -Uri "$BaseUrl/api/roles" -Headers @{ "X-Real-IP" = "10.99.99.99" } -UseBasicParsing -TimeoutSec 10
            $retryAfter = [string]$resp.Headers["Retry-After"]
        } catch {
            if ($_.Exception.Response) {
                try { $retryAfter = [string]$_.Exception.Response.Headers["Retry-After"] } catch { }
            }
        }
    }

    return [pscustomobject]@{
        Name    = "request"
        Passed  = $passed
        Details = "requests=$($rows.Count) 429=$count429 5xx=$count5xx netErr=$countNet retryAfter=$retryAfter ($criterio)"
    }
}

function Invoke-CpuScenario {
    param([string]$ReportDir)

    $pods = Get-TargetPods -Namespace $Namespace -Deployment $Target
    $workers = Get-IntensityWorkers $Intensity
    $start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $remote = @'
i=0
while [ $i -lt {0} ]; do
  (end=$(( $(date +%s) + {1} )); while [ $(date +%s) -lt $end ]; do :; done) &
  i=$((i+1))
done
wait
'@ -f $workers, $DurationSec

    # Stress concurrent en TODOS los pods del deployment (las replicas tambien sienten el caos)
    $jobs = @()
    foreach ($pod in $pods) {
        Write-Info "CPU stress en ${pod}: $workers worker(s) por ${DurationSec}s"
        $jobs += Start-Job -Name "chaos-cpu-$pod" -ScriptBlock {
            param($Ns, $Pod, $Script)
            & kubectl exec -n $Ns $Pod -- sh -c $Script 2>&1
        } -ArgumentList $Namespace, $pod, $remote
    }

    # Evidencia del pico: snapshot de kubectl/Prometheus a mitad del estres
    Start-Sleep -Seconds ([Math]::Max(10, [int]($DurationSec / 2)))
    Save-KubectlSnapshot -Namespace $Namespace -ReportDir $ReportDir -Tag "peak"
    $null = Save-PromSnapshot -BaseUrl $PrometheusUrl -Namespace $Namespace -Target $Target -JobName (Get-JobName -Target $Target) -ReportDir $ReportDir -Tag "peak"

    $null = Wait-Job -Job $jobs -Timeout ($DurationSec + 120)
    $jobs | Where-Object { $_.State -eq "Running" } | Stop-Job
    foreach ($j in $jobs) {
        Receive-Job $j | Out-Host
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $query = "sum(rate(container_cpu_usage_seconds_total{namespace=`"$Namespace`",pod=~`"$Target.*`",container!=`"POD`"}[1m]))"
    $cpuMax = Get-PromRangeMax -BaseUrl $PrometheusUrl -Query $query -Start $start -End ($end + 15)
    if ($null -eq $cpuMax) {
        $top = kubectl top pods -n $Namespace -l "app=$Target" --no-headers 2>$null | Out-String
        $totalMilli = 0
        foreach ($m in [regex]::Matches($top, '(\d+)m\s')) { $totalMilli += [int]$m.Groups[1].Value }
        if ($totalMilli -gt 0) { $cpuMax = [double]$totalMilli / 1000.0 }
    }

    $null = Wait-DeploymentReady -Namespace $Namespace -Deployment $Target -TimeoutSec 120
    $passed = ($null -ne $cpuMax) -and ($cpuMax -ge 0.25)
    $cpuText = if ($null -eq $cpuMax) { "sin dato" } else { ("{0:N3} cores" -f $cpuMax) }
    return [pscustomobject]@{
        Name    = "cpu"
        Passed  = $passed
        Details = "replicas=$($pods.Count) workers/pod=$workers cpuMax=$cpuText (se espera >= 0.25 cores en agregado)"
    }
}

function Invoke-MemoryScenario {
    param([string]$ReportDir, $Baseline)

    $pods = Get-TargetPods -Namespace $Namespace -Deployment $Target
    $mb = if ($SizeMB -gt 0) { $SizeMB } else { Get-IntensityMemoryMB $Intensity }
    $start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $remote = @'
v=$(dd if=/dev/zero bs=1M count={0} 2>/dev/null | tr '\0' 'x')
echo "allocated_bytes={2}"
sleep {1}
'@ -f $mb, $DurationSec, '${#v}'

    # Asignacion concurrente en TODOS los pods; con high (512MB > limite 384Mi) hay OOMKill por replica
    $jobs = @()
    foreach ($pod in $pods) {
        Write-Info "Memoria: asignando ${mb}MB en $pod por ${DurationSec}s"
        $jobs += Start-Job -Name "chaos-memory-$pod" -ScriptBlock {
            param($Ns, $Pod, $Script)
            & kubectl exec -n $Ns $Pod -- sh -c $Script 2>&1
        } -ArgumentList $Namespace, $pod, $remote
    }

    # Evidencia del pico: snapshot de kubectl/Prometheus a mitad de la asignacion
    Start-Sleep -Seconds ([Math]::Max(10, [int]($DurationSec / 2)))
    Save-KubectlSnapshot -Namespace $Namespace -ReportDir $ReportDir -Tag "peak"
    $null = Save-PromSnapshot -BaseUrl $PrometheusUrl -Namespace $Namespace -Target $Target -JobName (Get-JobName -Target $Target) -ReportDir $ReportDir -Tag "peak"

    $null = Wait-Job -Job $jobs -Timeout ($DurationSec + 120)
    $jobs | Where-Object { $_.State -eq "Running" } | Stop-Job
    $allOut = ""
    foreach ($j in $jobs) {
        $allOut += ((Receive-Job $j | Out-String) + "`n")
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    $allOut | Out-Host
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    $query = "sum(container_memory_working_set_bytes{namespace=`"$Namespace`",pod=~`"$Target.*`",container!=`"POD`"})"
    $memMax = Get-PromRangeMax -BaseUrl $PrometheusUrl -Query $query -Start $start -End ($end + 15)
    $memBefore = Get-SnapshotScalar -Snapshot $Baseline -Key "memory_bytes"

    # Deteccion de OOMKill en cualquier replica del deployment
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $podJson = kubectl get pods -n $Namespace -l "app=$Target" -o json 2>$null | Out-String
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $oom = ($allOut -match 'exit code 137') -or ($podJson -match '"reason"\s*:\s*"OOMKilled"')
    $null = Wait-DeploymentReady -Namespace $Namespace -Deployment $Target -TimeoutSec 120

    $allocatedSum = 0
    foreach ($m in [regex]::Matches($allOut, 'allocated_bytes=(\d+)')) { $allocatedSum += [int64]$m.Groups[1].Value }
    $delta = $null
    if ($null -ne $memMax -and $null -ne $memBefore) { $delta = $memMax - $memBefore }
    $targetBytes = [int64]($mb * $pods.Count * 1MB)
    $passed = $oom -or ($allocatedSum -ge [int64]($targetBytes * 0.8)) -or ($null -ne $delta -and $delta -ge (50 * 1024 * 1024))

    $memText = if ($null -eq $memMax) { "sin dato" } else { ("{0:N0} MB" -f ($memMax / 1MB)) }
    $deltaText = if ($null -eq $delta) { "n/d" } else { ("{0:N0} MB" -f ($delta / 1MB)) }
    return [pscustomobject]@{
        Name    = "memory"
        Passed  = $passed
        Details = "replicas=$($pods.Count) intento=${mb}MB/pod allocatedSum=$([math]::Round($allocatedSum / 1MB, 0))MB memMax=$memText delta=$deltaText oomKilled=$oom"
    }
}

function Invoke-StorageScenario {
    param([string]$ReportDir)

    $pods = Get-TargetPods -Namespace $Namespace -Deployment $Target
    $mbDefault = if ($SizeMB -gt 0) { $SizeMB } else { Get-IntensityStorageMB $Intensity }

    # Espacio libre y objetivo por pod (el primer df define el baseline)
    $beforeUsed = @{}
    $podPlan = @()
    foreach ($pod in $pods) {
        $mbPod = $mbDefault
        $dfBefore = kubectl exec -n $Namespace $pod -- df -m /tmp 2>$null | Out-String
        $beforeLine = ($dfBefore -split "`n" | Where-Object { $_ -match '^\S+\s+\d+\s+\d+\s+\d+\s+\d+%' } | Select-Object -Last 1)
        $usedBefore = $null
        if ($beforeLine) {
            $parts = ($beforeLine.Trim() -split '\s+')
            if ($parts.Count -ge 4) {
                $usedBefore = [int]$parts[2]
                $freeMb = [int]$parts[3]
                if ($freeMb -lt ($mbPod + 100)) {
                    $mbPod = [Math]::Max(50, $freeMb - 100)
                    Write-Warn "Poco espacio libre en $pod (${freeMb}MB). Objetivo reducido a ${mbPod}MB."
                }
            }
        }
        $beforeUsed[$pod] = $usedBefore
        $podPlan += [pscustomobject]@{ Pod = $pod; Mb = $mbPod }
    }

    # Escritura concurrente en TODOS los pods
    $jobs = @()
    foreach ($p in $podPlan) {
        $remote = @'
dd if=/dev/zero of=/tmp/chaos_fill bs=1M count={0} 2>/dev/null
df -m /tmp
sleep {1}
rm -f /tmp/chaos_fill
echo cleaned
'@ -f $p.Mb, $DurationSec

        Write-Info "Storage: escribiendo $($p.Mb)MB en /tmp de $($p.Pod)"
        $jobs += Start-Job -Name "chaos-storage-$($p.Pod)" -ScriptBlock {
            param($Ns, $Pod, $Script)
            & kubectl exec -n $Ns $Pod -- sh -c $Script 2>&1
        } -ArgumentList $Namespace, $p.Pod, $remote
    }

    # Evidencia del pico: df de cada pod con el archivo ocupando + snapshot Prom
    Start-Sleep -Seconds ([Math]::Max(10, [int]($DurationSec / 2)))
    $null = Save-PromSnapshot -BaseUrl $PrometheusUrl -Namespace $Namespace -Target $Target -JobName (Get-JobName -Target $Target) -ReportDir $ReportDir -Tag "peak"
    $peakDf = foreach ($p in $podPlan) {
        "-- $($p.Pod) --"
        (& kubectl exec -n $Namespace $p.Pod -- df -m /tmp 2>$null | Out-String).Trim()
    }
    ($peakDf | Out-String) | Set-Content -Path (Join-Path $ReportDir "kubectl\df-peak.txt") -Encoding utf8

    $null = Wait-Job -Job $jobs -Timeout ($DurationSec + 120)
    $jobs | Where-Object { $_.State -eq "Running" } | Stop-Job
    $outputs = @{}
    foreach ($j in $jobs) {
        $outputs[$j.Name] = (Receive-Job $j | Out-String)
        Remove-Job $j -Force -ErrorAction SilentlyContinue
    }
    foreach ($p in $podPlan) {
        if (-not [string]::IsNullOrWhiteSpace($outputs["chaos-storage-$($p.Pod)"])) { $outputs["chaos-storage-$($p.Pod)"] | Out-Host }
    }

    # Delta total de uso vs baseline
    $deltaTotal = 0
    $deltasKnown = $true
    foreach ($p in $podPlan) {
        $usedDuring = $null
        $jobOut = $outputs["chaos-storage-$($p.Pod)"]
        if ($jobOut) {
            $duringLine = ($jobOut -split "`n" | Where-Object { $_ -match '^\S+\s+\d+\s+\d+\s+\d+\s+\d+%' } | Select-Object -First 1)
            if ($duringLine) {
                $parts = ($duringLine.Trim() -split '\s+')
                if ($parts.Count -ge 4) { $usedDuring = [int]$parts[2] }
            }
        }
        if ($null -ne $usedDuring -and $null -ne $beforeUsed[$p.Pod]) {
            $deltaTotal += ($usedDuring - $beforeUsed[$p.Pod])
        } else {
            $deltasKnown = $false
        }
    }
    $noSpace = (($outputs.Values -join "`n") -match "No space left|No space")
    $targetTotal = ($podPlan | Measure-Object -Property Mb -Sum).Sum
    $passed = $noSpace -or ($deltasKnown -and $deltaTotal -ge ($targetTotal * 0.8))

    $deltaText = if ($deltasKnown) { "${deltaTotal}MB" } else { "n/d" }
    return [pscustomobject]@{
        Name    = "storage"
        Passed  = $passed
        Details = "replicas=$($pods.Count) intento=${mbDefault}MB/pod (total=${targetTotal}MB) usadoDelta=$deltaText noSpace=$noSpace"
    }
}

function Invoke-NetworkScenario {
    param([string]$ReportDir)

    $start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $usedPolicy = $false
    $tcApplied = @()
    $endpointsEmpty = $false
    $policyFile = Join-Path $ReportDir "manifests\chaos-netpol.yaml"
    $pods = Get-TargetPods -Namespace $Namespace -Deployment $Target

    try {
        if ($NetworkMode -eq "netpol") {
            $usedPolicy = $true
            $policy = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: chaos-deny-egress
  namespace: $Namespace
  labels:
    chaos: pharmago
spec:
  podSelector:
    matchLabels:
      app: $Target
  policyTypes:
    - Egress
  egress: []
"@
            Set-Content -Path $policyFile -Value $policy -Encoding utf8
            Write-Info "Aplicando NetworkPolicy deny-egress a $Target"
            kubectl apply -f $policyFile 2>&1 | Out-Host
            Start-Sleep -Seconds $DurationSec
        } else {
            foreach ($pod in $pods) {
                $existing = kubectl get pod $pod -n $Namespace -o jsonpath='{.spec.ephemeralContainers[*].name}' 2>$null | Out-String
                if ($existing -notmatch "chaos-net") {
                    Write-Info "Creando contenedor efimero chaos-net en $pod"
                    kubectl debug -n $Namespace "pod/$pod" --profile=netadmin --image=nicolaka/netshoot --attach=false -c chaos-net -- sh -c "sleep $($DurationSec + 180)" 2>&1 | Out-Host
                    $deadline = (Get-Date).AddSeconds(90)
                    $readyAt = ""
                    do {
                        $readyAt = kubectl get pod $pod -n $Namespace -o jsonpath='{.status.ephemeralContainerStatuses[?(@.name==\"chaos-net\")].state.running.startedAt}' 2>$null | Out-String
                        if (-not [string]::IsNullOrWhiteSpace($readyAt)) { break }
                        Start-Sleep -Seconds 3
                    } while ((Get-Date) -lt $deadline)
                    if ([string]::IsNullOrWhiteSpace($readyAt)) {
                        throw "El contenedor efimero chaos-net no inicio en 90s en $pod (¿RBAC o imagen?)."
                    }
                }
                Write-Info "Aplicando tc netem loss 100% en $pod"
                kubectl exec -n $Namespace $pod -c chaos-net -- tc qdisc add dev eth0 root netem loss 100% 2>&1 | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "No se pudo aplicar tc netem en $pod." }
                $tcApplied += $pod
            }
            Start-Sleep -Seconds $DurationSec
            $endpoints = kubectl get endpointslices -n $Namespace -l "kubernetes.io/service-name=$Target" -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>$null | Out-String
            $endpointsEmpty = [string]::IsNullOrWhiteSpace($endpoints)
            foreach ($pod in $tcApplied) {
                try {
                    kubectl exec -n $Namespace $pod -c chaos-net -- tc qdisc del dev eth0 root 2>&1 | Out-Host
                } catch {
                    Write-Warn "No se pudo retirar el qdisc de $pod (puede haberse eliminado ya): $($_.Exception.Message)"
                }
            }
        }
    } finally {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            if ($usedPolicy -and (Test-Path $policyFile)) {
                kubectl delete -f $policyFile 2>&1 | Out-Host
            }
            if (-not $usedPolicy) {
                foreach ($pod in $pods) {
                    if ($tcApplied -contains $pod) {
                        try {
                            kubectl exec -n $Namespace $pod -c chaos-net -- tc qdisc del dev eth0 root 2>&1 | Out-Null
                        } catch {
                            # El qdisc puede haberse removido con el contenedor; no es fatal.
                        }
                    }
                    # El contenedor efimero no se puede quitar sin recrear el pod.
                    kubectl delete pod $pod -n $Namespace --wait=false 2>&1 | Out-Host
                }
                $null = Wait-DeploymentReady -Namespace $Namespace -Deployment $Target -TimeoutSec 120
            }
        } finally {
            $ErrorActionPreference = $prevEap
        }
    }

    $end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $job = Get-JobName -Target $Target
    $upMin = Get-PromRangeMin -BaseUrl $PrometheusUrl -Query "up{job=`"$job`"}" -Start $start -End ($end + 15)
    $http5xxMax = Get-PromRangeMax -BaseUrl $PrometheusUrl -Query 'sum(rate(pharmago_http_requests_total{status_code=~"5.."}[1m]))' -Start $start -End ($end + 15)

    $passed = ($null -ne $upMin -and $upMin -eq 0) -or ($null -ne $http5xxMax -and $http5xxMax -gt 0) -or $endpointsEmpty
    $details = "pods=$($pods -join ',') mode=$NetworkMode upMin=$upMin http5xxMax=$http5xxMax endpointsEmpty=$endpointsEmpty"
    if ($usedPolicy -and -not $passed) {
        $details += " | Sin impacto: el CNI de Minikube puede no aplicar NetworkPolicy; proba -NetworkMode tc"
    }
    return [pscustomobject]@{ Name = "network"; Passed = $passed; Details = $details }
}

function Invoke-DisconnectScenario {
    param([string]$ReportDir)

    $mode = $DisconnectMode
    if ($Target -eq "pharmago-db") { $mode = "service" }

    $start = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $impacted = $false
    $originalSelector = $null
    $originalReplicas = 2

    try {
        if ($mode -eq "service") {
            $originalSelector = kubectl get service $Target -n $Namespace -o jsonpath='{.spec.selector}' 2>$null | Out-String
            if ([string]::IsNullOrWhiteSpace($originalSelector)) {
                throw "No se pudo leer el selector del Service '$Target'."
            }
            Write-Info "Desconectando Service $Target (selector -> chaos-disconnected)"
            $patch = @{ spec = @{ selector = @{ app = "chaos-disconnected" } } } | ConvertTo-Json -Compress
            kubectl patch service $Target -n $Namespace --type merge -p $patch 2>&1 | Out-Host
            Start-Sleep -Seconds $DurationSec
            $endpoints = kubectl get endpointslices -n $Namespace -l "kubernetes.io/service-name=$Target" -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>$null | Out-String
            $impacted = [string]::IsNullOrWhiteSpace($endpoints)
        } else {
            $originalReplicas = [int](kubectl get deployment $Target -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null | Out-String)
            if ($originalReplicas -lt 1) { $originalReplicas = 2 }
            Write-Info "Escalando $Target a 0 replicas (original=$originalReplicas)"
            kubectl scale deployment $Target -n $Namespace --replicas=0 2>&1 | Out-Host
            Start-Sleep -Seconds $DurationSec
            # Polling robusto: readyReplicas puede laggear o venir vacio
            $deadline = (Get-Date).AddSeconds(30)
            do {
                $readyText = ([string](kubectl get deployment $Target -n $Namespace -o jsonpath='{.status.readyReplicas}' 2>$null | Out-String)).Trim()
                if ([string]::IsNullOrWhiteSpace($readyText) -or $readyText -eq "0") { break }
                Start-Sleep -Seconds 3
            } while ((Get-Date) -lt $deadline)
            $impacted = [string]::IsNullOrWhiteSpace($readyText) -or ($readyText -eq "0")
        }
    } finally {
        if ($mode -eq "service" -and $originalSelector) {
            Write-Info "Restaurando selector de $Target"
            $selectorObject = $originalSelector | ConvertFrom-Json
            $restore = @{ spec = @{ selector = $selectorObject } } | ConvertTo-Json -Depth 5 -Compress
            kubectl patch service $Target -n $Namespace --type merge -p $restore 2>&1 | Out-Host
        } elseif ($mode -eq "scale") {
            Write-Info "Restaurando $Target a $originalReplicas replicas"
            kubectl scale deployment $Target -n $Namespace --replicas=$originalReplicas 2>&1 | Out-Host
        }
    }

    if ($mode -eq "service") {
        $deadline = (Get-Date).AddSeconds(30)
        do {
            $endpointsAfter = kubectl get endpoints $Target -n $Namespace -o jsonpath='{.subsets[*].addresses[*].ip}' 2>$null | Out-String
            if (-not [string]::IsNullOrWhiteSpace($endpointsAfter)) { break }
            Start-Sleep -Seconds 2
        } while ((Get-Date) -lt $deadline)
        $recovered = -not [string]::IsNullOrWhiteSpace($endpointsAfter)
    } else {
        $recovered = Wait-DeploymentReady -Namespace $Namespace -Deployment $Target -TimeoutSec 120
    }
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $http5xxMax = Get-PromRangeMax -BaseUrl $PrometheusUrl -Query 'sum(rate(pharmago_http_requests_total{status_code=~"5.."}[1m]))' -Start $start -End ($end + 15)
    $passed = $impacted -and $recovered

    return [pscustomobject]@{
        Name    = "disconnect"
        Passed  = $passed
        Details = "target=$Target mode=$mode impacted=$impacted recovered=$recovered http5xxMax=$http5xxMax"
    }
}

# ============================================================
# Flujo principal
# ============================================================
if (-not $SkipPreflight) { Invoke-Preflight }

$scenarios = if ($Scenario -eq "all") {
    @("request", "cpu", "memory", "storage", "network", "disconnect")
} else {
    @($Scenario)
}

if ($DryRun) {
    Write-Section "Dry run"
    Write-Info "Namespace: $Namespace | Target: $Target | Duracion: ${DurationSec}s | Intensidad: $Intensity"
    foreach ($s in $scenarios) { Write-Info "Se ejecutaria: $s" }
    exit 0
}

if (-not $Force) {
    Write-Warn "Vas a inyectar fallas en el namespace '$Namespace'."
    $answer = Read-Host "Escribi CHAOS para continuar"
    if ($answer -ne "CHAOS") {
        Write-Info "Cancelado."
        exit 0
    }
}

New-Item -ItemType Directory -Force -Path $ReportRoot | Out-Null
$runDir = Join-Path $ReportRoot (Get-Date -Format "yyyyMMdd-HHmmss")
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$results = @()

foreach ($s in $scenarios) {
    Write-Section "Escenario: $s"
    $reportDir = New-ReportDir -Root $runDir -Scenario $s
    Save-KubectlSnapshot -Namespace $Namespace -ReportDir $reportDir -Tag "baseline"
    $baseline = Save-PromSnapshot -BaseUrl $PrometheusUrl -Namespace $Namespace -Target $Target -JobName (Get-JobName -Target $Target) -ReportDir $reportDir -Tag "baseline"

    try {
        $result = switch ($s) {
            "request"    { Invoke-RequestScenario    -ReportDir $reportDir }
            "cpu"        { Invoke-CpuScenario        -ReportDir $reportDir }
            "memory"     { Invoke-MemoryScenario     -ReportDir $reportDir -Baseline $baseline }
            "storage"    { Invoke-StorageScenario    -ReportDir $reportDir }
            "network"    { Invoke-NetworkScenario    -ReportDir $reportDir }
            "disconnect" { Invoke-DisconnectScenario -ReportDir $reportDir }
            "gametime"   { Invoke-GameTimeScenario   -ReportDir $reportDir }
        }
    } catch {
        $result = [pscustomobject]@{
            Name    = $s
            Passed  = $false
            Details = "Excepcion: $($_.Exception.Message)"
        }
    }

    Save-KubectlSnapshot -Namespace $Namespace -ReportDir $reportDir -Tag "impact"
    $null = Save-PromSnapshot -BaseUrl $PrometheusUrl -Namespace $Namespace -Target $Target -JobName (Get-JobName -Target $Target) -ReportDir $reportDir -Tag "impact"

    $result | Add-Member -NotePropertyName ReportDir -NotePropertyValue $reportDir -Force
    $result | Add-Member -NotePropertyName DurationSec -NotePropertyValue $DurationSec -Force
    $results += $result

    if ($result.Passed) { Write-Ok $result.Details } else { Write-Fail $result.Details }
    Start-Sleep -Seconds 5
}

# ============================================================
# Reporte consolidado
# ============================================================
$summaryJson = Join-Path $runDir "summary.json"
$results | ConvertTo-Json -Depth 8 | Set-Content -Path $summaryJson -Encoding utf8

$lines = @(
    "# Reporte de caos",
    "",
    "- Fecha: $((Get-Date).ToString('o'))",
    "- Namespace: $Namespace",
    "- Target: $Target",
    "- Duracion por escenario: ${DurationSec}s",
    "- Intensidad: $Intensity",
    "",
    "| Escenario | Resultado | Detalle | Reporte |",
    "|---|---|---|---|"
)
foreach ($r in $results) {
    $status = if ($r.Passed) { "PASS" } else { "FAIL" }
    $lines += "| $($r.Name) | $status | $($r.Details) | $($r.ReportDir) |"
}
$lines += ""
$lines += "Artefactos: Prometheus (baseline/impact), kubectl (pods/top/events) y HTTP en cada carpeta."
$summaryMd = Join-Path $runDir "summary.md"
$lines | Set-Content -Path $summaryMd -Encoding utf8

Write-Section "Resumen"
$results | Format-Table Name, Passed, Details -AutoSize | Out-Host
Write-Info "Reporte: $summaryMd"

if ($results.Where({ -not $_.Passed }).Count -gt 0) { exit 1 }
exit 0
