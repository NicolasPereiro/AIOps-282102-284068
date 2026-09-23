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
    echo "Ejecuta: minikube start y agrega cuatro workers con minikube node add --worker"
    exit 1
fi

echo ""
echo "1. Validando y etiquetando los nodos del despliegue..."
REQUIRED_NODES=(minikube minikube-m02 minikube-m03 minikube-m04 minikube-m05)

for node in "${REQUIRED_NODES[@]}"; do
  if ! kubectl get node "$node" >/dev/null 2>&1; then
    echo "Error: No se encontró el nodo $node. Se requieren cinco nodos Kubernetes."
    echo "Agrega workers con: minikube node add --worker"
    exit 1
  fi
  kubectl wait --for=condition=Ready "node/$node" --timeout=120s >/dev/null
done

# La etiqueta workload determina en qué nodo puede ejecutarse cada componente.
kubectl label nodes minikube workload=platform --overwrite
kubectl label nodes minikube-m02 workload=frontend --overwrite
kubectl label nodes minikube-m03 workload=users --overwrite
kubectl label nodes minikube-m04 workload=pharmacy --overwrite
kubectl label nodes minikube-m05 workload=gateway --overwrite

# Elimina la etiqueta anterior para evitar que manifiestos viejos permitan
# programar componentes en cualquier nodo.
for node in "${REQUIRED_NODES[@]}"; do
  kubectl label nodes "$node" node-type- >/dev/null 2>&1 || true
done

echo "   platform: minikube"
echo "   frontend: minikube-m02"
echo "   users:    minikube-m03"
echo "   pharmacy: minikube-m04"
echo "   gateway:  minikube-m05"

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
echo "=== Despliegue completado ==="
echo ""
echo "Verificando estado de los pods..."
kubectl get pods -n pharmago -o wide

echo ""
echo "Para acceder a los servicios (usa 127.0.0.1 en Windows):"
echo "  ./port-forward.sh"
echo ""
echo "O con minikube service:"
echo "  Frontend:     minikube service pharmago-ui -n pharmago --url"
echo "  Grafana:      minikube service grafana -n pharmago --url"
echo "  Kibana:       minikube service kibana -n pharmago --url"
echo "  Prometheus:   minikube service prometheus -n pharmago --url"

