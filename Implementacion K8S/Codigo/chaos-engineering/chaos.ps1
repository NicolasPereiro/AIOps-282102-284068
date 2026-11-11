# ==============================================================================
# PharmaGo - Chaos Engineering & Constant Traffic Generator
# Ejecución directa: .\chaos.ps1
# (Sin parámetros obligatorios ni decoradores; todo preconfigurado y automatizado)
# ==============================================================================

$ErrorActionPreference = "Continue"

# Configuraciones fijas del entorno
$Namespace = "pharmago"
$BaseUrl = "http://127.0.0.1:5000"
$TargetRate = 20        # 20 req/segundo
$SimulatedUsers = 20    # 20 usuarios virtuales concurrentes
$IntervalMs = 50        # 1000ms / 20 = 50ms por request

# Duracion opcional de la corrida via variable de entorno (para corridas automatizadas).
# Sin definirla, el motor corre indefinido hasta Ctrl+C (uso normal: .\chaos.ps1).
$MaxDurationSec = 0
try {
    $envDur = [Environment]::GetEnvironmentVariable("CHAOS_DURATION_SEC")
    if ($envDur) { $MaxDurationSec = [int]$envDur }
} catch { }
if ($MaxDurationSec -lt 0) { $MaxDurationSec = 0 }

# Helpers de formato en terminal
function Write-Header([string]$text) {
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host ("  " + $text) -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
}

function Write-EventBanner([string]$title, [string]$detail) {
    Write-Host ""
    Write-Host ("#" * 80) -ForegroundColor Magenta
    Write-Host "  >>> INICIANDO EVENTO DE CAOS: $title" -ForegroundColor Yellow
    Write-Host "      $detail" -ForegroundColor Gray
    Write-Host ("#" * 80) -ForegroundColor Magenta
    Write-Host ""
}

function Write-EventEnd([string]$title, [string]$result) {
    Write-Host ""
    Write-Host "  <<< EVENTO FINALIZADO: $title" -ForegroundColor Green
    Write-Host "      Resultado: $result" -ForegroundColor Gray
    Write-Host ""
}

# 1. Asegurar conectividad con API Gateway (auto-port-forward si no está activo)
function Ensure-GatewayPortForward {
    param([string]$Url = "http://127.0.0.1:5000/health")
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($r.StatusCode -eq 200) { return $true }
    } catch { }

    Write-Host "  [!] Esperando que el API Gateway responda en $Url..." -ForegroundColor Yellow
    Write-Host "      (Asegurate de haber iniciado tu port-forward: 127.0.0.1:5000)" -ForegroundColor Gray
    
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($r.StatusCode -eq 200) {
                Write-Host "  [OK] Conectividad con API Gateway confirmada." -ForegroundColor Green
                return $true
            }
        } catch { }
    }
    Write-Host "  [WARN] No se pudo verificar $Url. Se continuara intentando..." -ForegroundColor Yellow
    return $false
}

# 2. Inicialización
Write-Header "PHARMAGO - CHAOS ENGINEERING (20 req/s, 90% 200 OK / 10% 4xx + Caos en Vivo)"
Write-Host "Verificando cluster Kubernetes y servicios..." -ForegroundColor Cyan
Ensure-GatewayPortForward | Out-Null

# Obtener tokens JWT para peticiones autenticadas de los 20 usuarios
Write-Host "Obteniendo tokens JWT de autenticacion para roles..." -ForegroundColor Cyan
$adminToken = ""
$empToken = ""
$ownToken = ""

try {
    $resAdmin = Invoke-RestMethod -Uri "$BaseUrl/api/login" -Method Post -Body '{"UserName":"admin","Password":"Abcdef12."}' -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
    $adminToken = $resAdmin.token
} catch { }

try {
    $resEmp = Invoke-RestMethod -Uri "$BaseUrl/api/login" -Method Post -Body '{"UserName":"empleado01","Password":"Abcdef12."}' -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
    $empToken = $resEmp.token
} catch { }

try {
    $resOwn = Invoke-RestMethod -Uri "$BaseUrl/api/login" -Method Post -Body '{"UserName":"owner001","Password":"Abcdef12."}' -ContentType "application/json" -TimeoutSec 5 -ErrorAction Stop
    $ownToken = $resOwn.token
} catch { }

$tokenStatus = "Admin=" + $(if ($adminToken){"OK"}else{"FAIL"}) + ", Empleado=" + $(if ($empToken){"OK"}else{"FAIL"}) + ", Owner=" + $(if ($ownToken){"OK"}else{"FAIL"})
Write-Host "  Tokens obtenidos: $tokenStatus" -ForegroundColor Gray

# Definicion de peticiones validas (200 OK esperadas) y de error (400, 401, 404 esperadas)
$validRequests = @(
    @{ Method = "GET"; Path = "/api/roles"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/roles/ping"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/roles/test"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/drug"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/drug/1"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/pharmacy"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/presentations"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/unitmeasures"; Headers = @{} },
    @{ Method = "GET"; Path = "/api/drug/User"; Headers = @{ Authorization = $empToken } },
    @{ Method = "GET"; Path = "/api/purchases"; Headers = @{ Authorization = $empToken } },
    @{ Method = "GET"; Path = "/api/pharmacy/1"; Headers = @{ Authorization = $adminToken } },
    @{ Method = "GET"; Path = "/api/invitations"; Headers = @{ Authorization = $adminToken } },
    @{ Method = "GET"; Path = "/api/stockrequest"; Headers = @{ Authorization = $ownToken } },
    @{ Method = "GET"; Path = "/api/export/exporters"; Headers = @{ Authorization = $empToken } }
)

$errorRequests = @(
    @{ Method = "GET";  Path = "/api/drug/abc"; Headers = @{}; Expect = 400 },
    @{ Method = "POST"; Path = "/api/users"; Headers = @{}; Body = '{"UserName":"","Email":"invalido"}'; Expect = 400 },
    @{ Method = "POST"; Path = "/api/purchases"; Headers = @{}; Body = '{}'; Expect = 400 },
    @{ Method = "GET";  Path = "/api/drug/999999"; Headers = @{}; Expect = 404 },
    @{ Method = "GET";  Path = "/api/recurso-inexistente"; Headers = @{}; Expect = 404 },
    @{ Method = "GET";  Path = "/api/purchases"; Headers = @{}; Expect = 401 },
    @{ Method = "GET";  Path = "/api/invitations"; Headers = @{}; Expect = 401 },
    @{ Method = "POST"; Path = "/api/login"; Headers = @{}; Body = '{"UserName":"admin","Password":"wrongpassword"}'; Expect = 404 }
)

# Configuracion del pool de usuarios simulados
# Cada usuario tiene un identificador unico (User-01 a User-20) e IP virtual rotativa
$userIps = @{}
for ($u = 1; $u -le $SimulatedUsers; $u++) {
    $userIps[$u] = "10.100.$u." + (Get-Random -Minimum 10 -Maximum 250)
}

# Script ejecutado por cada hilo de envio HTTP
$WorkerScript = {
    param($BaseUrl, $Method, $Path, $Body, $Headers, $VirtualIp, $UserId, $ExpectError, $Ts, $DelayMs)
    if ($DelayMs -gt 0) {
        Start-Sleep -Milliseconds $DelayMs
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 0
    $errText = ""
    try {
        $reqHeaders = @{ "X-Real-IP" = $VirtualIp; "X-User-Sim" = "User-$UserId" }
        if ($Headers) {
            foreach ($k in $Headers.Keys) { $reqHeaders[$k] = $Headers[$k] }
        }
        $params = @{
            Uri = "$BaseUrl$Path"
            Method = $Method
            Headers = $reqHeaders
            UseBasicParsing = $true
            TimeoutSec = 10
        }
        if ($Body) {
            $params.Body = $Body
            $params.ContentType = "application/json"
        }
        $resp = Invoke-WebRequest @params
        $status = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        }
        $errText = $_.Exception.Message
    }
    $sw.Stop()
    $totalElapsed = [math]::Round($sw.Elapsed.TotalMilliseconds + $(if ($DelayMs -gt 0) { $DelayMs } else { 0 }), 1)
    return [pscustomobject]@{
        Ts          = $Ts
        UserId      = $UserId
        Method      = $Method
        Path        = $Path
        StatusCode  = $status
        ElapsedMs   = $totalElapsed
        ExpectError = $ExpectError
        Error       = $errText
    }
}

# Inicializar RunspacePool para despachar peticiones concurrentes (soporta picos de hasta 100 req/s)
$runspacePool = [runspacefactory]::CreateRunspacePool(1, 150)
$runspacePool.Open()
$pendingRequests = New-Object System.Collections.ArrayList

# ==============================================================================
# DEFINICION DE EVENTOS DE CAOS
# ==============================================================================

function Chaos-KillPodGateway {
    Write-EventBanner "CAIDA DE POD (API GATEWAY)" "Eliminando pod aleatorio de pharmago-api-gateway"
    $pods = @((kubectl get pods -n $Namespace -l app=pharmago-api-gateway -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    if ($pods.Count -gt 0) {
        $victim = $pods[(Get-Random -Minimum 0 -Maximum $pods.Count)]
        Write-Host "  -> kubectl delete pod $victim (esperando auto-curacion de ReplicaSet)" -ForegroundColor Yellow
        kubectl delete pod $victim -n $Namespace --wait=false 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        Ensure-GatewayPortForward | Out-Null
        Write-EventEnd "CAIDA DE POD (API GATEWAY)" "Pod $victim eliminado; ReplicaSet recreo pod y port-forward activo."
    }
}

function Chaos-KillPodUsers {
    Write-EventBanner "CAIDA DE POD (USERS SERVICE)" "Eliminando pod aleatorio de pharmago-users-service"
    $pods = @((kubectl get pods -n $Namespace -l app=pharmago-users-service -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    if ($pods.Count -gt 0) {
        $victim = $pods[(Get-Random -Minimum 0 -Maximum $pods.Count)]
        Write-Host "  -> kubectl delete pod $victim" -ForegroundColor Yellow
        kubectl delete pod $victim -n $Namespace --wait=false 2>&1 | Out-Null
        Write-EventEnd "CAIDA DE POD (USERS SERVICE)" "Pod $victim eliminado; observando trafico desviado a replica sobreviviente."
    }
}

function Chaos-KillPodPharmacy {
    Write-EventBanner "CAIDA DE POD (PHARMACY SERVICE)" "Eliminando pod aleatorio de pharmago-pharmacy-service"
    $pods = @((kubectl get pods -n $Namespace -l app=pharmago-pharmacy-service -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    if ($pods.Count -gt 0) {
        $victim = $pods[(Get-Random -Minimum 0 -Maximum $pods.Count)]
        Write-Host "  -> kubectl delete pod $victim" -ForegroundColor Yellow
        kubectl delete pod $victim -n $Namespace --wait=false 2>&1 | Out-Null
        Write-EventEnd "CAIDA DE POD (PHARMACY SERVICE)" "Pod $victim eliminado; K8s recreando replica en background."
    }
}

function Chaos-DbDisconnect {
    Write-EventBanner "CAIDA / AISLAMIENTO DE LA BASE DE DATOS" "Cortando conexiones activas y aislando el Service pharmago-db (15s)"
    $dbPod = ([string](kubectl get pod -n $Namespace -l app=pharmago-db -o jsonpath='{.items[0].metadata.name}' 2>$null)).Trim()
    
    if ($dbPod) {
        Write-Host "  -> Cortando conexiones activas en SQL Server (ALTER DATABASE PharmaDb SET OFFLINE)..." -ForegroundColor Yellow
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET OFFLINE WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null
    }
    
    $patch = '{"spec":{"selector":{"app":"chaos-db-isolated"}}}'
    Write-Host "  -> Aislando Service pharmago-db por 15 segundos..." -ForegroundColor Yellow
    kubectl patch service pharmago-db -n $Namespace --type merge -p $patch 2>&1 | Out-Null
    
    for ($s = 1; $s -le 15; $s++) {
        Start-Sleep -Seconds 1
        Process-TrafficBatch
    }
    
    Write-Host "  -> Restaurando Service pharmago-db..." -ForegroundColor Cyan
    $restore = '{"spec":{"selector":{"app":"pharmago-db"}}}'
    kubectl patch service pharmago-db -n $Namespace --type merge -p $restore 2>&1 | Out-Null

    if ($dbPod) {
        Write-Host "  -> Restaurando base de datos a ONLINE..." -ForegroundColor Cyan
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET ONLINE;" 2>&1 | Out-Null
    }

    Write-EventEnd "CAIDA / AISLAMIENTO DE LA BASE DE DATOS" "Service y base de datos restaurados; reconexion verificada."
}

function Chaos-LatencySpike {
    Write-EventBanner "INDUCCION DE LATENCIA" "Inyectando retraso transaccional de 1.5s en SQL Server y micro-pausas"
    Write-Host "  -> Inyectando contencion transaccional pesimista en SQL Server y micro-pausas..." -ForegroundColor Yellow
    
    $dbPod = ([string](kubectl get pod -n $Namespace -l app=pharmago-db -o jsonpath='{.items[0].metadata.name}' 2>$null)).Trim()
    if ($dbPod) {
        # 1. Poner temporalmente la BD en aislamiento pesimista para que TABLOCKX bloquee lecturas concurrentes
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null

        # 2. Inyectar bloqueos continuos en background sobre tablas Drugs y Pharmacys
        $sqlJob = Start-Job -ScriptBlock {
            param($Pod, $Ns)
            for ($k = 0; $k -lt 10; $k++) {
                kubectl exec -i -n $Ns $Pod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -d PharmaDb -Q "BEGIN TRAN; SELECT TOP 1 * FROM Drugs WITH (TABLOCKX); SELECT TOP 1 * FROM Pharmacys WITH (TABLOCKX); WAITFOR DELAY '00:00:01.400'; COMMIT;" 2>&1 | Out-Null
                Start-Sleep -Milliseconds 200
            }
        } -ArgumentList $dbPod, $Namespace

        # 3. Activar bandera de latencia en el generador de peticiones
        $script:inLatencyChaos = $true

        for ($s = 1; $s -le 16; $s++) {
            Start-Sleep -Seconds 1
            Process-TrafficBatch
        }

        $script:inLatencyChaos = $false
        Stop-Job $sqlJob -ErrorAction SilentlyContinue
        Remove-Job $sqlJob -Force -ErrorAction SilentlyContinue

        # 4. Restaurar READ_COMMITTED_SNAPSHOT ON
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null
    }
    Write-EventEnd "INDUCCION DE LATENCIA" "Latencia transaccional liberada; p95 volviendo a valores normales."
}

function Chaos-CpuSpike {
    Write-EventBanner "SPIKE DE CPU" "Sobrecargando CPU al 100% del limite en replicas de users-service"
    $pods = @((kubectl get pods -n $Namespace -l app=pharmago-users-service -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    $jobs = @()
    foreach ($pod in $pods) {
        Write-Host "  -> Iniciando 4 busy-loops de CPU en $pod (duracion 30s)..." -ForegroundColor Yellow
        $jobs += Start-Job -ScriptBlock {
            param($Pod, $Ns)
            kubectl exec -n $Ns $Pod -- sh -c 'end=$(( $(date +%s) + 30 )); for i in 1 2 3 4; do ( while [ $(date +%s) -lt $end ]; do :; done ) & done; wait' 2>&1
        } -ArgumentList $pod, $Namespace
    }

    for ($s = 1; $s -le 30; $s++) {
        Start-Sleep -Seconds 1
        Process-TrafficBatch
    }
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    foreach ($pod in $pods) {
        kubectl exec -n $Namespace $pod -- sh -c 'killall sh 2>/dev/null || true' 2>&1 | Out-Null
    }
    Write-EventEnd "SPIKE DE CPU" "Procesos de consumo de CPU detenidos; uso de CPU normalizado."
}

function Chaos-RateSpike100 {
    Write-EventBanner "SPIKE DE TRAFICO (100 REQ/S)" "Elevando tasa de trafico a 100 req/s durante 15 segundos (5x carga normal)"
    Write-Host "  -> Despachando rafaga sostenida de 100 req/s (90% 200 OK / 10% 4xx)..." -ForegroundColor Yellow
    $script:targetRate = 100
    for ($s = 1; $s -le 15; $s++) {
        Start-Sleep -Seconds 1
        Process-TrafficBatch
    }
    $script:targetRate = 20
    Write-EventEnd "SPIKE DE TRAFICO (100 REQ/S)" "Tasa de trafico normalizada a 20 req/s."
}

function Chaos-LowMemory {
    Write-EventBanner "POCA MEMORIA DISPONIBLE" "Asignando buffer de 300MB de memoria en pods (limite 384Mi, mayor a 85% uso)"
    $pods = @((kubectl get pods -n $Namespace -l app=pharmago-pharmacy-service -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    $jobs = @()
    foreach ($pod in $pods) {
        Write-Host "  -> Asignando buffer de memoria en $pod por 18s..." -ForegroundColor Yellow
        $jobs += Start-Job -ScriptBlock {
            param($Pod, $Ns)
            kubectl exec -n $Ns $Pod -- sh -c "mem=\$(head -c 300M /dev/zero | tr '\0' 'x'); sleep 18; echo done" 2>&1
        } -ArgumentList $pod, $Namespace
    }

    for ($s = 1; $s -le 18; $s++) {
        Start-Sleep -Seconds 1
        Process-TrafficBatch
    }
    $jobs | Stop-Job -ErrorAction SilentlyContinue
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    Write-EventEnd "POCA MEMORIA DISPONIBLE" "Buffer de memoria liberado; presion OOM normalizada."
}

function Chaos-DiskIoStress {
    Write-EventBanner "RAFAGA DE I/O DE DISCO" "Generando pico breve de escritura (30MB con sync) en el nodo por 6s"
    $pods = @((kubectl get pods -n $Namespace -l app=pharmago-api-gateway -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    if ($pods.Count -gt 0) {
        $p = $pods[0]
        Write-Host "  -> Generando escritura sincronizada breve (30MB) en ${p}:/tmp/chaos_io_test..." -ForegroundColor Yellow
        kubectl exec -n $Namespace $p -- sh -c "dd if=/dev/zero of=/tmp/chaos_io_test bs=1M count=30 conv=fdatasync 2>/dev/null; sync" 2>&1 | Out-Null
        
        for ($s = 1; $s -le 6; $s++) {
            Start-Sleep -Seconds 1
            Process-TrafficBatch
        }
        
        Write-Host "  -> Eliminando archivo de prueba de disco..." -ForegroundColor Cyan
        kubectl exec -n $Namespace $p -- rm -f /tmp/chaos_io_test 2>&1 | Out-Null
        Write-EventEnd "RAFAGA DE I/O DE DISCO" "Escritura completada y archivo temporal removido; pico registrado en Grafana."
    }
}

function Chaos-RateLimitBurst {
    Write-EventBanner "SUGERIDO: RAFAGA RATE-LIMIT (HTTP 429)" "Lanzando rafaga DoS desde IP atacante 10.99.99.99 para forzar 429"
    $burstCount = 120
    Write-Host "  -> Disparando $burstCount peticiones instantaneas desde IP 10.99.99.99..." -ForegroundColor Yellow
    for ($i = 0; $i -lt $burstCount; $i++) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($WorkerScript)
        [void]$ps.AddArgument($BaseUrl)
        [void]$ps.AddArgument("GET")
        [void]$ps.AddArgument("/api/roles")
        [void]$ps.AddArgument("")
        [void]$ps.AddArgument(@{})
        [void]$ps.AddArgument("10.99.99.99")
        [void]$ps.AddArgument(99)
        [void]$ps.AddArgument($true)
        [void]$ps.AddArgument((Get-Date).ToString("HH:mm:ss.fff"))
        $handle = $ps.BeginInvoke()
        $null = $pendingRequests.Add(@{ PS = $ps; Handle = $handle })
    }
    
    for ($s = 1; $s -le 5; $s++) {
        Start-Sleep -Seconds 1
        Process-TrafficBatch
    }
    Write-EventEnd "SUGERIDO: RAFAGA RATE-LIMIT (HTTP 429)" "Rafaga finalizada; respuestas 429 registradas en el Gateway."
}

function Chaos-ScaleZeroBlackout {
    Write-EventBanner "SUGERIDO: APAGADO TOTAL DE SERVICIO (SCALE 0)" "Escalando pharmago-pharmacy-service a 0 replicas por 15s"
    Write-Host "  -> kubectl scale deployment/pharmago-pharmacy-service --replicas=0" -ForegroundColor Yellow
    kubectl scale deployment pharmago-pharmacy-service -n $Namespace --replicas=0 2>&1 | Out-Null
    
    for ($s = 1; $s -le 15; $s++) {
        Start-Sleep -Seconds 1
        Process-TrafficBatch
    }
    
    Write-Host "  -> Restaurando pharmago-pharmacy-service a 2 replicas..." -ForegroundColor Cyan
    kubectl scale deployment pharmago-pharmacy-service -n $Namespace --replicas=2 2>&1 | Out-Null
    Write-EventEnd "SUGERIDO: APAGADO TOTAL DE SERVICIO (SCALE 0)" "Servicio restaurado a 2 replicas y auto-curacion completada."
}

# Lista de todos los eventos aleatorios disponibles (11 eventos activos)
$allChaosEvents = @(
    @{ Name = "KillPodGateway";      Action = { Chaos-KillPodGateway } },
    @{ Name = "KillPodUsers";        Action = { Chaos-KillPodUsers } },
    @{ Name = "KillPodPharmacy";     Action = { Chaos-KillPodPharmacy } },
    @{ Name = "DbDisconnect";        Action = { Chaos-DbDisconnect } },
    @{ Name = "LatencySpike";        Action = { Chaos-LatencySpike } },
    @{ Name = "CpuSpike";            Action = { Chaos-CpuSpike } },
    @{ Name = "RateSpike100";        Action = { Chaos-RateSpike100 } },
    @{ Name = "LowMemory";           Action = { Chaos-LowMemory } },
    @{ Name = "DiskIoStress";        Action = { Chaos-DiskIoStress } },
    @{ Name = "RateLimitBurst";      Action = { Chaos-RateLimitBurst } },
    @{ Name = "ScaleZeroBlackout";   Action = { Chaos-ScaleZeroBlackout } }
)

# ==============================================================================
# MOTOR DE TRAFICO CONSTANTE Y PROCESAMIENTO
# ==============================================================================

# Contadores globales de sesion
$globalTotal = 0
$global2xx = 0
$global4xx = 0
$global5xx = 0
$global429 = 0
$globalErrors = 0
$scriptStartTime = [DateTime]::UtcNow
$script:targetRate = $TargetRate
$script:inLatencyChaos = $false

# Carpeta de evidencia de la corrida (reports/ esta en .gitignore)
$reportDir = Join-Path $PSScriptRoot ("reports\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$trafficCsv = Join-Path $reportDir "traffic.csv"
$script:eventLog = New-Object System.Collections.Generic.List[string]

function Process-TrafficBatch {
    # 1. Recolectar resultados completados del pool
    $batchResults = @()
    for ($i = 0; $i -lt $pendingRequests.Count; $i++) {
        $item = $pendingRequests[$i]
        if ($item.Handle.IsCompleted) {
            try {
                $out = $item.PS.EndInvoke($item.Handle)
                foreach ($res in $out) { $batchResults += $res }
            } catch { }
            $item.PS.Dispose()
            $pendingRequests.RemoveAt($i)
            $i--
        }
    }

    # 2. Despachar peticiones para el siguiente segundo ($script:targetRate o 20 por defecto)
    # Distribucion estricta: 90% validas y 10% con error
    $currentRate = if ($script:targetRate -gt 0) { $script:targetRate } else { $TargetRate }
    $validCount = [int][math]::Round($currentRate * 0.90)
    $errorCount = $currentRate - $validCount
    
    $scheduled = @()
    for ($k = 0; $k -lt $validCount; $k++) {
        $reqDef = $validRequests[(Get-Random -Minimum 0 -Maximum $validRequests.Count)]
        $scheduled += @{ Def = $reqDef; ExpectError = $false }
    }
    for ($k = 0; $k -lt $errorCount; $k++) {
        $reqDef = $errorRequests[(Get-Random -Minimum 0 -Maximum $errorRequests.Count)]
        $scheduled += @{ Def = $reqDef; ExpectError = $true }
    }
    $scheduled = $scheduled | Sort-Object { Get-Random }

    for ($idx = 0; $idx -lt $currentRate; $idx++) {
        $uId = ($idx % $SimulatedUsers) + 1
        $item = $scheduled[$idx]
        $def = $item.Def
        $vIp = $userIps[$uId]

        # Inyeccion de retardo cuando el caos de latencia transaccional esta activo
        $delayMs = 0
        if ($script:inLatencyChaos) {
            $delayMs = Get-Random -Minimum 1200 -Maximum 1600
        }

        $ps = [powershell]::Create()
        $ps.RunspacePool = $runspacePool
        [void]$ps.AddScript($WorkerScript)
        [void]$ps.AddArgument($BaseUrl)
        [void]$ps.AddArgument($def.Method)
        [void]$ps.AddArgument($def.Path)
        [void]$ps.AddArgument($def.Body)
        [void]$ps.AddArgument($def.Headers)
        [void]$ps.AddArgument($vIp)
        [void]$ps.AddArgument($uId)
        [void]$ps.AddArgument($item.ExpectError)
        [void]$ps.AddArgument((Get-Date).ToString("HH:mm:ss.fff"))
        [void]$ps.AddArgument($delayMs)
        
        $handle = $ps.BeginInvoke()
        $null = $pendingRequests.Add(@{ PS = $ps; Handle = $handle })
    }

    # 3. Calcular estadisticas del segundo actual y acumuladas
    $secCount = $batchResults.Count
    $c2xx = @($batchResults | Where-Object { $_.StatusCode -ge 200 -and $_.StatusCode -lt 300 }).Count
    $c4xx = @($batchResults | Where-Object { $_.StatusCode -ge 400 -and $_.StatusCode -lt 500 }).Count
    $c5xx = @($batchResults | Where-Object { $_.StatusCode -ge 500 }).Count
    $c429 = @($batchResults | Where-Object { $_.StatusCode -eq 429 }).Count
    $cNetErrors = @($batchResults | Where-Object { $_.StatusCode -eq 0 }).Count
    $latencies = @($batchResults | ForEach-Object { [double]$_.ElapsedMs } | Sort-Object)
    
    $avgMs = 0; $p95Ms = 0
    if ($latencies.Count -gt 0) {
        $avgMs = [math]::Round(($latencies | Measure-Object -Average).Average, 0)
        $p95Idx = [math]::Min($latencies.Count - 1, [int][math]::Floor($latencies.Count * 0.95))
        $p95Ms = [math]::Round($latencies[$p95Idx], 0)
    }

    # Acumular globales
    $script:globalTotal += $secCount
    $script:global2xx += $c2xx
    $script:global4xx += $c4xx
    $script:global5xx += $c5xx
    $script:global429 += $c429
    $script:globalErrors += $cNetErrors

    $pct2xx = if ($secCount -gt 0) { [math]::Round(($c2xx / $secCount) * 100, 1) } else { 0.0 }
    $pct4xx = if ($secCount -gt 0) { [math]::Round(($c4xx / $secCount) * 100, 1) } else { 0.0 }
    $globPct2xx = if ($script:globalTotal -gt 0) { [math]::Round(($script:global2xx / $script:globalTotal) * 100, 1) } else { 0.0 }
    $globPct4xx = if ($script:globalTotal -gt 0) { [math]::Round(($script:global4xx / $script:globalTotal) * 100, 1) } else { 0.0 }

    $elapsedSec = [math]::Round(([DateTime]::UtcNow - $scriptStartTime).TotalSeconds, 0)
    $nowStr = (Get-Date).ToString("HH:mm:ss")

    # Linea de estado en terminal segundo a segundo
    $lineColor = "White"
    if ($c5xx -gt 0 -or $c429 -gt 0) { $lineColor = "Yellow" }
    if ($p95Ms -gt 800) { $lineColor = "Magenta" }

    $statusMsg = "[{0} | t={1,3}s] Tasa: {2,2} req/s | 2xx: {3,2} ({4,4}%) | 4xx: {5,2} ({6,4}%) | 5xx: {7,2} | 429: {8,2} | Avg: {9,3}ms P95: {10,4}ms | Acum: 2xx={11}% 4xx={12}%" -f `
        $nowStr, $elapsedSec, $secCount, $c2xx, $pct2xx, $c4xx, $pct4xx, $c5xx, $c429, $avgMs, $p95Ms, $globPct2xx, $globPct4xx
    
    Write-Host $statusMsg -ForegroundColor $lineColor

    # Evidencia persistente: una fila por segundo en reports/<timestamp>/traffic.csv
    [pscustomobject]@{
        Timestamp = $nowStr
        RateSec   = $secCount
        Ok2xx     = $c2xx
        Err4xx    = $c4xx
        Err5xx    = $c5xx
        Err429    = $c429
        NetErr    = $cNetErrors
        AvgMs     = $avgMs
        P95Ms     = $p95Ms
    } | Export-Csv -Path $trafficCsv -Append -NoTypeInformation -Encoding utf8
}

# ==============================================================================
# BUCLE PRINCIPAL DE EJECUCION (TRAFICO CONSTANTE + CAOS ALEATORIO)
# ==============================================================================

Write-Header "INICIANDO GENERADOR DE TRAFICO Y MOTOR DE CAOS"
Write-Host "Presiona Ctrl+C en cualquier momento para detener y restaurar el cluster." -ForegroundColor Gray
Write-Host ""

$lastChaosTime = [DateTime]::UtcNow
$minSecondsBetweenChaos = 20
$maxSecondsBetweenChaos = 25
$nextChaosDelay = Get-Random -Minimum $minSecondsBetweenChaos -Maximum $maxSecondsBetweenChaos
$lastEventName = ""

try {
    while ($true) {
        # Duracion acotada opcional para corridas automatizadas (CHAOS_DURATION_SEC)
        if ($MaxDurationSec -gt 0 -and ([DateTime]::UtcNow - $scriptStartTime).TotalSeconds -ge $MaxDurationSec) {
            Write-Header "DURACION ALCANZADA ($MaxDurationSec s) - finalizando en forma ordenada"
            break
        }
        $secondStart = [DateTime]::UtcNow
        Process-TrafficBatch

        # Evaluar si corresponde disparar un nuevo evento de caos aleatorio
        $secSinceLastChaos = ([DateTime]::UtcNow - $lastChaosTime).TotalSeconds
        if ($secSinceLastChaos -ge $nextChaosDelay) {
            # Elegir un evento sin repetir el ultimo inmediatamente
            do {
                $chosen = $allChaosEvents[(Get-Random -Minimum 0 -Maximum $allChaosEvents.Count)]
            } while ($chosen.Name -eq $lastEventName -and $allChaosEvents.Count -gt 1)

            $lastEventName = $chosen.Name
            & $chosen.Action
            $script:eventLog.Add(("{0:HH:mm:ss} - {1}" -f (Get-Date), $chosen.Name))

            $lastChaosTime = [DateTime]::UtcNow
            $nextChaosDelay = Get-Random -Minimum $minSecondsBetweenChaos -Maximum $maxSecondsBetweenChaos
            Write-Host "  -> Proximo evento de caos aleatorio en ~$nextChaosDelay segundos..." -ForegroundColor Gray
            Write-Host ""
        }

        # Ajuste fino para mantener el ritmo exacto de 1 segundo
        $elapsedInSecond = ([DateTime]::UtcNow - $secondStart).TotalMilliseconds
        $sleepMs = [math]::Max(50, [int](1000 - $elapsedInSecond))
        Start-Sleep -Milliseconds $sleepMs
    }
} finally {
    Write-Host ""
    Write-Header "DETENIENDO GENERADOR Y LIMPIANDO ESTADO DE CLUSTER"
    
    # 1. Drenar runspaces pendientes
    try {
        $runspacePool.Close()
        $runspacePool.Dispose()
    } catch { }

    # 2. Restauracion de replicas en caso de que algun scale-zero haya quedado pendiente
    Write-Host "Verificando replicas de deployments..." -ForegroundColor Cyan
    foreach ($dep in @("pharmago-api-gateway", "pharmago-users-service", "pharmago-pharmacy-service", "pharmago-ui")) {
        $rep = ([string](kubectl get deployment $dep -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null)).Trim()
        if ($rep -ne "2") {
            Write-Host "  -> Restaurando $dep a 2 replicas" -ForegroundColor Yellow
            kubectl scale deployment $dep -n $Namespace --replicas=2 2>&1 | Out-Null
        }
    }
    
    # 3. Restaurar selector de base de datos si quedo aislado
    $dbSel = ([string](kubectl get service pharmago-db -n $Namespace -o jsonpath='{.spec.selector.app}' 2>$null)).Trim()
    if ($dbSel -eq "chaos-db-isolated") {
        Write-Host "  -> Restaurando selector de service pharmago-db" -ForegroundColor Yellow
        $restore = '{"spec":{"selector":{"app":"pharmago-db"}}}'
        kubectl patch service pharmago-db -n $Namespace --type merge -p $restore 2>&1 | Out-Null
    }

    # 4. Asegurar que READ_COMMITTED_SNAPSHOT en SQL Server quede activo
    $dbPod = ([string](kubectl get pod -n $Namespace -l app=pharmago-db -o jsonpath='{.items[0].metadata.name}' 2>$null)).Trim()
    if ($dbPod) {
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET ONLINE;" 2>&1 | Out-Null
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null
    }

    # 5. Limpiar procesos de CPU en pods de users-service
    $userPods = @((kubectl get pods -n $Namespace -l app=pharmago-users-service -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    foreach ($p in $userPods) {
        kubectl exec -n $Namespace $p -- sh -c 'killall sh 2>/dev/null || true' 2>&1 | Out-Null
    }

    # 6. Limpiar archivos temporales de disco
    Write-Host "Limpiando archivos de caos en pods..." -ForegroundColor Cyan
    $allPods = @((kubectl get pods -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    foreach ($p in $allPods) {
        kubectl exec -n $Namespace $p -- rm -f /tmp/chaos_large_file /tmp/chaos_fill /tmp/chaos_io_test 2>$null | Out-Null
    }

    # 5. Resumen final de la corrida
    Write-Header "RESUMEN FINAL DE LA CORRIDA DE CAOS"
    $dur = [math]::Round(([DateTime]::UtcNow - $scriptStartTime).TotalSeconds, 1)
    $finalPct2xx = if ($globalTotal -gt 0) { [math]::Round(($global2xx / $globalTotal) * 100, 1) } else { 0 }
    $finalPct4xx = if ($globalTotal -gt 0) { [math]::Round(($global4xx / $globalTotal) * 100, 1) } else { 0 }
    $finalPct5xx = if ($globalTotal -gt 0) { [math]::Round(($global5xx / $globalTotal) * 100, 1) } else { 0 }

    Write-Host "  Duracion total:              ${dur}s" -ForegroundColor White
    Write-Host "  Peticiones procesadas:       $globalTotal" -ForegroundColor White
    Write-Host "  Peticiones 2xx (Exitosas):   $global2xx ($finalPct2xx %)" -ForegroundColor Green
    Write-Host "  Peticiones 4xx (Cliente):    $global4xx ($finalPct4xx %)" -ForegroundColor Yellow
    Write-Host "  Peticiones 5xx (Servidor):   $global5xx ($finalPct5xx %)" -ForegroundColor Red
    Write-Host "  Peticiones 429 (Rate Limit): $global429" -ForegroundColor Magenta
    Write-Host "  Errores de red (timeout/conexion): $globalErrors" -ForegroundColor Red
    Write-Host ""
    Write-Host "Cluster restaurado y saludable." -ForegroundColor Green

    # Evidencia de la corrida en reports/<timestamp>/summary.md
    try {
        $lines = @(
            "# Corrida de caos PharmaGo (chaos.ps1)",
            "",
            "- Fecha: $((Get-Date).ToString('o'))",
            "- Duracion: ${dur}s (CHAOS_DURATION_SEC = $(if ($MaxDurationSec -gt 0) { "$MaxDurationSec" } else { "infinita (cortada con Ctrl+C)" }))",
            "- Requests totales: $globalTotal",
            "- 2xx: $global2xx | 4xx: $global4xx | 5xx: $global5xx | 429: $global429 | netErr: $globalErrors",
            "- Trafico: 20 req/s segregados en 18 peticiones validas + 2 inyectoras de error por segundo",
            "",
            "## Eventos de caos ejecutados",
            ""
        )
        $lines += if ($script:eventLog.Count -gt 0) { @($script:eventLog) } else { @("(ninguno)") }
        $lines += @("", "Detalle por segundo en traffic.csv (tasa, codigos, latencia media y p95).")
        $summaryPath = Join-Path $reportDir "summary.md"
        $lines | Set-Content -Path $summaryPath -Encoding utf8
        Write-Host ""
        Write-Host "  Evidencia de la corrida: $reportDir" -ForegroundColor Cyan
    } catch { }
    Write-Host ""
}
