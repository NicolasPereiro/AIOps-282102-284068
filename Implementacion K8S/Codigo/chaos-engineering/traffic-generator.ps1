<#
.SYNOPSIS
    Genera trafico HTTP mixto (200 y 4XX) contra los servicios de Users y Pharmacy a traves del API Gateway.

.DESCRIPTION
    Crea una cola de peticiones ponderada que mezcla endpoints publicos y protegidos,
    validos e invalidos, para producir codigos 200, 400, 401, 404 y 429 (rate limit).
    Usa las credenciales sembradas para obtener tokens JWT de sesion y ejercitar
    endpoints protegidos. Ejecuta con un pool de runspaces para generar carga concurrente.

.PARAMETER BaseUrl
    URL base del API Gateway. Por defecto http://127.0.0.1:5000

.PARAMETER TotalRequests
    Numero total de peticiones a generar. Por defecto 200.

.PARAMETER Concurrency
    Numero de peticiones concurrentes. Por defecto 10.

.PARAMETER DelayMs
    Pausa en milisegundos entre el lanzamiento de cada peticion (0 = sin pausa).
    Util para no saturar el rate limit del gateway.

.PARAMETER OutputCsv
    Ruta del CSV con el detalle de cada peticion. Por defecto traffic-results.csv en el mismo directorio.

.EXAMPLE
    .\traffic-generator.ps1

.EXAMPLE
    .\traffic-generator.ps1 -TotalRequests 500 -Concurrency 20
#>

param(
    [string]$BaseUrl = "http://127.0.0.1:5000",
    [string]$UsersServiceUrl = "http://127.0.0.1:5001",
    [int]$TotalRequests = 200,
    [int]$Concurrency = 10,
    [int]$SuccessPercent = 60,
    [int]$ClientErrorPercent = 20,
    [int]$NormalDelayMs = 100,
    [string]$OutputCsv = ""
)

$ErrorActionPreference = "Stop"

# Si no se especifica OutputCsv, no se genera archivo (solo log en consola)

Write-Host "=== PharmaGo Traffic Generator ===" -ForegroundColor Cyan
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

$adminToken = Get-AuthToken -UserName "admin" -Password "AdminPassword123!"
$empToken   = Get-AuthToken -UserName "empleado" -Password "EmpleadoPassword123!"
$ownerToken = Get-AuthToken -UserName "duenio" -Password "DuenioPassword123!"

# ---------------------------------------------------------------------------
# 2. Escenarios por categoria (200, 4XX sin 429, 429)
# ---------------------------------------------------------------------------
$successScenarios = @(
    @{ Method = "GET";  Path = "/api/roles" },
    @{ Method = "GET";  Path = "/api/roles/test" },
    @{ Method = "GET";  Path = "/api/roles/ping" },
    @{ Method = "POST"; Path = "/api/login"; Body = '{"UserName":"admin","Password":"AdminPassword123!"}' },
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
    @{ Method = "GET";  Path = "/api/invitations"; },
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
# 3. Construir la cola con distribucion controlada
# ---------------------------------------------------------------------------
$rateLimitPercent = 100 - $SuccessPercent - $ClientErrorPercent
$successCount = [int]($TotalRequests * $SuccessPercent / 100)
$clientCount  = [int]($TotalRequests * $ClientErrorPercent / 100)
$rateCount    = $TotalRequests - $successCount - $clientCount

# El rate limit del gateway es 100 req/min por IP y por pod. Con 2 replicas
# hay que superar 100 req/min en CADA pod, por eso el bloque 429 necesita
# al menos 202 peticiones rapidas desde la misma IP.
if ($rateCount -lt 202) {
    Write-Host "Ajustando bloque 429 a 202 (minimo para disparar rate limit con 2 replicas)" -ForegroundColor Yellow
    $rateCount = 202
}

$queue = New-Object System.Collections.ArrayList

for ($i = 0; $i -lt $successCount; $i++) {
    $s = $successScenarios | Get-Random
    $item = $s.Clone()
    $item.DelayMs = $NormalDelayMs
    if (-not $item.Headers) { $item.Headers = @{} }
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
for ($i = 0; $i -lt $rateCount; $i++) {
    $s = $rateLimitScenarios | Get-Random
    $item = $s.Clone()
    $item.DelayMs = 0
    # Sin X-Real-IP: todas desde la misma IP real del port-forward -> disparan 429
    [void]$queue.Add($item)
}

# Mezclar para no enviar todos los 429 juntos
$queue = $queue | Sort-Object { Get-Random }

$totalReal = $successCount + $clientCount + $rateCount
Write-Host "Cola generada: $totalReal peticiones" -ForegroundColor Yellow
Write-Host "  200 (exitosas)     : $successCount" -ForegroundColor Green
Write-Host "  4XX (cliente)      : $clientCount" -ForegroundColor Yellow
Write-Host "  429 (rate limit)   : $rateCount" -ForegroundColor Yellow
Write-Host ""
Write-Host "Nota: el bloque 429 necesita >=202 req (2 replicas). Para una distribucion 60/20/20 real use -TotalRequests 1000 o superior." -ForegroundColor Gray
Write-Host ""
# ---------------------------------------------------------------------------
# 4. Scriptblock ejecutado en cada runspace
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 5. Ejecutar con pool de runspaces
# ---------------------------------------------------------------------------
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

# Exportar CSV (opcional)
if (-not [string]::IsNullOrWhiteSpace($OutputCsv)) {
    $results | Select-Object Method, Path, StatusCode, ElapsedMs, Error |
        Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Detalle exportado a: $OutputCsv" -ForegroundColor Green
}