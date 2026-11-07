# Plan de gestión de incidentes — PharmaGo

Plan de incidentes para el stack PharmaGo sobre Kubernetes/Minikube, siguiendo la
estructura de cinco fases del **Incident Management Lifecycle**. Está adaptado a
**2 integrantes** y sirve como guía operativa durante los game days de caos.

**Alcance:** API Gateway, Users Service, Pharmacy Service, Frontend Angular,
SQL Server y la capa de observabilidad (Prometheus, Grafana, OTEL Collector).  
**Coordinación entre integrantes:** notificaciones de Grafana + llamada directa o
grupo de mensajería; War Room remota.  
**Revisión:** al cerrar cada incidente SEV-1/SEV-2 y después de cada game day.

---

## 1. Prepare (Preparación previa al fallo)

El objetivo de esta etapa es estar listos **antes** de que ocurra la falla, para
reducir la incertidumbre. La calidad de la respuesta del equipo depende casi por
completo de la preparación previa.

### 1.1 Definición de roles y responsabilidades

Con un equipo de **2 personas**, los roles son funcionales (no jerárquicos): cada
integrante asume un rol principal durante el incidente y se intercambian según la
carga de trabajo. La asignación se hace por guardia, no por senioridad.

| Rol | Responsabilidad | Quién lo asume |
|---|---|---|
| **Incident Commander (IC)** | Toma las decisiones operativas, coordina la respuesta, mantiene la línea de tiempo y concentra la comunicación. No investiga en detalle para no perder la vista del incidente. | Integrante en guardia activa (ver 1.2). |
| **Responders** | Investigan la telemetría, diagnostican la causa y ejecutan los comandos de mitigación (`kubectl`, consultas de Prometheus, logs, etc.). | El integrante que **no** está en IC. |
| **Stakeholders** | Reciben informes de estado y avales tipo "go/no-go" para acciones de mayor impacto (rollback, corte de tráfico), sin intervenir en la operación técnica. | En este proyecto: el docente / evaluador. |

### 1.2 Rotación de guardia (on-call)

Con 2 integrantes se usa una **rotación semanal alternada**:

- **Semana impar:** Integrante 1 = IC (`on-call`, canal de alertas); Integrante 2 = Responder principal.
- **Semana par:** Integrante 2 = IC; Integrante 1 = Responder principal.
- Escalamiento mínimo (sin PagerDuty): las alertas de Grafana/Prometheus llegan a la
  persona en guardia; si no responde en **15 min**, el otro integrante toma el rol
  de IC por defecto. No hay cadena jerárquica adicional.
- Cambio de guardia: brief de 5 min al inicio de cada semana (estado del sistema,
  alertas pendientes y tareas en curso).

### 1.3 Matriz de severidad e impacto

Criterios objetivos para clasificar el incidente al confirmarlo, en base a la
criticidad del servicio afectado, el impacto en usuarios y la violación de
**SLOs/SLAs** del stack PharmaGo.

| Severidad | Criterio | Escalamiento / siguiente acción |
|---|---|---|
| **SEV-1** | Servicio core indisponible o degradación severa: API Gateway caído, >50 % de requests con 5xx, SQL Server caído, caída de la DB que bloquea Users/Pharmacy. Violación crítica del SLO. | War Room inmediata; rollback o contención agresiva; informar al stakeholder en <10 min. |
| **SEV-2** | Degradación notable pero parcial: >10 % de 5xx, latencia p95 sostenida alta, saturación real de CPU/memoria, desconexión parcial de un componente. | Tratamiento inmediato dentro de la guardia; War Room opcional; informe a stakeholder en <30 min. |
| **SEV-3** | Degradación sin impacto perceptible en usuarios: alerta de capacidad, latencia marginal, warning no crítico, perturbación interna parcial. | Gestión dentro de la semana actual; acción de mejora (sin urgencia). |

Criterio general: la severidad se asigna según el **impacto real en usuarios** y
la **violación de un SLO/SLA**, no según la dificultad técnica de diagnosticarlo.

### 1.4 Playbooks (Runbooks)

Guías paso a paso para los escenarios más probables del stack. Cada playbook define
pasos ordenados, responsable asignado y comandos de mitigación concretos. Los
escenarios se validan en los game days de caos ejecutados con `chaos-ha.ps1`.

| Escenario | Pasos recomendados | Responsable | Acciones de mitigación (comandos) |
|---|---|---|---|
| **Saturación de base de datos** | Revisar `up` y `container_memory_working_set_bytes` de `pharmago-db`; evaluar consultas lentas y pool de conexiones. | Responder (IC supervisa) | `kubectl rollout restart deployment/pharmago-db -n pharmago` para liberar conexiones; verificar estado y tablas. |
| **Fallas en cascada** | Confirmar si el origen fue un microservicio o la DB; revisar trazas/logs para ver la cadena; contener el flujo desde la capa más alta afectada. | IC + Responder | Aplicar rate limiting (HTTP 429) para contener la entrada; `kubectl scale deployment <svc> -n pharmago --replicas=0` como opción extrema para aislar. |
| **Degradación de dependencias** | Identificar la dependencia (Users/Pharmacy) con latencia alta; evaluar Circuit Breaker en API Gateway; degradar de forma controlada. | IC | Habilitar o reforzar rate limiting; abrir circuito en la ruta afectada; aislar el componente sin caer el core. |
| **Saturación de recursos** | Identificar el pod objetivo (CPU/memoria/storage); confirmar vía `kubectl top pods`; decidir rollback o contención. | Responder | Si es un workload no crítico, escalar réplicas; si es core y hubo deploy reciente, `kubectl rollout undo deployment/<target> -n pharmago`. |
| **Saturación de tráfico** | Identificar origen (tormenta de requests o retry); esperar a que el API Gateway aplique rate limiting; registrar el patrón de tráfico. | IC | Con el rate limiter activo, observar `429` en `chaos-ha.ps1 -Scenario request`; ajustar límites si es necesario. |
| **Caída de un pod o componente** | Confirmar con `kubectl get pods` y timeline de eventos; revisar restart count y readiness; ver trazas/logs. | Responder | `kubectl delete pod <pod> -n pharmago` para validar self-healing del Deployment; si persiste, rollback. |

El IC confirma los pasos completados. Si un integrante no está disponible, el otro
asume ambos roles y reduce el alcance de los pasos no críticos.

### 1.5 Documentación y tracking

- **Documentación:** este archivo junto con `README.md` del módulo de caos; la
  evidencia de caos vive en `reports/<timestamp>/`. No se replica en
  Confluence/Notion: el repositorio Git es la única fuente de verdad.
- **Tracking:** cada acción correctiva o mejora se registra como issue y commit en
  Git (GitHub Issues). Sin Jira/Linear: el volumen de tareas para 2 personas no lo
  justifica.

---

## 2. Detect (Detección temprana y telemetría)

El objetivo es reducir el **MTTD** (Mean Time to Detect): identificar la falla
antes de que impacte masivamente o de que la reporten los usuarios.

### 2.1 Monitoreo de las Golden Signals (Google SRE)

| Golden Signal | Métrica en el stack PharmaGo | Qué vigilar |
|---|---|---|
| **Latencia** | Duración de requests en API Gateway / microservicios, especialmente `p95` | Cambios bruscos en percentiles de cola |
| **Tráfico** | Requests por ruta / servicio, requests/s, conexiones concurrentes | Caída o crecimiento anómalo de tráfico |
| **Errores** | Tasa de HTTP 5xx (gateway + microservicios), `pharmago_http_requests_total{status_code=~"5.."}` | Exceso de errores que representen degradación real |
| **Saturación** | CPU, memoria, disco por pod; colas y pools de conexiones hacia SQL Server | Alerta de capacidad antes de quedarse sin margen |

### 2.2 Alertas automáticas y accionables

Las alertas se derivan en tiempo real con **Prometheus / Grafana** y se asocian
directamente a los **SLI/SLO** del sistema (por ejemplo, "99 % de requests con
latencia <1 s", "99,9 % de disponibilidad del API Gateway").

Estructura mínima de una alerta:

1. **Métrica observable** (ej. `up{job="api-gateway"}`).
2. **Umbral crítico** (ej. `up == 0`).
3. **Ventana temporal de evaluación** (ej. `for: 2 min`).
4. **Acción inmediata recomendada** (ej. "revisar pods del Deployment y aplicar rollback").

### 2.3 Logs estructurados (JSON)

Logs centralizados de los microservicios con atributos obligatorios:

- `timestamp` en **UTC**
- `level` (`INFO`, `WARN`, `ERROR`)
- `service` (microservicio que lo emite)
- `message` (texto legible)
- `context` de negocio (id de usuario, endpoint, recurso afectado)
- `correlation_id` / `trace_id` para correlacionar eventos entre microservicios

Los logs se procesan con **Fluent Bit** y se consumen en **Elasticsearch/Kibana**.

### 2.4 Trazas distribuidas

El stack usa **OpenTelemetry Collector** para emitir trazas. Los headers HTTP
(`traceparent`, `tracestate`/W3C) propagan el `trace_id` a través del API Gateway
y los microservicios para reconstruir la causalidad y el recorrido completo de la
solicitud de punta a punta.

---

## 3. Respond (Respuesta, coordinación y contención)

El objetivo es medir la capacidad de coordinación organizacional vía **MTTA**
(Mean Time to Acknowledge): confirmar el problema y empezar a trabajar de forma
coordinada lo antes posible.

### 3.1 Confirmación formal y triaje

1. Al recibir la alerta (evento de la guardia), el IC verifica los hechos en la
   telemetría (dashboards, logs, trazas) antes de confirmar el incidente.
2. Se asigna **severidad** según la matriz 1.3.
3. Se abre el **Incident Log** (3.3) con la primera descripción del síntoma.
4. Se define si se abre la War Room de inmediato (SEV-1) o se gestiona en guardia
   (SEV-2/SEV-3).

### 3.2 War Room

Con solo 2 personas, la "sala" es una **llamada o reunión compartida** (Discord,
Meet o llamada) con ambos integrantes sincronizando en vivo. Reglas:

- Un único canal de coordinación; toda discusión técnica se centraliza ahí.
- **Roles estrictamente diferenciados:** el IC dirige la llamada, asigna tareas y
  aísla la operación técnica; el Responder investiga y ejecuta comandos.
- Nada de discusiones paralelas: toda decisión y todo dato técnico se anota en el
  **Incident Log** con marca temporal.

### 3.3 Registro de eventos en tiempo real (Incident Log)

Documento compartido entre los 2 integrantes (por ejemplo, un archivo Markdown
editado en un VS Code Live Share o un Google Doc). Campos mínimos:

- **Timestamp** de inicio del problema y de la detección.
- **Descripción concisa del síntoma** (qué se ve, qué se espera).
- **Servicios y componentes afectados.**
- **Nivel de severidad asignado.**
- **Decisiones tomadas** y **acciones ejecutadas**, cada una con marca temporal.
- **Estado del checklist de recuperación**, al cierre del incidente.

### 3.4 Comunicación continua con Stakeholders

En este proyecto el stakeholder es el docente/evaluador. Protocolo:

- **SEV-1 / SEV-2:** informe breve por mensaje o issue con estado actual, acciones
  ejecutadas y tiempo estimado de recuperación.
- **SEV-3:** se menciona en el próximo informe de avance; no requiere aviso urgente.
- **Nunca bloquear la operación técnica por una consulta del stakeholder:** quien
  coordina responde con un resumen breve; quien ejecuta no se interrumpe.

---

## 4. Recover (Mitigación y restauración del servicio)

El objetivo es restaurar la operatividad lo antes posible para minimizar el
**MTTR / TTRS** (Time to Restore Service). Mitigar el impacto **no** siempre exige
encontrar la causa raíz de inmediato.

### 4.1 Estrategias de mitigación inmediata

1. **Rollback rápido** — si el fallo coincidió con un deploy reciente:
   `kubectl rollout undo deployment/<target> -n pharmago`
   para volver a la imagen anterior estable.
2. **Degradación controlada (Graceful degradation)** — desactivar funcionalidades
   no críticas (por ejemplo, features accesorias del frontend) manteniendo operativas
   las funciones centrales del producto.
3. **Aislamiento de fallas (Circuit Breaker)** — abrir circuitos en la ruta hacia
   una dependencia lenta o degradada, para evitar saturación en cascada hacia otros
   servicios.
4. **Control de tráfico en el borde (Rate Limiting)** — aplicar o ajustar
   **Token Bucket** en el API Gateway para rechazar exceso de carga con código
   HTTP `429` y frenar tormentas de reintentos (`retry storms`). El stack ya
   incluye este mecanismo, además del middleware de throttling de requests
   fallidas (`FailedRequestsThrottlingMiddleware`).

### 4.2 Validación de estabilidad post-recuperación (Checklist)

Antes de declarar el incidente resuelto, verificar:

- [ ] ¿El servicio y sus endpoints principales volvieron a responder correctamente?
- [ ] ¿Las tasas de error y los percentiles de latencia volvieron a sus líneas base (`steady state`)?
- [ ] ¿Los usuarios siguen percibiendo algún tipo de afectación?

Solo cuando las tres respuestas son afirmativas el IC declara el incidente
**restaurado** y cierra la War Room.

---

## 5. Learn (Aprendizaje y mejora continua)

Esta etapa transforma los incidentes en mejoras arquitectónicas y sistémicas para
elevar el **MTBF** (Mean Time Between Failures) y evitar que la falla se repita.

### 5.1 Blameless Postmortem (Análisis sin culpa)

Documento escrito en Markdown tras cada SEV-1/SEV-2, centrado en las debilidades
del sistema, los procesos y las herramientas; nunca en señalar personas.

Estructura mínima:

- **Qué ocurrió:** resumen técnico del incidente.
- **Impacto:** duración total de la indisponibilidad, porcentaje de usuarios
  afectados, pérdida de transacciones (si aplica).
- **Línea de tiempo (timeline):** `t_start`, `t_detect`, `t_ack`, `t_repair`,
  `t_restore`.
- **Causa raíz:** diagnóstico técnico profundo de los factores causales.
- **Acciones correctivas:** plan de tareas preventivas con **dueños** y **plazos**
  para eliminar la causa raíz.

### 5.2 Corrección vs. Acción Correctiva

- **Corrección (fix / workaround):** devuelve el servicio al estado operativo;
  reduce el `MTTRestore` en el momento, pero no elimina la causa raíz.
- **Acción correctiva:** cambio estructural (configuración, código, arquitectura o
  herramienta) que elimina la causa raíz, incrementa el `MTBF` / `MTBSI` y previene
  que el mismo incidente vuelva a ocurrir.

### 5.3 Validación mediante Ingeniería del Caos (Chaos Engineering)

Diseñar y ejecutar experimentos controlados para validar de forma proactiva que
las alertas, los playbooks y los mecanismos de autorrecuperación responden como
está documentado en el plan. Se inyectan fallas con:

- **Saturación de CPU / memoria / storage en pods.**
- **Corte de tráfico de red** (`tc netem` o NetworkPolicy).
- **Caída forzada de pods / desconexión de componentes internos.**

El orquestador `chaos-ha.ps1` ejecuta esos experimentos y deja evidencia en
`reports/<timestamp>/summary.md`; ese reporte es la entrada directa al postmortem
de la sección 5.1 y a las acciones correctivas de la sección 5.2.
