# Registro de Implementación y Cambios del Proyecto

Este documento resume los cambios técnicos implementados en el proyecto conforme a la rúbrica de evaluación de AIOps.

---

## 1. Implementación de Plataforma

- **Cluster Minikube de un nodo**:
  - Despliegue local en un único nodo Kubernetes (`minikube`), iniciado con `minikube start --memory=6144 --cpus=4`.
  - El nodo se etiqueta `workload=platform` para anclar los componentes de plataforma (SQL Server, OTEL Collector, Prometheus, Grafana, Elasticsearch, Kibana) y sus PersistentVolumes.
  - Cada microservicio corre en su propio pod independiente (Frontend Angular, Users Service, Pharmacy Service y API Gateway).

- **Afinidad y Aislamiento de Cargas (declarativo)**:
  - Los componentes de plataforma usan `nodeAffinity` obligatoria (`requiredDuringSchedulingIgnoredDuringExecution`) hacia `workload=platform`.
  - Los microservicios declaran `nodeAffinity` **blanda** (`preferredDuringSchedulingIgnoredDuringExecution`, `weight: 100`) hacia su label `workload` (`frontend`, `users`, `pharmacy`, `gateway`). En este entorno de un solo nodo la separación es declarativa/demostrativa: expresa el aislamiento por label sin bloquear el scheduling. En un entorno productivo multi-nodo, esta misma afinidad se elevaría a `required` para garantizar que los microservicios no compartan nodo físico.
  - Fluent Bit y Node Exporter son DaemonSets (una instancia por nodo).

- **Almacenamiento Persistente**:
  - PersistentVolumes y PersistentVolumeClaims configurados y anclados al nodo `platform` mediante `workload=platform` para SQL Server, Elasticsearch, Prometheus y Grafana.

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

## 3. Despliegues Seguros (Zero-Downtime Rolling Updates)

Conforme a la rúbrica de evaluación (*"El sistema debe poder reemplazar sus componentes garantizando 100% de disponibilidad. Se necesita documentar y explicar la técnica elegida"*):

### Justificación de la Técnica Elegida
Se optó por la estrategia nativa de Kubernetes **RollingUpdate** ajustada con parámetros estrictos de disponibilidad, en lugar de enfoques más pesados como Canary o Blue-Green:
1. **Garantía matemática de 100% de disponibilidad sin sobrecosto**: En un entorno local (Minikube con recursos finitos), Blue-Green exigiría duplicar la capacidad de memoria y CPU (200% del clúster corriendo en paralelo). Por su parte, Canary requeriría herramientas adicionales (como Ingress controllers avanzados o service meshes como Istio/Linkerd) sumando complejidad innecesaria.
2. **Reemplazo progresivo controlado**: `RollingUpdate` con `maxUnavailable: 0` garantiza que Kubernetes jamás destruye una réplica funcional antes de que su reemplazo esté 100% listo para recibir tráfico de usuarios.

### Mecanismos de Configuración Implementados
Todos los microservicios sin estado (`pharmago-ui`, `pharmago-users-service`, `pharmago-pharmacy-service` y `pharmago-api-gateway`) cuentan con la siguiente configuración:

1. **Estrategia RollingUpdate Estricta**:
   ```yaml
   replicas: 2
   strategy:
     type: RollingUpdate
     rollingUpdate:
       maxSurge: 1
       maxUnavailable: 0
   ```
   - `maxUnavailable: 0`: Fuerza a que en ningún momento el número de pods disponibles sea inferior a las réplicas deseadas (mínimo 2 réplicas sanas siempre atendiendo tráfico).
   - `maxSurge: 1`: Permite crear a lo sumo 1 pod adicional temporal por encima del deseado (hasta 3 pods simultáneos durante la transición).

2. **Acoplamiento con Sondas de Estado (`readinessProbe` y `startupProbe`)**:
   - Una estrategia `RollingUpdate` solo previene caídas si Kubernetes sabe cuándo la nueva versión está efectivamente lista.
   - Si no se configuran sondas, Kubernetes considera el pod listo apenas inicia el proceso, redirigiendo tráfico antes del warmup de la aplicación o de establecer el pool de conexiones a la base de datos.
   - Con `readinessProbe` apuntando a `/health` (`periodSeconds: 5`, `failureThreshold: 2`), el pod en versión nueva se mantiene fuera de los endpoints del Service hasta responder satisfactoriamente. Solo cuando la nueva réplica pasa a estado `READY (1/1)` se añade a los endpoints y se procede al drenado y apagado ordenado (`SIGTERM`) de la réplica en versión anterior.

3. **Rollback Automático y Manual**:
   - Si una nueva imagen contiene un fallo de inicio o no responde en `/health`, el `readinessProbe` falla continuamente: el rollout se bloquea automáticamente sin derribar las réplicas sanas de la versión previa.
   - En caso de requerirse rollback manual inmediato:
     ```bash
     kubectl rollout undo deployment/pharmago-users-service -n pharmago
     ```

### Procedimiento de Validación de Disponibilidad
Para comprobar que durante una actualización no se pierde una sola petición:
1. Iniciar un flujo continuo de tráfico con el generador:
   ```powershell
   .\traffic-generator.ps1 -TotalRequests 200 -Concurrency 5 -DelayMs 100
   ```
2. Provocar el reemplazo de componentes (rollout):
   ```bash
   kubectl rollout restart deployment pharmago-users-service -n pharmago
   kubectl rollout status deployment pharmago-users-service -n pharmago
   ```
3. Verificar en `traffic-results.csv` que el 100% de las respuestas son exitosas (cero errores HTTP 502/503/504 por caída de pods).

---

## 4. Telemetría

### Cumplimiento de la rúbrica (según "Obligatorio AIOps")

| Requisito | Estado | Implementación |
|---|---|---|
| Logs estructurados en JSON | ✅ | Formateador JSON en ApiGateway, parser CRI en Fluent Bit, campos `LogLevel`, `Message`, `Category`, `correlation_id`, `pharma_biz` como JSON raíz en Elasticsearch |
| Trazas de acuerdo a OTLP | ✅ | `.WithTracing(...)` en Users, Pharmacy y Gateway con exportador OTLP gRPC a `otlp-collector:4317`; pipeline `traces` en el collector |
| Métricas a nivel de pod/contenedor y nodo (CPU, memoria, storage, red) | ✅ | Prometheus scrapea OTLP collector, users/pharmacy/gateway, node-exporter (nodo) y cAdvisor (pod/contenedor); dashboard "PharmaGo - Infra" en Grafana |
| Métricas recolectadas con OTLP hacia Prometheus | ✅ | Servicios envían métricas OTLP al collector; collector exporta a Prometheus (`prometheus` exporter en puerto 8889) |
| Logs consultables en Kibana + Elasticsearch | ✅ | Data View `pharmago-logs*`, dashboard "PharmaGo - Logs" con histograma por nivel, distribución por servicio, errores y visor estructurado |
| Al menos 5 alertas en Grafana para detección de anomalías | ✅ | 5 reglas (errores HTTP >5%, latencia >1s, 429 >5 req/s, CPU >85%, memoria >85% riesgo OOM) |

- **Logging de nivel Error**:
  - Se agregó `ILogger` a los `ExceptionFilter` de Users y Pharmacy para registrar `LogError` cuando se captura una excepción no controlada (HTTP 500), incluyendo la excepción y el contexto de la petición.

- **Trazas distribuidas (OpenTelemetry OTLP)**:
  - Se habilitó `.WithTracing(...)` en `UsersService`, `PharmacyService` y `ApiGateway` con instrumentación ASP.NET Core y HttpClient, exportando vía OTLP (gRPC) a `http://otlp-collector:4317`.
  - Se habilitó el pipeline `traces` en el OpenTelemetry Collector (`otel-collector-config.yaml`).
  - Validado: el collector recibe y exporta spans de los tres servicios (Gateway, Users, Pharmacy), con propagación de contexto (`traceparent` / `X-Correlation-ID`).

- **Alertas de Grafana**:
  - ConfigMap `grafana-alerting.yaml` con 5 reglas de anomalías: tasa de errores HTTP > 5%, latencia media > 1s, rate limit 429 > 5 req/s, CPU pod > 85%, memoria > 85% (riesgo OOM).
  - Montado en el deployment de Grafana bajo `/etc/grafana/provisioning/alerting/`.
  - Validación integrada en `setup-dashboards.ps1` (consulta `api/v1/provisioning/alert-rules`).

- **Script de tráfico mixto (`traffic-generator.ps1`)**:
  - Ubicación: `Implementacion K8S/Codigo/chaos-engineering/traffic-generator.ps1`.
  - Genera peticiones HTTP mixtas (códigos 200 y 4XX: 400, 401, 404 y 429) contra los servicios de Users y Pharmacy a través del API Gateway (`http://127.0.0.1:5000`).
  - Obtiene tokens de sesión con las credenciales sembradas (`admin`, `empleado`, `duenio`) para ejercitar endpoints protegidos y generar 401 en accesos sin token.
  - Ejecuta con un pool de runspaces configurable (`-Concurrency`) y exporta el detalle de cada petición a `traffic-results.csv`, incluyendo resumen por código de estado y por endpoint.
   - Parámetros principales: `-TotalRequests`, `-Concurrency`, `-DelayMs`, `-BaseUrl`, `-UsersServiceUrl`, `-OutputCsv`, `-DurationSec`, `-IncludeRateLimitTest`.
   - **Modo carga sostenida (~5 min, >=20 req/s, mayoría sin 429)**:
     ```powershell
     .\traffic-generator.ps1 -TotalRequests 300 -Concurrency 20 -DurationSec 300
     ```
     IP rotativa en todas las requests (10.0.0.x) para evitar rate limit por IP y throttling de fallas. Sin bloque 429.
   - **Modo con test de rate limiting (incluye bloque 429)**:
     ```powershell
     .\traffic-generator.ps1 -TotalRequests 300 -Concurrency 20 -DurationSec 300 -IncludeRateLimitTest
     ```
     Agrega 202 requests desde una sola IP (10.99.99.99) para disparar el rate limiter y el FailedRequestsThrottlingMiddleware.
   - Requiere port-forward activo. El modo con `-IncludeRateLimitTest` consume el rate limit: esperar ~60 s entre corridas.

---

## 5. Tareas Pendientes

- [x] **Script de Ingeniería del Caos para Alta Disponibilidad**: Implementado `chaos-ha.ps1` (`Implementacion K8S/Codigo/chaos-engineering/`) para simular y validar de forma automatizada la auto-curación de pods (eliminación de pod + verificación de nueva réplica READY dentro del timeout, con Service respondiendo) y la activación del patrón de mitigación ante solicitudes fallidas (envío de requests inválidas y verificación de HTTP 429 con Retry-After).
