# Guía de despliegue para agentes y colaboradores

## Arquitectura Kubernetes

El despliegue local de PharmaGo utiliza Minikube con un único nodo Kubernetes.
Todos los componentes corren en el nodo `minikube`, iniciado con recursos
suficientes para el stack completo:

```bash
minikube start --memory=6144 --cpus=4
```

El nodo se etiqueta `workload=platform` para anclar los componentes de
plataforma y sus PersistentVolumes:

```bash
kubectl label node minikube workload=platform --overwrite
```

Los componentes de plataforma (SQL Server, OTEL Collector, Prometheus, Grafana,
Elasticsearch y Kibana) usan afinidad **obligatoria** (`required`) hacia
`workload=platform`, y los PersistentVolumes se anclan al mismo label.

Los microservicios (Frontend Angular, Users Service, Pharmacy Service y API
Gateway) declaran afinidad **blanda** (`preferred`) hacia su propio label
`workload` (`frontend`, `users`, `pharmacy`, `gateway`). En un entorno de un
solo nodo esta separación es **declarativa/demostrativa**: expresa la intención
de aislamiento por label sin bloquear el scheduling, y cada microservicio corre
en pods independientes.

Fluent Bit y Node Exporter son DaemonSets: en este despliegue de un solo nodo
ejecutan una única instancia que recolecta logs y métricas de la infraestructura.

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

Minikube corre como un contenedor Docker sobre la misma máquina física. En este
despliegue de un solo nodo no hay separación física real entre microservicios:
la separación por label `workload` es declarativa (afinidad blanda). Un entorno
productivo debería desplegar cada microservicio en hosts físicos o máquinas
virtuales independientes, usando la misma afinidad como requisito obligatorio.
