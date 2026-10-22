# Chaos Engineering

Requiere: app en K8s + port-forward activo.

| Script | Uso |
|--------|-----|
| `cpu-spike.sh` | `./cpu-spike.sh [deploy] [seg]` |
| `ram-spike.sh` | `./ram-spike.sh [deploy] [MB]` |
| `volume-spike.sh` | `./volume-spike.sh [deploy] [MB]` |
| `load-requests.sh` | `./load-requests.sh [N] [url]` |
| `traffic-generator.ps1` | `.\traffic-generator.ps1 [-TotalRequests 200] [-Concurrency 10] [-DelayMs 0]` |
| `chaos-ha.ps1` | `.\chaos-ha.ps1 [-Deployment pharmago-api-gateway] [-SelfHealTimeoutSec 90] [-FailedRequestCount 60] [-SkipSelfHeal] [-SkipMitigation]` |

Default deploy: pharmago-api-gateway

### traffic-generator.ps1
Genera trafico mixto (200 y 4XX: 400, 401, 404, 429) contra Users y Pharmacy via API Gateway.
Requiere port-forward activo. Obtiene tokens de sesion usando las credenciales sembradas
(admin / empleado / duenio). Exporta el detalle a `traffic-results.csv`.

Notas:
- El gateway aplica rate limiting (100 req/min por IP). Ejecuciones muy seguidas pueden
  devolver solo 429. Espera ~60 s entre corridas o usa `-DelayMs` para espaciar las peticiones.
- Los endpoints protegidos usan los tokens obtenidos al inicio (login directo al servicio Users).

**Ver impacto en Grafana:** Dashboard "PharmaGo - Infra" → paneles "CPU por pod (pharmago)" y "Memoria por pod (pharmago)".

### chaos-ha.ps1
Valida la Alta Disponibilidad de forma automatizada:

1. **Auto-curación (Self-Healing):** elimina un pod del deployment indicado y verifica que
   Kubernetes levante una nueva replica en estado READY (1/1) dentro del timeout
   (-SelfHealTimeoutSec, default 90s), mientras el Service sigue respondiendo (/health).
   Valida liveness/readiness probes y la estrategia RollingUpdate.

2. **Mitigacion ante fallas reiteradas:** envia requests fallidas (login invalido) contra el
   API Gateway y verifica que se active el FailedRequestsThrottlingMiddleware devolviendo
   HTTP 429 Too Many Requests (con header Retry-After).

Parametros principales: -Deployment, -Namespace, -BaseUrl, -SelfHealTimeoutSec,
-FailedRequestCount, -Concurrency, -DelayMs, -SkipSelfHeal, -SkipMitigation.

Requiere port-forward activo. El test de mitigacion consume el rate limit del gateway:
esperar ~60 s entre corridas o usar -DelayMs.
