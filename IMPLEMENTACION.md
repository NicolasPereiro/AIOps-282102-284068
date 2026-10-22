# Registro de ImplementaciÃ³n y Cambios del Proyecto

Este documento resume los cambios tÃ©cnicos implementados en el proyecto conforme a la rÃºbrica de evaluaciÃ³n de AIOps.

---

## 1. ImplementaciÃ³n de Plataforma

- **Cluster Minikube de un nodo**:
  - Despliegue local en un Ãºnico nodo Kubernetes (`minikube`), iniciado con `minikube start --memory=6144 --cpus=4`.
  - El nodo se etiqueta `workload=platform` para anclar los componentes de plataforma (SQL Server, OTEL Collector, Prometheus, Grafana, Elasticsearch, Kibana) y sus PersistentVolumes.
  - Cada microservicio corre en su propio pod independiente (Frontend Angular, Users Service, Pharmacy Service y API Gateway).

- **Afinidad y Aislamiento de Cargas (declarativo)**:
  - Los componentes de plataforma usan `nodeAffinity` obligatoria (`requiredDuringSchedulingIgnoredDuringExecution`) hacia `workload=platform`.
  - Los microservicios declaran `nodeAffinity` **blanda** (`preferredDuringSchedulingIgnoredDuringExecution`, `weight: 100`) hacia su label `workload` (`frontend`, `users`, `pharmacy`, `gateway`). En este entorno de un solo nodo la separaciÃ³n es declarativa/demostrativa: expresa el aislamiento por label sin bloquear el scheduling. En un entorno productivo multi-nodo, esta misma afinidad se elevarÃ­a a `required` para garantizar que los microservicios no compartan nodo fÃ­sico.
  - Fluent Bit y Node Exporter son DaemonSets (una instancia por nodo).

- **Almacenamiento Persistente**:
  - PersistentVolumes y PersistentVolumeClaims configurados y anclados al nodo `platform` mediante `workload=platform` para SQL Server, Elasticsearch, Prometheus y Grafana.

- **AutomatizaciÃ³n**:
  - Scripts `build-images.ps1` / `build-images.sh` y `apply-k8s.ps1` / `apply-k8s.sh` para compilaciÃ³n, carga de imÃ¡genes y despliegue idempotente del cluster.

---

## 2. Alta Disponibilidad

- **MÃºltiples RÃ©plicas y Redundancia**:
  - Escalamiento a 2 rÃ©plicas (`replicas: 2`) en los Deployments de `pharmago-users-service`, `pharmago-pharmacy-service`, `pharmago-api-gateway` y `pharmago-ui`.
  - Las rÃ©plicas corren en su nodo asignado, garantizando que si una rÃ©plica falla, se reinicia o sufre excepciones, la rÃ©plica restante mantenga el 100% de la disponibilidad del servicio.

- **Auto-curaciÃ³n (Self-Healing) y Estado READY**:
  - Ajuste de `readinessProbe` con umbral de fallo rÃ¡pido (`periodSeconds: 5`, `failureThreshold: 2`): ante excepciones que degraden un contenedor, este se retira de inmediato de los endpoints del Service de Kubernetes, derivando el trÃ¡fico a la rÃ©plica sana.
  - Sondas `livenessProbe` configuradas para reiniciar automÃ¡ticamente contenedores bloqueados o corruptos (`restartPolicy: Always`), restaurando el estado `READY (1/1)` en pocos segundos.
  - Estrategia de despliegue `RollingUpdate` (`maxSurge: 1`, `maxUnavailable: 0`) para evitar downtime en actualizaciones o reinicios.

- **Salud del API Gateway**:
  - ImplementaciÃ³n del endpoint nativo `/health` en `PharmaGo.ApiGateway/Program.cs` (`AddHealthChecks()` y `MapHealthChecks("/health")`).
  - ActualizaciÃ³n de las sondas del deployment del Gateway de `tcpSocket` a `httpGet: /health`.

- **Resiliencia ante Ataques de Fallas Reiteradas**:
  - CreaciÃ³n de `FailedRequestsThrottlingMiddleware` en el API Gateway:
    - Rastrea respuestas fallidas (cÃ³digos HTTP $\ge 400$) por cliente/IP en ventanas deslizantes de 1 minuto.
    - Si un cliente supera el umbral de fallas consecutivas/reiteradas (ataques DoS, fuerza bruta en `/api/login` o inyecciÃ³n de requests invÃ¡lidas), se activa una contenciÃ³n automÃ¡tica que bloquea temporalmente las solicitudes de dicho cliente devolviendo `HTTP 429 Too Many Requests` (`Retry-After: 60`), protegiendo a los microservicios y a la base de datos de saturaciÃ³n.

- **Circuit Breaker y Reintentos con Equal Jitter (Polly)**:
  - IncorporaciÃ³n del paquete `Microsoft.Extensions.Http.Polly` en `UsersService.Factory` y `PharmacyService.Factory`.
  - ConfiguraciÃ³n en los clientes HTTP inter-servicio (`PharmacyServiceClient` y `UsersServiceClient`):
    - **Retry con Equal Jitter**: 3 reintentos con cÃ¡lculo de espera que divide el retroceso exponencial en una parte base y otra aleatoria ($\text{delay} = \frac{\text{backoff}}{2} + \text{Random}(0, \frac{\text{backoff}}{2})$) para evitar el problema de "Thundering Herd".
    - **Circuit Breaker**: Ante 5 fallas consecutivas, el circuito se abre durante 30 segundos, devolviendo un fallback seguro sin propagar fallas en cascada ni sobrecargar los canales de comunicaciÃ³n.

---

## 3. TelemetrÃ­a

### Cumplimiento de la rÃºbrica (segÃºn "Obligatorio AIOps")

| Requisito | Estado | ImplementaciÃ³n |
|---|---|---|
| Logs estructurados en JSON | âœ… | Formateador JSON en ApiGateway, parser CRI en Fluent Bit, campos `LogLevel`, `Message`, `Category`, `correlation_id`, `pharma_biz` como JSON raÃ­z en Elasticsearch |
| Trazas de acuerdo a OTLP | âœ… | `.WithTracing(...)` en Users, Pharmacy y Gateway con exportador OTLP gRPC a `otlp-collector:4317`; pipeline `traces` en el collector |
| MÃ©tricas a nivel de pod/contenedor y nodo (CPU, memoria, storage, red) | âœ… | Prometheus scrapea OTLP collector, users/pharmacy/gateway, node-exporter (nodo) y cAdvisor (pod/contenedor); dashboard "PharmaGo - Infra" en Grafana |
| MÃ©tricas recolectadas con OTLP hacia Prometheus | âœ… | Servicios envÃ­an mÃ©tricas OTLP al collector; collector exporta a Prometheus (`prometheus` exporter en puerto 8889) |
| Logs consultables en Kibana + Elasticsearch | âœ… | Data View `pharmago-logs*`, dashboard "PharmaGo - Logs" con histograma por nivel, distribuciÃ³n por servicio, errores y visor estructurado |
| Al menos 5 alertas en Grafana para detecciÃ³n de anomalÃ­as | âœ… | 5 reglas (errores HTTP >5%, latencia >1s, 429 >5 req/s, CPU >85%, memoria >85% riesgo OOM) |

- **Logging de nivel Error**:
  - Se agregÃ³ `ILogger` a los `ExceptionFilter` de Users y Pharmacy para registrar `LogError` cuando se captura una excepciÃ³n no controlada (HTTP 500), incluyendo la excepciÃ³n y el contexto de la peticiÃ³n.

- **Trazas distribuidas (OpenTelemetry OTLP)**:
  - Se habilitÃ³ `.WithTracing(...)` en `UsersService`, `PharmacyService` y `ApiGateway` con instrumentaciÃ³n ASP.NET Core y HttpClient, exportando vÃ­a OTLP (gRPC) a `http://otlp-collector:4317`.
  - Se habilitÃ³ el pipeline `traces` en el OpenTelemetry Collector (`otel-collector-config.yaml`).
  - Validado: el collector recibe y exporta spans de los tres servicios (Gateway, Users, Pharmacy), con propagaciÃ³n de contexto (`traceparent` / `X-Correlation-ID`).

- **Alertas de Grafana**:
  - ConfigMap `grafana-alerting.yaml` con 5 reglas de anomalÃ­as: tasa de errores HTTP > 5%, latencia media > 1s, rate limit 429 > 5 req/s, CPU pod > 85%, memoria > 85% (riesgo OOM).
  - Montado en el deployment de Grafana bajo `/etc/grafana/provisioning/alerting/`.
  - ValidaciÃ³n integrada en `setup-dashboards.ps1` (consulta `api/v1/provisioning/alert-rules`).

- **Script de trÃ¡fico mixto (`traffic-generator.ps1`)**:
  - UbicaciÃ³n: `Implementacion K8S/Codigo/chaos-engineering/traffic-generator.ps1`.
  - Genera peticiones HTTP mixtas (cÃ³digos 200 y 4XX: 400, 401, 404 y 429) contra los servicios de Users y Pharmacy a travÃ©s del API Gateway (`http://127.0.0.1:5000`).
  - Obtiene tokens de sesiÃ³n con las credenciales sembradas (`admin`, `empleado`, `duenio`) para ejercitar endpoints protegidos y generar 401 en accesos sin token.
  - Ejecuta con un pool de runspaces configurable (`-Concurrency`) y exporta el detalle de cada peticiÃ³n a `traffic-results.csv`, incluyendo resumen por cÃ³digo de estado y por endpoint.
   - Parametros principales: -TotalRequests, -Concurrency, -DelayMs, -BaseUrl, -UsersServiceUrl, -OutputCsv, -DurationSec, -IncludeRateLimitTest.
   - **Modo carga sostenida (~5 min, >=20 req/s, mayoria sin 429)**:
     ```powershell
     .\traffic-generator.ps1 -TotalRequests 300 -Concurrency 20 -DurationSec 300
     ```
     IP rotativa en todas las requests (10.0.0.x) para evitar rate limit por IP y throttling de fallas. Sin bloque 429.
   - **Modo con test de rate limiting (incluye bloque 429)**:
     ```powershell
     .\traffic-generator.ps1 -TotalRequests 300 -Concurrency 20 -DurationSec 300 -IncludeRateLimitTest
     ```
     Agrega 202 requests desde una sola IP (10.99.99.99) para disparar el rate limiter y el FailedRequestsThrottlingMiddleware.
   - Requiere port-forward activo. El modo con -IncludeRateLimitTest consume el rate limit: esperar ~60 s entre corridas.

---

## 4. Tareas Pendientes

- [x] **Script de Ingenieria del Caos para Alta Disponibilidad**: Implementado chaos-ha.ps1 (Implementacion K8S/Codigo/chaos-engineering/) para simular y validar de forma automatizada la auto-curación de pods (eliminacion de pod + verificacion de nueva replica READY dentro del timeout, con Service respondiendo) y la activacion del patron de mitigacion ante solicitudes fallidas (envio de requests invalidas y verificacion de HTTP 429 con Retry-After).
