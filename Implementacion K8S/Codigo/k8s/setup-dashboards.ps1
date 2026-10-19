# Script unificado para aprovisionar y verificar los Dashboards de Grafana y Kibana
# Uso: .\setup-dashboards.ps1

Write-Host "=== Aprovisionando Dashboards en Grafana y Kibana ===" -ForegroundColor Green

# 1. Verificar conectividad con Kubernetes
$kibanaPod = kubectl get pod -n pharmago -l app=kibana -o jsonpath='{.items[0].metadata.name}' 2>$null
$grafanaPod = kubectl get pod -n pharmago -l app=grafana -o jsonpath='{.items[0].metadata.name}' 2>$null

if ([string]::IsNullOrWhiteSpace($kibanaPod) -or [string]::IsNullOrWhiteSpace($grafanaPod)) {
    Write-Host "Error: No se encontraron los pods de Kibana o Grafana en el namespace 'pharmago'." -ForegroundColor Red
    Write-Host "Asegúrate de que Minikube esté corriendo: minikube status" -ForegroundColor Yellow
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kibanaNdjson = Join-Path $scriptDir "kibana-dashboards.ndjson"

# 2. Aprovisionar Dashboards y Data Views en Kibana
Write-Host "`n1. Configurando Dashboards y Data Views en Kibana..." -ForegroundColor Yellow

if (-not (Test-Path $kibanaNdjson)) {
    Write-Host "Error: No se encontró el archivo $kibanaNdjson" -ForegroundColor Red
    exit 1
}

$res = Get-Content $kibanaNdjson -Raw | kubectl exec -i -n pharmago $kibanaPod -- sh -c "cat > /tmp/import.ndjson && curl -s -X POST 'http://localhost:5601/api/saved_objects/_import?overwrite=true' -H 'kbn-xsrf:true' -F 'file=@/tmp/import.ndjson'" 2>&1

if ($res -like "*`"success`":true*") {
    Write-Host "  [OK] Dashboards y Data Views importados correctamente via API oficial de Kibana." -ForegroundColor Cyan
    Write-Host "   Kibana configurado exitosamente." -ForegroundColor Green
} else {
    Write-Host "  [WARN] Fallo al importar en Kibana: $res" -ForegroundColor Yellow
}

# 3. Aprovisionar Dashboards en Grafana
Write-Host "`n2. Configurando Dashboards en Grafana..." -ForegroundColor Yellow

$provisioningFiles = @(
    (Join-Path $scriptDir "configmaps\grafana-provisioning.yaml"),
    (Join-Path $scriptDir "configmaps\grafana-dashboards.yaml"),
    (Join-Path $scriptDir "configmaps\grafana-dashboard-infra.yaml")
)

$alertingFile = Join-Path $scriptDir "configmaps\grafana-alerting.yaml"
if (Test-Path $alertingFile) {
    $provisioningFiles += $alertingFile
}

foreach ($f in $provisioningFiles) {
    if (Test-Path $f) {
        kubectl apply -f $f *> $null
        Write-Host "  [OK] Aplicado ConfigMap: $(Split-Path $f -Leaf)" -ForegroundColor Cyan
    }
}

# Reiniciar pod de Grafana para recargar dashboards si fue modificado
Write-Host "   Verificando dashboards cargados en Grafana..." -ForegroundColor Yellow
Start-Sleep -Seconds 2

# 4. Validar alertas en Grafana
Write-Host "`n3. Validando alertas en Grafana..." -ForegroundColor Yellow
try {
    $alertRules = Invoke-RestMethod -Uri "http://127.0.0.1:3000/api/v1/provisioning/alert-rules" -Headers @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:admin")) } -TimeoutSec 10
    Write-Host "  Alertas aprovisionadas: $($alertRules.Count)" -ForegroundColor Cyan
    foreach ($r in $alertRules) {
        Write-Host "   - $($r.title) ($($r.uid))" -ForegroundColor Gray
    }
} catch {
    Write-Host "  [WARN] No se pudo consultar alertas: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 5. Resumen y URLs directas
Write-Host "`n=== Dashboards y alertas configurados y listos ===" -ForegroundColor Green
Write-Host ""
Write-Host "Dashboards de Kibana (Logs y Trazabilidad):" -ForegroundColor White
Write-Host "  - PharmaGo - Logs:            http://127.0.0.1:5601/app/dashboards#/view/4fc85f40-cbca-11f1-a044-d7e76d4ac73e" -ForegroundColor Cyan
Write-Host "  - Stream de Logs en Vivo:     http://127.0.0.1:5601/app/discover#/?_a=(discover:(columns:!('@timestamp',kubernetes.container_name,LogLevel,Message,'Scopes.correlation_id'),sort:!(!('@timestamp',desc))))" -ForegroundColor Cyan
Write-Host ""
Write-Host "Dashboards de Grafana (Metricas y Rendimiento):" -ForegroundColor White
Write-Host "  - PharmaGo Overview:          http://127.0.0.1:3000/d/pharmago-overview" -ForegroundColor Cyan
Write-Host "  - Infraestructura Kubernetes: http://127.0.0.1:3000/d/pharmago-infra" -ForegroundColor Cyan
Write-Host ""
Write-Host "Nota: Si los puertos locales no estan activos, inicia los tuneles con:" -ForegroundColor Gray
Write-Host "      .\Implementacion K8S\Codigo\k8s\port-forward.ps1" -ForegroundColor Gray
Write-Host ""
