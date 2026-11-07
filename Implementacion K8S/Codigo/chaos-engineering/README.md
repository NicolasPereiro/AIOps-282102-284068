# Chaos Engineering — PharmaGo

Escenarios de caos para validar detección, contención y recuperación. El punto de
entrada es **`chaos-ha.ps1`**: un único script autocontenido que orquesta los
6 escenarios de la rúbrica e incluye el generador de tráfico y los helpers de
kubectl/Prometheus. Deja evidencia en `reports/`.

```text
chaos-engineering/
├── chaos-ha.ps1                     ← ÚNICO script de caos (6 escenarios, autocontenido)
├── chaos-cleanup.ps1                ← Limpieza/restauración de emergencia (Recover)
├── PLAN-CONTENCION-INCIDENTES.md    ← Plan operativo (Prepare/Detect/Respond/Recover/Learn)
├── README.md
└── reports/                         ← Evidencia generada por cada corrida (ignorada por git)
```

El plan operativo completo (Prepare, Detect, Respond, Recover y Learn) está en
[`PLAN-CONTENCION-INCIDENTES.md`](PLAN-CONTENCION-INCIDENTES.md). Es la única copia
canónica del plan y vive dentro de la carpeta de código.

## Requisitos

1. Minikube con el stack desplegado:

   ```bash
   minikube start --memory=6144 --cpus=4
   kubectl label node minikube workload=platform --overwrite
   ```

2. Port-forwards activos (en terminales separadas):

   ```bash
   kubectl port-forward -n pharmago svc/pharmago-api-gateway 5000:80
   kubectl port-forward -n pharmago svc/prometheus 9090:9090
   ```

   El primero es obligatorio para `request` y para las verificaciones HTTP.
   El segundo es opcional: sin Prometheus el script sigue funcionando, pero
   algunos escenarios quedan sin métrica y se apoyan en `kubectl`.

3. Base de datos inicializada con `Backend/seed-data.sql` para que existan
   `admin`, `empleado01` y `owner001` (contraseña `Abcdef12.`).

4. PowerShell 7+ recomendado (`pwsh`). También funciona Windows PowerShell 5.1.

## Uso rápido

```powershell
# Simular sin tocar el cluster
.\chaos-ha.ps1 -Scenario all -DryRun

# Todos los escenarios (pide confirmación)
.\chaos-ha.ps1 -Scenario all

# Sin confirmación (CI / demo)
.\chaos-ha.ps1 -Scenario all -Force

# Un escenario puntual (alta intensidad, pico visible)
.\chaos-ha.ps1 -Scenario cpu -Target pharmago-api-gateway -Intensity high -DurationSec 90 -Force
```

Salida esperada:

```text
reports/20261106-120000/
├── summary.json
├── summary.md
├── request/
│   ├── http/requests.csv
│   ├── kubectl/baseline.txt, impact.txt, ...
│   └── prometheus/baseline.json, impact.json
├── cpu/...
├── memory/...
├── storage/...
├── network/...
└── disconnect/...
```

El exit code es `0` si todos los escenarios pasan y `1` si alguno falla.

## Escenarios

| # | `-Scenario` | Qué inyecta | Verificación de impacto | Criterio PASS |
|---|---|---|---|---|
| 1 | `request` | Ráfaga de 200–1000 requests (según intensidad) + rate-limit test con el generador integrado | CSV de requests | `429 > 0` y `5xx = 0` |
| 2 | `cpu` | Bucles de CPU en **todos los pods** del target (`workers` por pod según intensidad) | `container_cpu_usage_seconds_total` o `kubectl top` | CPU ≥ 0.25 cores |
| 3 | `memory` | Asignación concurrente de `${SizeMB}` MB **por réplica** | Memoria working set, `allocated_bytes`, `OOMKilled` | OOM o asignación ≥ 80 % del objetivo |
| 4 | `storage` | `dd` de `${SizeMB}` MB **por réplica** en `/tmp` | `df -m /tmp` antes/durante/pico | Uso de disco crece ≥ 80 % del objetivo o `No space left` |
| 5 | `network` | `tc netem loss 100%` en `eth0` de todos los pods del target (o NetworkPolicy deny-egress) | `up{job=...}` y tasa de 5xx | `up` cae a 0 o aparecen 5xx |
| 6 | `disconnect` | `kubectl scale --replicas=0` o parcheo del selector de un Service | `readyReplicas` / endpoints | Componente no disponible y luego recuperado |
| 7 | `gametime` | Game Day: tráfico **constante de `-Rate` req/s** (20 por defecto) mientras se disparan **eventos de caos aleatorios** (cpu, memoria, pod eliminado, scale-zero, red, latencia, DB, disco, 429) | CSV completo + reporte por evento | Constancia ≥ 90 % de ventanas, ≥ N eventos, impacto visible y recuperación final |

### Intensidad

Los escenarios de cpu, memory y storage estresan **todas las réplicas del deployment a la vez** (jobs concurrentes por pod).

| `-Intensity` | CPU workers/pod | Memoria/pod | Storage/pod |
|---|---:|---:|---:|
| `low` | 2 | 256 MB | 200 MB |
| `medium` | 4 | 384 MB | 500 MB |
| `high` | 8 | 512 MB (OOMKill garantizado) | 1024 MB |

`-SizeMB` sobreescribe el tamaño de memoria/storage. La duración default es 60 s;
usar `-DurationSec 90–120` para una meseta claramente visible en las métricas.

## Ejemplos por escenario

### 1. Request injection

```powershell
# Ráfaga del escenario de la rúbrica (incluye bloque 429)
.\chaos-ha.ps1 -Scenario request -Intensity high -Force

# Carga sostenida (~5 min, sin bloque 429), útil durante rollouts
.\chaos-ha.ps1 -Scenario request -LoadTotalRequests 300 -LoadConcurrency 20 -LoadDurationSec 300 -SkipRateLimitTest -Force

# Game Day: 20 req/s constantes + eventos aleatorios que arden todo
.\chaos-ha.ps1 -Scenario gametime -GameTimeSec 300 -Force
```

El generador integrado (`Invoke-TrafficLoad`) produce tráfico mixto contra Users y
Pharmacy vía API Gateway, con tokens de las credenciales sembradas
(`admin` / `empleado01` / `owner001`, contraseña `Abcdef12.`). El rate limit es de
100 req/min por IP: si corrés el escenario con rate-limit test dos veces seguidas,
esperá ~60 s o el segundo run puede devolver solo `429`. El reporte de la rúbrica
verifica `429 > 0`, `5xx = 0` y la presencia del header `Retry-After`.

### 2. CPU overload

```powershell
.\chaos-ha.ps1 -Scenario cpu -Target pharmago-users-service -Intensity high -DurationSec 90 -Force
```

Golpea todas las réplicas del deployment: 8 busy-loops por pod en `high`.

### 3. Memory overload

```powershell
.\chaos-ha.ps1 -Scenario memory -Target pharmago-pharmacy-service -SizeMB 512 -DurationSec 90 -Force
```

El comando asigna 512 MB por réplica (jobs concurrentes): supera el límite de
384Mi, así que el OOMKill está garantizado en cada réplica; Kubernetes recupera
los pods y el script espera el rollout. En `kubectl/events-*.txt` quedan los
`OOMKilled` y reinicios como evidencia.

### 4. Storage overload

```powershell
.\chaos-ha.ps1 -Scenario storage -Target pharmago-api-gateway -Intensity high -DurationSec 90 -Force
```

Escribe 1 GB por réplica en `/tmp` (total ~2 GB) y limpia al final. El objetivo
es demostrar presión de disco efímero, con evidencia en `df-peak.txt`; no toca
los PVC de SQL Server, Elasticsearch, Prometheus ni Grafana.

### 5. Network interruption

```powershell
# Recomendado en Minikube: contenedor efímero con NET_ADMIN + tc
.\chaos-ha.ps1 -Scenario network -Target pharmago-api-gateway -NetworkMode tc -DurationSec 90 -Force

# Alternativa declarativa (puede no aplicarse con el CNI por defecto de Minikube)
.\chaos-ha.ps1 -Scenario network -Target pharmago-api-gateway -NetworkMode netpol -DurationSec 90 -Force
```

El modo `tc` crea un contenedor efímero `chaos-net` con la imagen
`nicolaka/netshoot` en cada pod del target, aplica
`tc qdisc add dev eth0 root netem loss 100%` y luego borra los pods para eliminar
los contenedores efímeros. Si el pull de la imagen tarda, el script espera hasta
90 s por pod.

El modo `netpol` genera y aplica una NetworkPolicy de egreso vacía (se archiva en
`reports/<run>/network/manifests/`). Con el CNI por defecto de Minikube puede no
tener efecto; en ese caso el reporte lo indica y sugiere usar `tc`.

### 6. Internal component disconnection

```powershell
# Apagar temporalmente un microservicio (Deployment)
.\chaos-ha.ps1 -Scenario disconnect -Target pharmago-pharmacy-service -DisconnectMode scale -DurationSec 90 -Force

# Romper la conectividad al Service de SQL Server sin apagar la DB
.\chaos-ha.ps1 -Scenario disconnect -Target pharmago-db -DisconnectMode service -DurationSec 90 -Force
```

El modo `scale` guarda las réplicas originales y las restaura; equivale a la
validación de auto-curación (self-healing) de la entrega de alta disponibilidad.
El modo `service` guarda el selector original del Service, lo apunta a un label
inexistente y lo restaura. Este último es el más seguro para la DB.

### 7. Game Day (trafico constante + caos aleatorio)

```powershell
.\chaos-ha.ps1 -Scenario gametime -GameTimeSec 600 -Rate 20 -Intensity high -Force
```

- **Trafico constante**: un pacer interno lanza exactamente `1 request cada
  1000/-Rate` ms (50 ms = 20 req/s) durante todo el run, con IP rotativa y
  mezcla de 2xx/4xx. No se bloquea cuando los requests cuelgan (pool de
  runspaces); si un pod muere, los errores de red quedan registrados.
- **Eventos aleatorios** cada 10-25 s (sin repetir el anterior): `cpu-spike`,
  `memory-spike` (OOM con `high`), `kill-pod` (auto-curación), `scale-zero`,
  `db-disconnect` (Service de SQL aislado 25 s), `disk-fill`, `blackout`
  (`tc netem loss 100%`), `latency-spike` (`tc netem delay 2000ms` — la p95
  explota) y `throttle-burst` (ola de 429).
- **Evidencia**: `gametime/traffic/traffic.csv` con `(timestamp, path, code, ms)`
  — la línea plana de 20 req/s con los picos de error encima queda lista para
  Grafana/Excel — y `gametime/events/<n>-<evento>/` con snapshot Prometheus+kubectl
  por evento, más `summary-gametime.md` con la tabla de impacto por evento.
- **PASS**: constancia ≥ 90 % de las ventanas de 10s, mínimo `GameTimeSec/60`
  eventos y al menos un impacto visible (5xx, errores de red, 429, p95 > 1 s),
  con recuperación final limpia (deployment READY + `/health` OK).
- El caos golpea a `-ChaosTarget` (default `pharmago-users-service`), no al
  gateway, para que el port-forward del tráfico sobreviva a los eventos.

## Limpieza de emergencia

```powershell
.\chaos-cleanup.ps1 -Force
.\chaos-cleanup.ps1 -RestoreReplicas -Force
```

Limpia NetworkPolicies con label `chaos=pharmago`, qdiscs `netem`, archivos
`/tmp/chaos_fill` y, opcionalmente, restaura réplicas (`2` para microservicios,
`1` para la DB).

## Evidencia para el informe

Cada escenario deja:

- `prometheus/baseline.json`, `prometheus/impact.json` y `prometheus/peak.json`
  (en escenarios de recursos el snapshot del pico se captura a mitad del estrés)
  con CPU, memoria, red, tasa de 5xx, requests, `up` y espacio de nodo.
- `kubectl/pods-*.txt`, `top-*.txt` (incluye `top-peak.txt` del pico),
  `events-*.txt` y `describe-*.txt`.
- `df-peak.txt` en el escenario de storage.
- `http/requests.csv` en el escenario de requests.
- `gametime/` en el escenario gametime: `traffic/traffic.csv` (timeline con tasa
  por segundo), `events/<n>-<evento>/` (impacto por evento) y `summary-gametime.md`.
- `summary.md` consolidado con PASS/FAIL y detalle.

Para el informe, adjuntar `summary.md`, una captura de Grafana del panel
correspondiente y el `events-*.txt` donde se vea el reinicio/recuperación.

## Seguridad

- No ejecutar contra un cluster que no sea de laboratorio.
- El script rechaza targets en `kube-system`, `default` y `kube-public`.
- `disconnect` restaura réplicas/selector en un bloque `finally`.
- `network` solo borra los pods target después de aplicar `tc`; la limpieza de
  qdiscs y contenedores efímeros se ejecuta en un bloque `finally`.
- `storage` limpia `/tmp/chaos_fill` al final, incluso si el `dd` falla.
