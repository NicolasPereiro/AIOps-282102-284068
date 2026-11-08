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
1. Iniciar un flujo continuo de tráfico con el motor integrado en `chaos.ps1`:
   ```powershell
   $env:CHAOS_DURATION_SEC = "300"; .\chaos.ps1
   ```
2. Provocar el reemplazo de componentes (rollout):
   ```bash
   kubectl rollout restart deployment pharmago-users-service -n pharmago
   kubectl rollout status deployment pharmago-users-service -n pharmago
   ```
3. Verificar en `chaos-engineering/reports/<timestamp>/traffic.csv` que durante el rollout la tasa se mantiene en 20 req/s y que el 100% de las respuestas siguen exitosas (cero errores HTTP 502/503/504 por caída de pods).

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

- **Generador de tráfico y motor de caos (`chaos.ps1`)**:
  - Ubicación: `Implementacion K8S/Codigo/chaos-engineering/chaos.ps1` — único
    script de caos, ejecución directa (`.\chaos.ps1`), sin parámetros.
  - Tráfico constante de **20 req/s exactas**: 20 usuarios virtuales con IP
    rotativa (`10.100.x.y`) sobre un runspace pool; por segundo se envían 18
    peticiones válidas + 2 inyectoras de error (400/401/404) contra Users y
    Pharmacy a través del API Gateway (`http://127.0.0.1:5000`).
  - Tokens de sesión con las credenciales sembradas (`admin`, `empleado01`,
    `owner001`, contraseña `Abcdef12.`) para ejercitar endpoints protegidos y
    generar 401 en accesos sin token.
  - Consola en vivo (tasa, 2xx/4xx/5xx/429, latencia media y p95) y evidencia
    persistente en `reports/<timestamp>/`: `traffic.csv` (una fila por segundo)
    y `summary.md` (totales + eventos ejecutados).
  - **Test de rate limiting (criterio de la rúbrica)**: evento `RateLimitBurst`
    dispara 120 requests desde una sola IP (`10.99.99.99`) para saturar el
    límite de 100 req/min y activar el `FailedRequestsThrottlingMiddleware`
    → ola de 429 con header `Retry-After`. El rate limit es por IP: esperar
    ~60 s entre corridas con ese bloque.
  - Port-forward automático al gateway (levanta el forward si no está activo).
  - `Ctrl+C` corta la sesión y el `finally` restaura el cluster (réplicas de
    deployments, selector del Service de la DB, archivos `/tmp` en pods).
  - Para corridas automatizadas acotadas: `$env:CHAOS_DURATION_SEC = "420"`
    corta el motor a los 420 s en forma ordenada; sin la variable corre
    indefinido hasta `Ctrl+C`.

---

## 5. Tareas Pendientes

- [x] **Script de Ingeniería del Caos para Alta Disponibilidad**: `chaos.ps1` (`Implementacion K8S/Codigo/chaos-engineering/`) — game day con tráfico constante de 20 req/s y eventos de caos aleatorios que validan la auto-curación de pods (caídas forzadas), el patrón de mitigación ante solicitudes fallidas (ola de 429 con `Retry-After`, mezcla con requests inválidas), la desconexión de componentes internos (aislamiento del Service de la DB y scale-zero) y la interrupción de tráfico de red (`tc netem loss`). Ctrl+C (o `CHAOS_DURATION_SEC`) restaura el cluster automáticamente y deja la evidencia en `reports/<timestamp>/`.

---

## 6. Entrega 3 — Detección de anomalías, contención y caos

### 6.1 Detección de anomalías (Isolation Forest + SVM RBF)

Implementación en `Implementacion K8S/Codigo/anomaly-detection/`, centrada en la
notebook docente resuelta y ejecutada: `anomaly-detection-notebook.ipynb`
(semilla 42, outputs conservados).

| Requisito de la rúbrica | Dónde se cumple |
|---|---|
| IsolationForest | Sección 6 de la notebook, con submuestreo `contamination` y score `-decision_function` |
| Support Vector Machine con kernel RBF | Sección 7: `OneClassSVM(kernel="rbf", gamma="scale")`, entrenado solo con datos normales |
| Baseline univariado | Sección 4–5: k-sigma y MAD (TODOs del docente resueltos) |
| Comparación y gráficos | Sección 8 |
| Preguntas de cierre | Sección 9 |

Ejecución:

```bash
docker run --rm -v "${PWD}:/app" \
  -w "/app/Implementacion K8S/Codigo/anomaly-detection" \
  python:3.11-slim bash -lc \
  "pip install --no-cache-dir -r requirements-notebook.txt && \
   jupyter nbconvert --to notebook --execute --inplace \
   anomaly-detection-notebook.ipynb"
```

Resultado sobre el dataset del práctico (300 ventanas, 53 anomalías, 17,7 %):

| Detector | Precision | Recall | F1 | Alertas |
|---|---:|---:|---:|---:|
| k-sigma error | 1.000 | 0.189 | 0.317 | 10 |
| k-sigma latencia | 1.000 | 0.151 | 0.262 | 8 |
| MAD error | 0.944 | 0.321 | 0.479 | 18 |
| MAD latencia | 1.000 | 0.679 | 0.809 | 36 |
| Isolation Forest | 0.800 | 0.453 | 0.578 | 30 |
| One-Class SVM RBF | 0.621 | 0.340 | 0.439 | 29 |

El dataset es el que incluye la notebook docente, y la estructura original
(sus secciones y sus TODOs) se conserva.

### 6.2 Plan de gestión y contención de incidentes

Documento: `Implementacion K8S/Codigo/chaos-engineering/PLAN-CONTENCION-INCIDENTES.md`.

El plan sigue la estructura de cinco fases del Incident Management Lifecycle:

- **Prepare:** alcance, inventario/dependencias, roles (Incident Commander,
  Responders, Stakeholders), on-call y escalamiento, matriz de severidad,
  playbooks/runbooks y documentación/tracking.
- **Detect:** Golden Signals, alertas accionables, logs estructurados JSON,
  trazas distribuidas y MTTD.
- **Respond:** confirmación y triaje, War Room, Incident Log, comunicación con
  stakeholders y MTTA.
- **Recover:** rollback, degradación controlada, circuit breaker, rate limiting,
  checklist de validación post-recuperación y MTTR/TTRS.
- **Learn:** blameless postmortem, timeline, causa raíz, corrección vs acción
  correctiva, MTBF/MTBSI y validación con chaos engineering.

Es la única copia del plan: se eliminaron las copias de `docs/` y el contenido
que no formaba parte de esta estructura.

### 6.3 Caos orquestado (Game Day con tráfico constante)

Punto de entrada: `Implementacion K8S/Codigo/chaos-engineering/chaos.ps1`
(ejecución directa `.\chaos.ps1`; Ctrl+C o `$env:CHAOS_DURATION_SEC` corta con
restauración automática).

Engine: **20 req/s constantes** (18 peticiones válidas + 2 inyectoras de error
por segundo, 20 usuarios virtuales con IP rotativa) + **un evento de caos
aleatorio cada 20-25 s**. Evidencia: consola en vivo y `reports/<timestamp>/`
(`traffic.csv` por segundo + `summary.md` con totales y eventos ejecutados).

| Inyección de la rúbrica | Evento de caos |
|---|---|
| Inyección de requests | Mezcla del tráfico (10% inválidas: 400/401/404) + `RateLimitBurst` (ráfaga desde una IP única → 429 con `Retry-After`) |
| Sobrecarga de CPU | `CpuSpike` — busy-loops 20 s en todos los pods de users-service |
| Sobrecarga de memoria | `LowMemory` — 300 MB en pods de pharmacy (límite 384Mi → uso > 85%) |
| Sobrecarga de storage | `DiskFill` — archivo de 500 MB en `/tmp` del gateway |
| Interrupción de tráfico de red | `NetemBlackout` — `tc netem loss 100%` 15 s vía contenedor efímero `chaos-net`; el ReplicaSet recrea los pods con red limpia |
| Desconexión de componentes internos | `DbDisconnect` (Service de SQL aislado) y `ScaleZeroBlackout` (pharmacy a 0 réplicas) |
| Extras del Game Day | `KillPod*` de los 3 microservicios, `LatencySpike` (lock transaccional en SQL) y `DbHeavyQueries` |

Los efectos se observan en la consola y en `traffic.csv`: caída de disponibilidad
durante `DbDisconnect`/`LatencySpike` (5xx en endpoints con BD), `netErr`/p95
elevado durante `NetemBlackout`, ola de 429 en los bursts y auto-curación de los
pods eliminados en segundos. Limpieza de emergencia: `chaos-cleanup.ps1`.

### 6.4 Validación realizada

- Notebook docente ejecutada de punta a punta con Docker/nbconvert; incluye los
  `TODO` resueltos, IsolationForest (sección 6) y One-Class SVM RBF (sección 7),
  comparación y gráficos, conservando las preguntas de cierre. La sección 9
  (preguntas y exit ticket) quedó respondida dentro de la propia notebook,
  citando las tablas y gráficos ejecutados.
- `chaos.ps1` (Game Day de caos, corrida de validación de ~7 min con
  `CHAOS_DURATION_SEC=420`): **6.460 requests a 20 req/s constantes** (tasa
  20/s estable en `traffic.csv`), 3.109 × 2xx, 2.971 × 4xx, 363 × 5xx,
  **2.019 × 429** y 17 errores de red; 9 eventos de caos ejecutados con impacto
  visible en vivo (`RateLimitBurst` ×2, `CpuSpike`, `KillPodGateway` con
  port-forward automático, `NetemBlackout` con p95 hasta 8 s, `LowMemory`,
  `KillPodUsers`, `DbDisconnect` ×2) y restauración limpia del cluster al
  finalizar (cleanup PASS). Evidencia:
  `chaos-engineering/reports/20261108-132640/` (`summary.md` + `traffic.csv`
  por segundo).
- Suite ejecutada con Minikube, `metrics-server` habilitado y datos de
  `Backend/seed-data.sql` aplicados para que login y endpoints protegidos respondan.

### 6.5 Pendientes

- [x] Ejecutar la suite de caos completa contra el cluster local y archivar evidencias.
- [ ] Adjuntar capturas de Grafana/Kibana al informe final.
- [x] Incorporar y resolver la notebook docente de detectores (IF y One-Class SVM RBF).
