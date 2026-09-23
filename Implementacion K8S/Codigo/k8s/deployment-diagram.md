# Bosquejo del diagrama de despliegue

El siguiente diagrama representa la distribución de la plataforma en Minikube.

```mermaid
flowchart TB
    browser[Usuario / navegador]

    subgraph cluster[Cluster Kubernetes - Minikube]
        subgraph platform[Nodo minikube - workload=platform]
            db[(SQL Server)]
            otel[OTEL Collector]
            prometheus[Prometheus]
            grafana[Grafana]
            elastic[Elasticsearch]
            kibana[Kibana]
        end

        subgraph frontendNode[Nodo minikube-m02 - workload=frontend]
            ui[Frontend Angular + Nginx]
            uiSvc[Service pharmago-ui]
        end

        subgraph usersNode[Nodo minikube-m03 - workload=users]
            users[Users Service]
            usersSvc[Service pharmago-users-service]
        end

        subgraph pharmacyNode[Nodo minikube-m04 - workload=pharmacy]
            pharmacy[Pharmacy Service]
            pharmacySvc[Service pharmago-pharmacy-service]
        end

        subgraph gatewayNode[Nodo minikube-m05 - workload=gateway]
            gateway[API Gateway]
            gatewaySvc[Service pharmago-api-gateway]
        end

        subgraph daemonsets[DaemonSets - una instancia por nodo]
            fluent[Fluent Bit]
            nodeExporter[Node Exporter]
        end
    end

    browser --> uiSvc
    browser -->|API por port-forward 127.0.0.1:5000| gatewaySvc
    uiSvc --> ui
    gatewaySvc --> gateway
    gateway --> usersSvc
    gateway --> pharmacySvc
    usersSvc --> users
    pharmacySvc --> pharmacy
    users --> db
    pharmacy --> db

    users -->|métricas OTLP| otel
    pharmacy -->|métricas OTLP| otel
    gateway -->|métricas Prometheus| prometheus
    otel --> prometheus
    prometheus --> grafana
    fluent -->|logs JSON| elastic
    elastic --> kibana
    nodeExporter -->|métricas de nodos| prometheus
```

## Evidencia esperada

```text
pharmago-ui                  -> minikube-m02
pharmago-users-service       -> minikube-m03
pharmago-pharmacy-service    -> minikube-m04
pharmago-api-gateway         -> minikube-m05
pharmago-db                  -> minikube
elasticsearch/prometheus/... -> minikube
fluent-bit/node-exporter     -> todos los nodos
```

El frontend es una aplicación estática: las llamadas HTTP al API se originan en
el navegador. Por eso el frontend y el API Gateway pueden estar en nodos
distintos sin requerir comunicación directa entre el contenedor Nginx y el
Gateway.
