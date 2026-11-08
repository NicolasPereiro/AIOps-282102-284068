# Script de despliegue para Kubernetes (Minikube)
# Uso: .\apply-k8s.ps1

Write-Host "=== Desplegando PharmaGo en Kubernetes ===" -ForegroundColor Green

# Verificar que kubectl está disponible
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Host "Error: kubectl no está instalado o no está en el PATH" -ForegroundColor Red
    exit 1
}

# Verificar que el cluster Kubernetes está accesible
$nodes = kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>&1
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($nodes)) {
    Write-Host "Error: No hay cluster Kubernetes accesible. Si usas Minikube: minikube start" -ForegroundColor Red
    exit 1
}

Write-Host "`n1. Validando y etiquetando el nodo..." -ForegroundColor Yellow
# Despliegue de un solo nodo: todos los componentes corren en el nodo
# `minikube`. El nodo se etiqueta workload=platform para anclar los
# PersistentVolumes y los componentes de plataforma. Los microservicios
# declaran afinidad blanda (preferred) hacia su label workload, por lo que
# la separación es declarativa y no bloquea el scheduling en el único nodo.
$node = "minikube"
kubectl get node $node *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: No se encontró el nodo $node. Ejecuta: minikube start --memory=6144 --cpus=4" -ForegroundColor Red
    exit 1
}
kubectl wait --for=condition=Ready "node/$node" --timeout=120s *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Error: El nodo $node no está Ready." -ForegroundColor Red
    exit 1
}

# La etiqueta workload ancla la plataforma y los PVs al nodo único.
kubectl label nodes minikube workload=platform --overwrite

# Elimina la etiqueta anterior para evitar que manifiestos viejos permitan
# programar componentes en cualquier nodo.
kubectl label nodes minikube node-type- 2>$null | Out-Null

Write-Host "   platform: minikube (nodo único)" -ForegroundColor Cyan
Write-Host "   Verificar: kubectl get nodes --show-labels" -ForegroundColor Gray

Write-Host "`n2. Creando namespace..." -ForegroundColor Yellow
kubectl apply -f namespace.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n3. Creando secrets..." -ForegroundColor Yellow
kubectl apply -f secrets\db-secret.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n4. Creando configmaps..." -ForegroundColor Yellow
kubectl apply -f configmaps\prometheus-config.yaml
kubectl apply -f configmaps\otel-collector-config.yaml
kubectl apply -f configmaps\grafana-provisioning.yaml
kubectl apply -f configmaps\grafana-dashboards.yaml
kubectl apply -f configmaps\grafana-dashboard-infra.yaml
kubectl apply -f configmaps\grafana-alerting.yaml
kubectl apply -f configmaps\fluent-bit-config.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n5. Creando StorageClass y PersistentVolumes..." -ForegroundColor Yellow
kubectl apply -f persistent-volumes\storage-class.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

# Eliminar solamente PVs huérfanos en estado Released/Failed para recrearlos.
# Los PVs Bound no deben eliminarse automáticamente porque contienen datos.
Write-Host "   Limpiando PVs existentes..." -ForegroundColor Cyan
foreach ($pv in @("sql-pv", "elasticsearch-pv", "prometheus-pv", "grafana-pv")) {
    $status = kubectl get pv $pv -o jsonpath='{.status.phase}' 2>$null
    if ($status -eq "Released" -or $status -eq "Failed") {
        kubectl delete pv $pv --ignore-not-found=true
    }
}
Start-Sleep -Seconds 2

kubectl apply -f persistent-volumes\sql-pv.yaml
kubectl apply -f persistent-volumes\elasticsearch-pv.yaml
kubectl apply -f persistent-volumes\prometheus-pv.yaml
kubectl apply -f persistent-volumes\grafana-pv.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n6. Desplegando base de datos..." -ForegroundColor Yellow
kubectl apply -f services\ops\db-service.yaml
kubectl apply -f deployments\ops\db-deployment.yaml
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n   Esperando a que la base de datos esté lista..." -ForegroundColor Yellow
$dbWait = kubectl wait --for=condition=Ready pod -l app=pharmago-db -n pharmago --timeout=300s 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "   Base de datos lista!" -ForegroundColor Green
} else {
    Write-Host "   Timeout esperando la base de datos. Continuando..." -ForegroundColor Yellow
    Write-Host "   $dbWait" -ForegroundColor Gray
}

Write-Host "`n7. Desplegando servicios de observabilidad..." -ForegroundColor Yellow
# Elasticsearch primero
kubectl apply -f services\ops\elasticsearch-service.yaml
kubectl apply -f deployments\ops\elasticsearch-deployment.yaml

# Esperar a que Elasticsearch esté listo
Write-Host "   Esperando a que Elasticsearch esté listo..." -ForegroundColor Yellow
$elasticsearchWait = kubectl wait --for=condition=Ready pod -l app=elasticsearch -n pharmago --timeout=300s 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "   Elasticsearch listo!" -ForegroundColor Green
} else {
    Write-Host "   Timeout esperando Elasticsearch. Continuando..." -ForegroundColor Yellow
    Write-Host "   $elasticsearchWait" -ForegroundColor Gray
}

# Resto de servicios ops
kubectl apply -f services\ops\otel-collector-service.yaml
kubectl apply -f deployments\ops\otel-collector-deployment.yaml

kubectl apply -f deployments\ops\prometheus-serviceaccount.yaml
kubectl apply -f deployments\ops\prometheus-clusterrole.yaml
kubectl apply -f deployments\ops\prometheus-clusterrolebinding.yaml
kubectl apply -f services\ops\prometheus-service.yaml
kubectl apply -f deployments\ops\prometheus-deployment.yaml
kubectl apply -f services\ops\node-exporter-service.yaml
kubectl apply -f deployments\ops\node-exporter-daemonset.yaml

kubectl apply -f services\ops\grafana-service.yaml
kubectl apply -f deployments\ops\grafana-deployment.yaml

kubectl apply -f services\ops\kibana-service.yaml
kubectl apply -f deployments\ops\kibana-deployment.yaml

kubectl apply -f deployments\ops\fluent-bit-serviceaccount.yaml
kubectl apply -f deployments\ops\fluent-bit-clusterrole.yaml
kubectl apply -f deployments\ops\fluent-bit-clusterrolebinding.yaml
kubectl apply -f deployments\ops\fluent-bit-daemonset.yaml

if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n8. Desplegando servicios backend..." -ForegroundColor Yellow
kubectl apply -f services\backend\users-service-service.yaml
kubectl apply -f deployments\backend\users-service-deployment.yaml

kubectl apply -f services\backend\pharmacy-service-service.yaml
kubectl apply -f deployments\backend\pharmacy-service-deployment.yaml

kubectl apply -f services\backend\api-gateway-service.yaml
kubectl apply -f deployments\backend\api-gateway-deployment.yaml

if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n9. Desplegando frontend..." -ForegroundColor Yellow
kubectl apply -f services\frontend\ui-service.yaml
kubectl apply -f deployments\frontend\ui-deployment.yaml

if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host "`n10. Inicializando base de datos con datos de prueba (seed-data.sql)..." -ForegroundColor Yellow
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$seedFile = Join-Path (Split-Path $scriptDir -Parent) "Backend\seed-data.sql"
if (Test-Path $seedFile) {
    Write-Host "   Esperando a que users-service complete migraciones de base de datos..." -ForegroundColor Cyan
    $null = kubectl wait --for=condition=Ready pod -l app=pharmago-users-service -n pharmago --timeout=120s 2>&1
    Start-Sleep -Seconds 2
    $dbPod = ([string](kubectl get pod -n pharmago -l app=pharmago-db -o jsonpath='{.items[0].metadata.name}' 2>$null)).Trim()
    if ($dbPod) {
        Get-Content $seedFile -Raw | kubectl exec -i -n pharmago $dbPod -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -d PharmaDb -i /dev/stdin 2>&1 | Out-Null
        Write-Host "   Datos iniciales cargados en la base de datos (admin, empleado01, owner001, etc.)" -ForegroundColor Green
    }
}

Write-Host "`n11. Configurando Dashboards y Data Views en Kibana..." -ForegroundColor Yellow
$kibanaFile = Join-Path $scriptDir "kibana-dashboards.ndjson"
if (Test-Path $kibanaFile) {
    Write-Host "   Esperando a que Kibana esté listo..." -ForegroundColor Cyan
    $null = kubectl wait --for=condition=Ready pod -l app=kibana -n pharmago --timeout=120s 2>&1
    $kibanaPod = ([string](kubectl get pod -n pharmago -l app=kibana -o jsonpath='{.items[0].metadata.name}' 2>$null)).Trim()
    if ($kibanaPod) {
        $importRes = Get-Content $kibanaFile -Raw | kubectl exec -i -n pharmago $kibanaPod -- sh -c "cat > /tmp/import.ndjson && curl -s -X POST 'http://localhost:5601/api/saved_objects/_import?overwrite=true' -H 'kbn-xsrf:true' -F 'file=@/tmp/import.ndjson'" 2>&1
        if ($importRes -like "*`"success`":true*") {
            Write-Host "   Dashboards y Data Views de Kibana importados correctamente." -ForegroundColor Green
        } else {
            Write-Host "   Aviso al importar en Kibana: $importRes" -ForegroundColor Yellow
        }
    }
}

Write-Host "`n=== Despliegue completado ===" -ForegroundColor Green
Write-Host "`nVerificando estado de los pods..." -ForegroundColor Yellow
kubectl get pods -n pharmago -o wide

Write-Host "`n=== Dashboards y Accesos Disponibles ===" -ForegroundColor Green
Write-Host ""
Write-Host "Aplicación y Gateway (via port-forward):" -ForegroundColor White
Write-Host "  - Frontend:                   http://127.0.0.1:4200" -ForegroundColor Cyan
Write-Host "  - API Gateway:                http://127.0.0.1:5000" -ForegroundColor Cyan
Write-Host ""
Write-Host "Dashboards de Grafana (Métricas y Rendimiento):" -ForegroundColor White
Write-Host "  - PharmaGo Overview:          http://127.0.0.1:3000/d/pharmago-overview" -ForegroundColor Cyan
Write-Host "  - Infraestructura Kubernetes: http://127.0.0.1:3000/d/pharmago-infra" -ForegroundColor Cyan
Write-Host ""
Write-Host "Dashboards de Kibana (Logs y Trazabilidad):" -ForegroundColor White
Write-Host "  - PharmaGo - Logs:            http://127.0.0.1:5601/app/dashboards#/view/4fc85f40-cbca-11f1-a044-d7e76d4ac73e" -ForegroundColor Cyan
Write-Host "  - Stream de Logs en Vivo:     http://127.0.0.1:5601/app/discover#/?_a=(discover:(columns:!('@timestamp',kubernetes.container_name,LogLevel,Message,'Scopes.correlation_id'),sort:!(!('@timestamp',desc))))" -ForegroundColor Cyan
Write-Host ""
Write-Host "Prometheus & Base de Datos:" -ForegroundColor White
Write-Host "  - Prometheus Targets:         http://127.0.0.1:9090" -ForegroundColor Cyan
Write-Host "  - SQL Server:                 127.0.0.1,11433 (sa / Str0ngP@ssword!)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Nota: Si los puertos locales no están activos, inicia los túneles con:" -ForegroundColor Gray
Write-Host "      .\port-forward.ps1" -ForegroundColor Gray
Write-Host ""

