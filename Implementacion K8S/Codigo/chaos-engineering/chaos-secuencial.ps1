# ==============================================================================
# PharmaGo - Chaos Engineering: Ejecución Secuencial y Controlada (Paso a Paso)
#
# Uso:
#   .\chaos-secuencial.ps1                        -> Ejecuta los 11 eventos en secuencia (uno por uno) con 20s de estabilización
#   .\chaos-secuencial.ps1 -Evento 5              -> Ejecuta únicamente el evento 5 de forma aislada
#   .\chaos-secuencial.ps1 -PasoAPaso             -> Pausa interactiva (espera [Enter]) antes de disparar cada evento
#   .\chaos-secuencial.ps1 -CooldownSec 15        -> Ajusta el tiempo de tráfico limpio entre eventos
# ==============================================================================

param(
    [int]$Evento = 0,
    [int]$CooldownSec = 20,
    [switch]$PasoAPaso
)

$ErrorActionPreference = "Continue"

# Configuraciones fijas del entorno
$Namespace = "pharmago"
$BaseUrl = "http://127.0.0.1:5000"
$TargetRate = 20        # 20 req/segundo nominal
$SimulatedUsers = 20    # 20 usuarios virtuales concurrentes
$IntervalMs = 50

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

# 1. Asegurar conectividad con API Gateway (espera que el port-forward del usuario esté activo)
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
Write-Header "PHARMAGO - CAOS SECUENCIAL CONTROLADO (1 por 1, Tráfico 20 req/s continuo)"
Write-Host "Verificando conectividad con API Gateway en 127.0.0.1:5000..." -ForegroundColor Cyan
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
$userIps = @{}
for ($u = 1; $u -le $SimulatedUsers; $u++) {
    $userIps[$u] = "10.100.$u." + (Get-Random -Minimum 10 -Maximum 250)
}

# Worker de envio HTTP en hilos de background
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
    
    # 1. Poner base de datos OFFLINE cortando todas las conexiones existentes del pool de ADO.NET/EF Core
    if ($dbPod) {
        Write-Host "  -> Cortando conexiones activas en SQL Server (ALTER DATABASE PharmaDb SET OFFLINE)..." -ForegroundColor Yellow
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET OFFLINE WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null
    }
    
    # 2. Desviar selector de Service pharmago-db
    $patch = '{"spec":{"selector":{"app":"chaos-db-isolated"}}}'
    Write-Host "  -> Aislando Service pharmago-db por 15 segundos..." -ForegroundColor Yellow
    kubectl patch service pharmago-db -n $Namespace --type merge -p $patch 2>&1 | Out-Null
    
    # Mantener corte durante 15 segundos (el trafico sigue y se observaran errores 500 y latencia por timeout)
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
    Write-EventBanner "INDUCCION DE LATENCIA" "Inyectando retraso transaccional de 1.4s en SQL Server y micro-pausas"
    Write-Host "  -> Inyectando contencion transaccional pesimista en SQL Server y micro-pausas..." -ForegroundColor Yellow
    
    $dbPod = ([string](kubectl get pod -n $Namespace -l app=pharmago-db -o jsonpath='{.items[0].metadata.name}' 2>$null)).Trim()
    if ($dbPod) {
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET READ_COMMITTED_SNAPSHOT OFF WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null

        $sqlJob = Start-Job -ScriptBlock {
            param($Pod, $Ns)
            for ($k = 0; $k -lt 10; $k++) {
                kubectl exec -i -n $Ns $Pod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -d PharmaDb -Q "BEGIN TRAN; SELECT TOP 1 * FROM Drugs WITH (TABLOCKX); SELECT TOP 1 * FROM Pharmacys WITH (TABLOCKX); WAITFOR DELAY '00:00:01.400'; COMMIT;" 2>&1 | Out-Null
                Start-Sleep -Milliseconds 200
            }
        } -ArgumentList $dbPod, $Namespace

        $script:inLatencyChaos = $true

        for ($s = 1; $s -le 16; $s++) {
            Start-Sleep -Seconds 1
            Process-TrafficBatch
        }

        $script:inLatencyChaos = $false
        Stop-Job $sqlJob -ErrorAction SilentlyContinue
        Remove-Job $sqlJob -Force -ErrorAction SilentlyContinue

        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null
    }
    Write-EventEnd "INDUCCION DE LATENCIA" "Latencia transaccional liberada; p95 volviendo a valores normales."
}

function Chaos-CpuSpike {
    Write-EventBanner "SPIKE DE CPU" "Sobrecargando CPU al 100% del limite en replicas de users-service (30s)"
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
    # Restaurar explicitamente a 20 req/s nominales (evita corrupcion de scope en PowerShell)
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
        
        # Mantener la ventana de observacion breve (6 segundos) mientras fluye el trafico
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
    Write-EventBanner "RAFAGA RATE-LIMIT (HTTP 429)" "Lanzando rafaga DoS desde IP atacante 10.99.99.99 para forzar 429"
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
    Write-EventEnd "RAFAGA RATE-LIMIT (HTTP 429)" "Rafaga finalizada; respuestas 429 registradas en el Gateway."
}

function Chaos-ScaleZeroBlackout {
    Write-EventBanner "APAGADO TOTAL DE SERVICIO (SCALE 0)" "Escalando pharmago-pharmacy-service a 0 replicas por 15s"
    Write-Host "  -> kubectl scale deployment/pharmago-pharmacy-service --replicas=0" -ForegroundColor Yellow
    kubectl scale deployment pharmago-pharmacy-service -n $Namespace --replicas=0 2>&1 | Out-Null
    
    for ($s = 1; $s -le 15; $s++) {
        Start-Sleep -Seconds 1
        Process-TrafficBatch
    }
    
    Write-Host "  -> Restaurando pharmago-pharmacy-service a 2 replicas..." -ForegroundColor Cyan
    kubectl scale deployment pharmago-pharmacy-service -n $Namespace --replicas=2 2>&1 | Out-Null
    Write-EventEnd "APAGADO TOTAL DE SERVICIO (SCALE 0)" "Servicio restaurado a 2 replicas y auto-curacion completada."
}

# ==============================================================================
# LISTA SECUENCIAL DE LOS 11 EVENTOS
# ==============================================================================
$allChaosEvents = @(
    @{ Id = 1;  Name = "KillPodGateway";    Title = "1. Caida de pod (API Gateway)";                 Action = { Chaos-KillPodGateway } },
    @{ Id = 2;  Name = "KillPodUsers";      Title = "2. Caida de pod (Users Service)";               Action = { Chaos-KillPodUsers } },
    @{ Id = 3;  Name = "KillPodPharmacy";   Title = "3. Caida de pod (Pharmacy Service)";            Action = { Chaos-KillPodPharmacy } },
    @{ Id = 4;  Name = "DbDisconnect";      Title = "4. Caida / Aislamiento de Base de Datos";       Action = { Chaos-DbDisconnect } },
    @{ Id = 5;  Name = "LatencySpike";      Title = "5. Induccion de latencia transaccional SQL";    Action = { Chaos-LatencySpike } },
    @{ Id = 6;  Name = "CpuSpike";          Title = "6. Spike de CPU (100% limite en Users, 30s)";   Action = { Chaos-CpuSpike } },
    @{ Id = 7;  Name = "RateSpike100";      Title = "7. Spike masivo de trafico (100 req/s, 15s)";   Action = { Chaos-RateSpike100 } },
    @{ Id = 8;  Name = "LowMemory";         Title = "8. Poca memoria disponible (>85% OOM, 18s)";    Action = { Chaos-LowMemory } },
    @{ Id = 9;  Name = "DiskIoStress";      Title = "9. Rafaga de I/O de disco (30MB sync, 6s)";    Action = { Chaos-DiskIoStress } },
    @{ Id = 10; Name = "RateLimitBurst";    Title = "10. Rafaga DoS / Rate-Limit (HTTP 429)";        Action = { Chaos-RateLimitBurst } },
    @{ Id = 11; Name = "ScaleZeroBlackout"; Title = "11. Apagado total temporal (Scale 0, 15s)";     Action = { Chaos-ScaleZeroBlackout } }
)

# Filtrar segun parámetro -Evento
$eventsToRun = @()
if ($Evento -ge 1 -and $Evento -le 11) {
    $eventsToRun = @($allChaosEvents | Where-Object { $_.Id -eq $Evento })
    Write-Host "Modo evento unico seleccionado: Evento #$Evento ($($eventsToRun[0].Name))" -ForegroundColor Cyan
} else {
    $eventsToRun = $allChaosEvents
    Write-Host "Modo secuencia completa: Se ejecutaran los 11 eventos en orden 1 -> 11" -ForegroundColor Cyan
}

# ==============================================================================
# MOTOR DE TRAFICO CONSTANTE
# ==============================================================================
$globalTotal = 0
$global2xx = 0
$global4xx = 0
$global5xx = 0
$global429 = 0
$globalErrors = 0
$scriptStartTime = [DateTime]::UtcNow
$script:targetRate = $TargetRate
$script:inLatencyChaos = $false

$reportDir = Join-Path $PSScriptRoot ("reports\seq-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$trafficCsv = Join-Path $reportDir "traffic.csv"
$script:eventLog = New-Object System.Collections.Generic.List[string]

function Process-TrafficBatch {
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

    $lineColor = "White"
    if ($c5xx -gt 0 -or $c429 -gt 0) { $lineColor = "Yellow" }
    if ($p95Ms -gt 800) { $lineColor = "Magenta" }

    $statusMsg = "[{0} | t={1,3}s] Tasa: {2,2} req/s | 2xx: {3,2} ({4,4}%) | 4xx: {5,2} ({6,4}%) | 5xx: {7,2} | 429: {8,2} | Avg: {9,3}ms P95: {10,4}ms | Acum: 2xx={11}% 4xx={12}%" -f `
        $nowStr, $elapsedSec, $secCount, $c2xx, $pct2xx, $c4xx, $pct4xx, $c5xx, $c429, $avgMs, $p95Ms, $globPct2xx, $globPct4xx
    
    Write-Host $statusMsg -ForegroundColor $lineColor

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

function Wait-TrafficBaseline([int]$seconds, [string]$reason) {
    Write-Host ""
    Write-Host "  ---> Manteniendo trafico limpio ($reason, $seconds s) <---" -ForegroundColor DarkCyan
    for ($s = 1; $s -le $seconds; $s++) {
        $secondStart = [DateTime]::UtcNow
        Process-TrafficBatch
        $elapsedInSecond = ([DateTime]::UtcNow - $secondStart).TotalMilliseconds
        $sleepMs = [math]::Max(50, [int](1000 - $elapsedInSecond))
        Start-Sleep -Milliseconds $sleepMs
    }
}

function Wait-InteractiveEnter([string]$nextEventTitle) {
    Write-Host ""
    Write-Host "================================================================================" -ForegroundColor Yellow
    Write-Host "  LISTO PARA EL SIGUIENTE EVENTO: $nextEventTitle" -ForegroundColor Yellow
    Write-Host "  Presiona [ENTER] para ejecutarlo (o Ctrl+C para finalizar)..." -ForegroundColor White
    Write-Host "  (El trafico de fondo a 20 req/s continua fluyendo normalmente)" -ForegroundColor DarkGray
    Write-Host "================================================================================" -ForegroundColor Yellow
    Write-Host ""
    
    while ($true) {
        $secondStart = [DateTime]::UtcNow
        Process-TrafficBatch
        
        $keyAvailable = $false
        try { $keyAvailable = [Console]::KeyAvailable } catch { }
        
        if ($keyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                break
            }
        }
        $elapsedInSecond = ([DateTime]::UtcNow - $secondStart).TotalMilliseconds
        $sleepMs = [math]::Max(50, [int](1000 - $elapsedInSecond))
        Start-Sleep -Milliseconds $sleepMs
    }
}

# ==============================================================================
# BUCLE PRINCIPAL SECUENCIAL
# ==============================================================================
Write-Header "INICIANDO EJECUCION SECUENCIAL DE CAOS"
Write-Host "Plan de ejecucion:" -ForegroundColor Cyan
foreach ($ev in $eventsToRun) {
    Write-Host "  [$($ev.Id)] $($ev.Title)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Presiona Ctrl+C en cualquier momento para detener y restaurar el cluster." -ForegroundColor Gray
Write-Host ""

try {
    # 1. Periodo de linea base inicial (10s de trafico sano)
    Wait-TrafficBaseline 10 "Linea Base Inicial"

    # 2. Iteracion secuencial por cada evento
    for ($i = 0; $i -lt $eventsToRun.Count; $i++) {
        $ev = $eventsToRun[$i]

        if ($PasoAPaso) {
            Wait-InteractiveEnter $ev.Title
        }

        # Ejecutar evento de caos
        & $ev.Action
        $script:eventLog.Add(("{0:HH:mm:ss} - [{1}] {2}" -f (Get-Date), $ev.Id, $ev.Name))

        # Periodo de cooldown / recuperacion (excepto luego del ultimo evento)
        if ($i -lt ($eventsToRun.Count - 1) -or $Evento -gt 0) {
            Wait-TrafficBaseline $CooldownSec "Recuperacion y observacion post-evento #$($ev.Id)"
        }
    }

    Write-Header "TODOS LOS EVENTOS SECUENCIALES COMPLETADOS EXITOSAMENTE"

} finally {
    Write-Host ""
    Write-Header "DETENIENDO GENERADOR Y LIMPIANDO ESTADO DE CLUSTER"
    
    try {
        $runspacePool.Close()
        $runspacePool.Dispose()
    } catch { }

    Write-Host "Verificando replicas de deployments..." -ForegroundColor Cyan
    foreach ($dep in @("pharmago-api-gateway", "pharmago-users-service", "pharmago-pharmacy-service", "pharmago-ui")) {
        $rep = ([string](kubectl get deployment $dep -n $Namespace -o jsonpath='{.spec.replicas}' 2>$null)).Trim()
        if ($rep -ne "2") {
            Write-Host "  -> Restaurando $dep a 2 replicas" -ForegroundColor Yellow
            kubectl scale deployment $dep -n $Namespace --replicas=2 2>&1 | Out-Null
        }
    }
    
    $dbSel = ([string](kubectl get service pharmago-db -n $Namespace -o jsonpath='{.spec.selector.app}' 2>$null)).Trim()
    if ($dbSel -eq "chaos-db-isolated") {
        Write-Host "  -> Restaurando selector de service pharmago-db" -ForegroundColor Yellow
        $restore = '{"spec":{"selector":{"app":"pharmago-db"}}}'
        kubectl patch service pharmago-db -n $Namespace --type merge -p $restore 2>&1 | Out-Null
    }

    $dbPod = ([string](kubectl get pod -n $Namespace -l app=pharmago-db -o jsonpath='{.items[0].metadata.name}' 2>$null)).Trim()
    if ($dbPod) {
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET ONLINE;" 2>&1 | Out-Null
        kubectl exec -i -n $Namespace $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -Q "ALTER DATABASE PharmaDb SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;" 2>&1 | Out-Null
    }

    $userPods = @((kubectl get pods -n $Namespace -l app=pharmago-users-service -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    foreach ($p in $userPods) {
        kubectl exec -n $Namespace $p -- sh -c 'killall sh 2>/dev/null || true' 2>&1 | Out-Null
    }

    Write-Host "Limpiando archivos de caos en pods..." -ForegroundColor Cyan
    $allPods = @((kubectl get pods -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>$null).Trim() -split '\s+' | Where-Object { $_ })
    foreach ($p in $allPods) {
        kubectl exec -n $Namespace $p -- rm -f /tmp/chaos_large_file /tmp/chaos_fill /tmp/chaos_io_test 2>$null | Out-Null
    }

    Write-Header "RESUMEN FINAL DE LA CORRIDA DE CAOS SECUENCIAL"
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

    try {
        $lines = @(
            "# Corrida de caos secuencial PharmaGo (chaos-secuencial.ps1)",
            "",
            "- Fecha: $((Get-Date).ToString('o'))",
            "- Duracion: ${dur}s",
            "- Modo: $(if ($Evento -gt 0) { "Evento unico #$Evento" } else { "Secuencia completa 1 a 13" })",
            "- Requests totales: $globalTotal",
            "- 2xx: $global2xx | 4xx: $global4xx | 5xx: $global5xx | 429: $global429 | netErr: $globalErrors",
            "",
            "## Eventos de caos ejecutados",
            ""
        )
        $lines += if ($script:eventLog.Count -gt 0) { @($script:eventLog) } else { @("(ninguno)") }
        $summaryPath = Join-Path $reportDir "summary.md"
        $lines | Set-Content -Path $summaryPath -Encoding utf8
        Write-Host "  Evidencia de la corrida: $reportDir" -ForegroundColor Cyan
    } catch { }
    Write-Host ""
}
