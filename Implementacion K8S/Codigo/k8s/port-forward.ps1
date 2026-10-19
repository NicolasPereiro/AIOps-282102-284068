param(
    [switch]$Stop
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $scriptDir ".port-forward.pids"

if ($Stop) {
    if (Test-Path $pidFile) {
        Write-Host "Deteniendo port-forwards..." -ForegroundColor Yellow
        $pids = Get-Content $pidFile
        foreach ($p in $pids) {
            $p = $p.Trim()
            if ($p) {
                Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
                Write-Host "  Detenido PID $p" -ForegroundColor Gray
            }
        }
        Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
        Write-Host "Listo." -ForegroundColor Green
    } else {
        Write-Host "No hay archivo de registro de port-forwards en ejecución." -ForegroundColor Yellow
    }
    exit 0
}

# Si ya había procesos previos registrados, detenerlos primero
if (Test-Path $pidFile) {
    $oldPids = Get-Content $pidFile
    foreach ($p in $oldPids) {
        $p = $p.Trim()
        if ($p) {
            Stop-Process -Id $p -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

Write-Host "=== Iniciando port-forwards en background ===" -ForegroundColor Green
Write-Host ""

$services = @(
    @{ Name = "Frontend";         Svc = "svc/pharmago-ui";               Port = "4200:80";    Url = "http://127.0.0.1:4200" },
    @{ Name = "API Gateway";      Svc = "svc/pharmago-api-gateway";      Port = "5000:80";    Url = "http://127.0.0.1:5000" },
    @{ Name = "Users Service";    Svc = "svc/pharmago-users-service";    Port = "5001:80";    Url = "http://127.0.0.1:5001" },
    @{ Name = "Pharmacy Service"; Svc = "svc/pharmago-pharmacy-service";  Port = "5002:80";    Url = "http://127.0.0.1:5002" },
    @{ Name = "SQL Server";       Svc = "svc/pharmago-db";              Port = "11433:1433"; Url = "127.0.0.1,11433 (sa / Str0ngP@ssword!)" },
    @{ Name = "Prometheus";       Svc = "svc/prometheus";               Port = "9090:9090";  Url = "http://127.0.0.1:9090" },
    @{ Name = "Grafana";          Svc = "svc/grafana";                  Port = "3000:3000";  Url = "http://127.0.0.1:3000 (admin/admin)" },
    @{ Name = "Kibana";           Svc = "svc/kibana";                   Port = "5601:5601";  Url = "http://127.0.0.1:5601" },
    @{ Name = "Elasticsearch";    Svc = "svc/elasticsearch";            Port = "9200:9200";  Url = "http://127.0.0.1:9200" }
)

$startedPids = @()

foreach ($item in $services) {
    $proc = Start-Process -FilePath "kubectl" -ArgumentList @("port-forward", $item.Svc, $item.Port, "-n", "pharmago") -PassThru -WindowStyle Hidden
    $startedPids += $proc.Id
    Write-Host ("  {0,-16} {1}" -f ($item.Name + ":"), $item.Url) -ForegroundColor Cyan
}

$startedPids | Set-Content $pidFile

Write-Host ""
Write-Host "Port-forwards activos. Para detener: .\port-forward.ps1 -Stop" -ForegroundColor Yellow
Write-Host ""
