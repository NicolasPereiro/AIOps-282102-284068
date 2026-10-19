# Chaos Engineering

Requiere: app en K8s + port-forward activo.

| Script | Uso |
|--------|-----|
| `cpu-spike.sh` | `./cpu-spike.sh [deploy] [seg]` |
| `ram-spike.sh` | `./ram-spike.sh [deploy] [MB]` |
| `volume-spike.sh` | `./volume-spike.sh [deploy] [MB]` |
| `load-requests.sh` | `./load-requests.sh [N] [url]` |
| `traffic-generator.ps1` | `.\traffic-generator.ps1 [-TotalRequests 200] [-Concurrency 10] [-DelayMs 0]` |

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
