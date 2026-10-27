# Diagrama de Despliegue de la Plataforma

Este documento describe la arquitectura de despliegue sobre Kubernetes (Minikube de nodo único), con los microservicios, la base de datos relacional y la infraestructura de observabilidad.

## Imagen para Documentación (Tema Claro)

Para incluir en el informe académico final (Word/PDF), se generaron dos formatos listos para usar en `Implementacion K8S/Documentación/img/`:
- [diagrama-despliegue.png](file:///c:/ID/AIOps-282102-284068/Implementacion%20K8S/Documentacio%CC%81n/img/diagrama-despliegue.png) (PNG renderizado nítido con fondo claro)
- [diagrama-despliegue.svg](file:///c:/ID/AIOps-282102-284068/Implementacion%20K8S/Documentacio%CC%81n/img/diagrama-despliegue.svg) (Gráfico vectorial escalable)

---

## Diagrama Mermaid (Tema Claro Simplificado)

```mermaid
%%{init: {
  'theme': 'base',
  'themeVariables': {
    'primaryColor': '#EEF2F6',
    'primaryTextColor': '#1E293B',
    'primaryBorderColor': '#94A3B8',
    'lineColor': '#334155',
    'secondaryColor': '#FFFFFF',
    'tertiaryColor': '#F8FAFC',
    'fontSize': '12px'
  }
}}%%
flowchart TB
    Client(["Cliente / Navegador Web"])

    subgraph Cluster ["Cluster Kubernetes (Minikube) - Namespace: pharmago"]
        subgraph Node ["Nodo: minikube (Label: workload=platform)"]

            subgraph Apps ["Microservicios de Aplicacion (Afinidad Blanda: workload)"]
                UI["<b>pharmago-ui</b><br/>pharmago-ui:latest<br/>(replicas: 2 | :80)"]
                GW["<b>pharmago-api-gateway</b><br/>pharmago-api-gateway:latest<br/>(replicas: 2 | :80)"]
                Users["<b>pharmago-users-service</b><br/>pharmago-users-service:latest<br/>(replicas: 2 | :80)"]
                Pharm["<b>pharmago-pharmacy-service</b><br/>pharmago-pharmacy-service:latest<br/>(replicas: 2 | :80)"]
            end

            subgraph Data ["Base de Datos (Afinidad: workload=platform)"]
                DB[("<b>pharmago-db</b><br/>mcr.microsoft.com/mssql/server:2019-latest<br/>(replicas: 1 | :1433)")]
            end

            subgraph Obs ["Stack de Observabilidad y Telemetria (workload=platform)"]
                OTEL["<b>otel-collector</b><br/>otel/opentelemetry-collector-contrib:latest<br/>(:4317 / :8889)"]
                Prom["<b>prometheus</b><br/>prom/prometheus:latest<br/>(:9090)"]
                Graf["<b>grafana</b><br/>grafana/grafana:10.4.2<br/>(:3000)"]
                ES["<b>elasticsearch</b><br/>docker.elastic.co/elasticsearch/elasticsearch:8.11.0<br/>(:9200)"]
                Kib["<b>kibana</b><br/>docker.elastic.co/kibana/kibana:8.11.0<br/>(:5601)"]
                FB["<b>fluent-bit (DaemonSet)</b><br/>fluent/fluent-bit:2.2.2"]
                NodeExp["<b>node-exporter (DaemonSet)</b><br/>prom/node-exporter:v1.7.0<br/>(:9100)"]
            end

        end
    end

    %% Trafico de Usuario
    Client -->|"HTTP :8080 (Port-Forward)"| UI
    Client -->|"HTTP :5000 (Port-Forward API)"| GW

    %% Enrutamiento Interno
    GW -->|"HTTP"| Users
    GW -->|"HTTP"| Pharm
    Users -->|"SQL :1433"| DB
    Pharm -->|"SQL :1433"| DB

    %% Telemetria y Monitoreo
    Apps -.->|"OTLP gRPC :4317 (Trazas/Metricas)"| OTEL
    OTEL -.->|"Metricas :8889"| Prom
    NodeExp -.->|"Metricas Host :9100"| Prom
    Prom -.->|"Dashboards"| Graf
    FB -.->|"Logs JSON CRI"| ES
    ES -.->|"Indices"| Kib
```

---

## Distribución y Afinidad de Cargas

- **Nodo de Plataforma (`workload=platform`)**:
  - `minikube` actúa como nodo único donde residen los PersistentVolumes y componentes de plataforma (`pharmago-db`, `elasticsearch`, `prometheus`, `grafana`, `otel-collector`, `kibana`).
- **Microservicios**:
  - Cada microservicio corre en pods independientes con 2 réplicas (`replicas: 2`).
  - Afinidad declarativa blanda (`preferredDuringScheduling...`) por label `workload` (`frontend`, `gateway`, `users`, `pharmacy`), preparada para elevarse a `required` en entornos multi-nodo.
- **DaemonSets**:
  - `fluent-bit` y `node-exporter` ejecutan una instancia por nodo para recolección de logs a nivel de contenedor y métricas a nivel de sistema operativo/nodo.
