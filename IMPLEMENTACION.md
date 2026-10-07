# Registro de Implementación y Cambios del Proyecto

Este documento resume los cambios técnicos implementados en el proyecto conforme a la rúbrica de evaluación de AIOps.

---

## 1. Implementación de Plataforma

- **Cluster Multirnodo (Minikube)**:
  - Configuración de un cluster local con cinco nodos Kubernetes para separar los microservicios en nodos físicos independientes:
    - `minikube` (`workload=platform`): Base de datos SQL Server y plataforma de observabilidad.
    - `minikube-m02` (`workload=frontend`): Frontend Angular (`pharmago-ui`).
    - `minikube-m03` (`workload=users`): Microservicio de usuarios (`pharmago-users-service`).
    - `minikube-m04` (`workload=pharmacy`): Microservicio de operaciones de farmacia (`pharmago-pharmacy-service`).
    - `minikube-m05` (`workload=gateway`): API Gateway YARP (`pharmago-api-gateway`).

- **Afinidad y Aislamiento de Cargas**:
  - Configuración de `nodeAffinity` obligatoria (`requiredDuringSchedulingIgnoredDuringExecution`) en cada Deployment hacia su respectivo label `workload`, evitando la coexistencia de microservicios en un mismo nodo.
  - Excepciones intencionales mediante DaemonSets (`fluent-bit` y `node-exporter`) para ejecutar un agente por nodo recolectando logs y métricas de infraestructura.

- **Almacenamiento Persistente**:
  - PersistentVolumes y PersistentVolumeClaims configurados y anclados al nodo `platform` para SQL Server, Elasticsearch, Prometheus y Grafana.

- **Automatización**:
  - Scripts `build-images.ps1` / `build-images.sh` y `apply-k8s.ps1` / `apply-k8s.sh` para compilación, carga de imágenes y despliegue idempotente del cluster.

---

## 2. Alta Disponibilidad

- **Múltiples Réplicas y Redundancia**:
  - Escalamiento a 2 réplicas (`replicas: 2`) en los Deployments de `pharmago-users-service`, `pharmago-pharmacy-service`, `pharmago-api-gateway` y `pharmago-ui`.
  - Las réplicas corren en su nodo asignado, garantizando que si una réplica falla, se reinicia o sufre excepciones, la réplica restante mantenga el 100% de la disponibilidad del servicio.

- **Auto-curación (Self-Healing) y Estado READY**:
  - Ajuste de `readinessProbe` con umbral de fallo rápido (`periodSeconds: 5`, `failureThreshold: 2`): ante excepciones que degraden un contenedor, este se retira de inmediato de los endpoints del Service de Kubernetes, derivando el tráfico a la réplica sana.
  - Sondas `livenessProbe` configuradas para reiniciar automáticamente contenedores bloqueados o corruptos (`restartPolicy: Always`), restaurando el estado `READY (1/1)` en pocos segundos.
  - Estrategia de despliegue `RollingUpdate` (`maxSurge: 1`, `maxUnavailable: 0`) para evitar downtime en actualizaciones o reinicios.

- **Salud del API Gateway**:
  - Implementación del endpoint nativo `/health` en `PharmaGo.ApiGateway/Program.cs` (`AddHealthChecks()` y `MapHealthChecks("/health")`).
  - Actualización de las sondas del deployment del Gateway de `tcpSocket` a `httpGet: /health`.

- **Resiliencia ante Ataques de Fallas Reiteradas**:
  - Creación de `FailedRequestsThrottlingMiddleware` en el API Gateway:
    - Rastrea respuestas fallidas (códigos HTTP $\ge 400$) por cliente/IP en ventanas deslizantes de 1 minuto.
    - Si un cliente supera el umbral de fallas consecutivas/reiteradas (ataques DoS, fuerza bruta en `/api/login` o inyección de requests inválidas), se activa una contención automática que bloquea temporalmente las solicitudes de dicho cliente devolviendo `HTTP 429 Too Many Requests` (`Retry-After: 60`), protegiendo a los microservicios y a la base de datos de saturación.

- **Circuit Breaker y Reintentos con Equal Jitter (Polly)**:
  - Incorporación del paquete `Microsoft.Extensions.Http.Polly` en `UsersService.Factory` y `PharmacyService.Factory`.
  - Configuración en los clientes HTTP inter-servicio (`PharmacyServiceClient` y `UsersServiceClient`):
    - **Retry con Equal Jitter**: 3 reintentos con cálculo de espera que divide el retroceso exponencial en una parte base y otra aleatoria ($\text{delay} = \frac{\text{backoff}}{2} + \text{Random}(0, \frac{\text{backoff}}{2})$) para evitar el problema de "Thundering Herd".
    - **Circuit Breaker**: Ante 5 fallas consecutivas, el circuito se abre durante 30 segundos, devolviendo un fallback seguro sin propagar fallas en cascada ni sobrecargar los canales de comunicación.

---

## 3. Tareas Pendientes

- [ ] **Script de Ingeniería del Caos para Alta Disponibilidad**: Implementar script específico de caos para simular y validar de forma automatizada la auto-curación de pods y la activación del patrón de mitigación ante solicitudes fallidas.
