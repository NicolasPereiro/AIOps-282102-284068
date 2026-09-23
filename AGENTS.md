# Guía de despliegue para agentes y colaboradores

## Arquitectura Kubernetes

El despliegue local de PharmaGo utiliza Minikube con cinco nodos Kubernetes. Si
el cluster todavía tiene solamente el nodo `minikube`, deben agregarse cuatro
workers:

```bash
minikube node add --worker
minikube node add --worker
minikube node add --worker
minikube node add --worker
```

La distribución obligatoria es:

| Nodo | Label `workload` | Componentes principales |
|---|---|---|
| `minikube` | `platform` | SQL Server, OTEL Collector, Prometheus, Grafana, Elasticsearch y Kibana |
| `minikube-m02` | `frontend` | Frontend Angular servido por Nginx |
| `minikube-m03` | `users` | Users Service |
| `minikube-m04` | `pharmacy` | Pharmacy Service |
| `minikube-m05` | `gateway` | API Gateway |

Los labels se pueden aplicar manualmente con:

```bash
kubectl label node minikube workload=platform --overwrite
kubectl label node minikube-m02 workload=frontend --overwrite
kubectl label node minikube-m03 workload=users --overwrite
kubectl label node minikube-m04 workload=pharmacy --overwrite
kubectl label node minikube-m05 workload=gateway --overwrite
```

Los Deployments usan afinidad obligatoria hacia su label `workload`. No se debe
reintroducir `node-type=all`, porque permitiría que varios microservicios fueran
programados en el mismo nodo.

Fluent Bit y Node Exporter son excepciones intencionales: son DaemonSets y deben
ejecutar una instancia por nodo para recolectar logs y métricas de toda la
infraestructura.

## Flujo de trabajo

1. Verificar los nodos:

   ```bash
   kubectl get nodes --show-labels
   ```

2. Construir y cargar imágenes desde `Implementacion K8S/Codigo/k8s`:

   ```powershell
   .\build-images.ps1
   ```

3. Aplicar los manifiestos:

   ```powershell
   .\apply-k8s.ps1
   ```

4. Verificar la distribución:

   ```bash
   kubectl get pods -n pharmago -o wide
   ```

Los PersistentVolumes de SQL Server, Elasticsearch, Prometheus y Grafana están
asociados al nodo `platform` mediante `workload=platform`.

## Acceso local

El frontend Angular utiliza `http://127.0.0.1:5000` como URL del API. Para las
pruebas locales se deben mantener los port-forwards documentados en
`Implementacion K8S/Codigo/k8s/README-k8s.md`.

## Limitación de Minikube

Los nodos de Minikube son contenedores Docker sobre la misma máquina física. La
separación demostrada es separación entre nodos Kubernetes; un entorno productivo
requeriría hosts físicos o máquinas virtuales independientes.
