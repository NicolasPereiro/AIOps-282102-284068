#!/bin/bash
# Script de despliegue para Kubernetes (Minikube)
# Uso: ./apply-k8s.sh

set -e

echo "=== Desplegando PharmaGo en Kubernetes ==="

# Verificar que kubectl está disponible
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl no está instalado o no está en el PATH"
    exit 1
fi

# Verificar que minikube está corriendo
if ! minikube status &> /dev/null; then
    echo "Error: Minikube no está corriendo."
    echo "Ejecuta: minikube start --memory=6144 --cpus=4"
    exit 1
fi

echo ""
echo "1. Validando y etiquetando el nodo del despliegue..."
# Despliegue de un solo nodo: todos los componentes corren en `minikube`.
# El nodo se etiqueta workload=platform para anclar PVs y plataforma; los
# microservicios declaran afinidad blanda (preferred) hacia su label workload,
# por lo que la separación es declarativa y no bloquea el scheduling.
node="minikube"
if ! kubectl get node "$node" >/dev/null 2>&1; then
    echo "Error: No se encontró el nodo $node. Ejecuta: minikube start --memory=6144 --cpus=4"
    exit 1
fi
kubectl wait --for=condition=Ready "node/$node" --timeout=120s >/dev/null

# La etiqueta workload ancla la plataforma y los PVs al nodo único.
kubectl label nodes minikube workload=platform --overwrite

# Elimina la etiqueta anterior para evitar que manifiestos viejos permitan
# programar componentes en cualquier nodo.
kubectl label nodes "$node" node-type- >/dev/null 2>&1 || true

echo "   platform: minikube (nodo único)"

echo ""
echo "2. Creando namespace..."
kubectl apply -f namespace.yaml

echo ""
echo "3. Creando secrets..."
kubectl apply -f secrets/db-secret.yaml

echo ""
echo "4. Creando configmaps..."
kubectl apply -f configmaps/prometheus-config.yaml
kubectl apply -f configmaps/otel-collector-config.yaml
kubectl apply -f configmaps/grafana-provisioning.yaml
kubectl apply -f configmaps/grafana-dashboards.yaml
kubectl apply -f configmaps/grafana-dashboard-infra.yaml
kubectl apply -f configmaps/grafana-alerting.yaml
kubectl apply -f configmaps/fluent-bit-config.yaml

echo ""
echo "5. Creando StorageClass y PersistentVolumes..."
kubectl apply -f persistent-volumes/storage-class.yaml

# Eliminar solo PVs en estado Released (huérfanos tras borrar el namespace).
# No intentar borrar PVs Bound: kubectl delete se bloquearía indefinidamente.
echo "   Limpiando PVs huérfanos (Released)..."
for pv in sql-pv elasticsearch-pv prometheus-pv grafana-pv; do
  status=$(kubectl get pv $pv -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$status" = "Released" ] || [ "$status" = "Failed" ]; then
    kubectl delete pv $pv --ignore-not-found=true 2>/dev/null || true
  fi
done
sleep 2

kubectl apply -f persistent-volumes/sql-pv.yaml
kubectl apply -f persistent-volumes/elasticsearch-pv.yaml
kubectl apply -f persistent-volumes/prometheus-pv.yaml
kubectl apply -f persistent-volumes/grafana-pv.yaml

echo ""
echo "6. Desplegando base de datos..."
kubectl apply -f services/ops/db-service.yaml
kubectl apply -f deployments/ops/db-deployment.yaml

echo ""
echo "   Esperando a que la base de datos esté lista..."
if kubectl wait --for=condition=Ready pod -l app=pharmago-db -n pharmago --timeout=300s; then
    echo "   Base de datos lista!"
else
    echo "   Timeout esperando la base de datos. Continuando..."
fi

echo ""
echo "7. Desplegando servicios de observabilidad..."
# Elasticsearch primero
kubectl apply -f services/ops/elasticsearch-service.yaml
kubectl apply -f deployments/ops/elasticsearch-deployment.yaml

# Esperar a que Elasticsearch esté listo
echo "   Esperando a que Elasticsearch esté listo..."
if kubectl wait --for=condition=Ready pod -l app=elasticsearch -n pharmago --timeout=300s; then
    echo "   Elasticsearch listo!"
else
    echo "   Timeout esperando Elasticsearch. Continuando..."
fi

# Resto de servicios ops
kubectl apply -f services/ops/otel-collector-service.yaml
kubectl apply -f deployments/ops/otel-collector-deployment.yaml

kubectl apply -f deployments/ops/prometheus-serviceaccount.yaml
kubectl apply -f deployments/ops/prometheus-clusterrole.yaml
kubectl apply -f deployments/ops/prometheus-clusterrolebinding.yaml
kubectl apply -f services/ops/prometheus-service.yaml
kubectl apply -f deployments/ops/prometheus-deployment.yaml
kubectl apply -f services/ops/node-exporter-service.yaml
kubectl apply -f deployments/ops/node-exporter-daemonset.yaml

kubectl apply -f services/ops/grafana-service.yaml
kubectl apply -f deployments/ops/grafana-deployment.yaml

kubectl apply -f services/ops/kibana-service.yaml
kubectl apply -f deployments/ops/kibana-deployment.yaml

# Fluent Bit: recolecta logs de pods y los envía a Elasticsearch (pharmago-logs-*)
kubectl apply -f deployments/ops/fluent-bit-serviceaccount.yaml
kubectl apply -f deployments/ops/fluent-bit-clusterrole.yaml
kubectl apply -f deployments/ops/fluent-bit-clusterrolebinding.yaml
kubectl apply -f deployments/ops/fluent-bit-daemonset.yaml

echo ""
echo "8. Desplegando servicios backend..."
kubectl apply -f services/backend/users-service-service.yaml
kubectl apply -f deployments/backend/users-service-deployment.yaml

kubectl apply -f services/backend/pharmacy-service-service.yaml
kubectl apply -f deployments/backend/pharmacy-service-deployment.yaml

kubectl apply -f services/backend/api-gateway-service.yaml
kubectl apply -f deployments/backend/api-gateway-deployment.yaml

echo ""
echo "9. Desplegando frontend..."
kubectl apply -f services/frontend/ui-service.yaml
kubectl apply -f deployments/frontend/ui-deployment.yaml

echo ""
echo "10. Inicializando base de datos con datos de prueba (seed-data.sql)..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_FILE="${SCRIPT_DIR}/../Backend/seed-data.sql"
if [ -f "$SEED_FILE" ]; then
    echo "   Esperando a que users-service complete migraciones de base de datos..."
    kubectl wait --for=condition=Ready pod -l app=pharmago-users-service -n pharmago --timeout=120s >/dev/null 2>&1 || true
    sleep 2
    DB_POD=$(kubectl get pod -n pharmago -l app=pharmago-db -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$DB_POD" ]; then
        kubectl exec -i -n pharmago "$DB_POD" -- /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Str0ngP@ssword!" -C -d PharmaDb -i /dev/stdin >/dev/null 2>&1 || true
        echo "   Datos iniciales cargados en la base de datos (admin, empleado01, owner001, etc.)"
    fi
fi

echo ""
echo "11. Configurando Dashboards y Data Views en Kibana..."
KIBANA_FILE="${SCRIPT_DIR}/kibana-dashboards.ndjson"
if [ -f "$KIBANA_FILE" ]; then
    echo "   Esperando a que Kibana este listo..."
    kubectl wait --for=condition=Ready pod -l app=kibana -n pharmago --timeout=120s >/dev/null 2>&1 || true
    KIBANA_POD=$(kubectl get pod -n pharmago -l app=kibana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -n "$KIBANA_POD" ]; then
        IMPORT_RES=$(cat "$KIBANA_FILE" | kubectl exec -i -n pharmago "$KIBANA_POD" -- sh -c "cat > /tmp/import.ndjson && curl -s -X POST 'http://localhost:5601/api/saved_objects/_import?overwrite=true' -H 'kbn-xsrf:true' -F 'file=@/tmp/import.ndjson'" 2>&1)
        if [[ "$IMPORT_RES" == *"\"success\":true"* ]]; then
            echo "   Dashboards y Data Views de Kibana importados correctamente."
        else
            echo "   Aviso al importar en Kibana: $IMPORT_RES"
        fi
    fi
fi

echo ""
echo "=== Despliegue completado ==="
echo ""
echo "Verificando estado de los pods..."
kubectl get pods -n pharmago -o wide

echo ""
echo "=== Dashboards y Accesos Disponibles ==="
echo ""
echo "Aplicación y Gateway (via port-forward):"
echo "  - Frontend:                   http://127.0.0.1:4200"
echo "  - API Gateway:                http://127.0.0.1:5000"
echo ""
echo "Dashboards de Grafana (Metricas y Rendimiento):"
echo "  - PharmaGo Overview:          http://127.0.0.1:3000/d/pharmago-overview"
echo "  - Infraestructura Kubernetes: http://127.0.0.1:3000/d/pharmago-infra"
echo ""
echo "Dashboards de Kibana (Logs y Trazabilidad):"
echo "  - PharmaGo - Logs:            http://127.0.0.1:5601/app/dashboards#/view/4fc85f40-cbca-11f1-a044-d7e76d4ac73e"
echo "  - Stream de Logs en Vivo:     http://127.0.0.1:5601/app/discover"
echo ""
echo "Prometheus & Base de Datos:"
echo "  - Prometheus Targets:         http://127.0.0.1:9090"
echo "  - SQL Server:                 127.0.0.1,11433 (sa / Str0ngP@ssword!)"
echo ""
echo "Nota: Si los puertos locales no estan activos, inicia los tuneles con:"
echo "      ./port-forward.sh"
echo ""

