# Chaos Engineering — PharmaGo

Escenarios de caos para validar detección, contención y recuperación. El punto de
entrada es **`chaos.ps1`**: un único script autocontenido que genera tráfico constante
de 20 req/s simulando 20 usuarios (90% respuestas 200 OK y 10% errores 4xx) mientras
dispara eventos de caos aleatorios en paralelo, con auto-reconexión de port-forward y
monitoreo segundo a segundo en vivo por terminal.

```text
chaos-engineering/
├── chaos.ps1                     ← Script principal de caos (20 req/s 90/10 + 12 eventos aleatorios (incluye spike a 100 req/s))
├── chaos-cleanup.ps1             ← Limpieza/restauración de emergencia (Recover)
├── PLAN-CONTENCION-INCIDENTES.md ← Plan operativo (Prepare/Detect/Respond/Recover/Learn)
└── README.md
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

2. Despliegue de la aplicación aplicado (la base de datos se inicializa automáticamente con `seed-data.sql` en el paso 10):

   ```powershell
   cd ..\k8s
   .\apply-k8s.ps1
   ```

3. PowerShell 7+ o Windows PowerShell 5.1.

## Uso rápido

El script está 100% preconfigurado y no requiere parámetros ni decoradores de entrada:

```powershell
.\chaos.ps1
```

## Cómo funciona

- **Port-forward automático**: si `127.0.0.1:5000/health` no responde, el script
  levanta el forward al gateway solo y reintentos en cada caída de pod.
- **20 usuarios virtuales** (`User-01`…`User-20`, IP rotativa `10.100.x.y`) sobre
  un runspace pool; timeout de 8 s por request.
- **Mezcla por segundo**: 18 peticiones válidas (90 %, con tokens de los roles
  sembrados `admin`/`empleado01`/`owner001`) + 2 inyectoras de error (400/401/404).
- **Consola en vivo** segundo a segundo: tasa, 2xx/4xx/5xx/429, latencia media y
  p95, acumulados de la sesión.
- **Un evento de caos aleatorio cada 20-25 s** (sin repetir el anterior).
- **Ctrl+C para cortar**: el `finally` drena el pool, restaura réplicas de los
  deployments, el selector del Service de la DB y borra archivos temporales en
  pods; al final imprime el resumen de la corrida.
- **Evidencia en `reports/<timestamp>/`** (ignorada por git): `traffic.csv`
  con una fila por segundo (tasa, 2xx/4xx/5xx/429/netErr, avg/p95) y
  `summary.md` con el total de requests, códigos y la lista de eventos ejecutados.

## Eventos de caos disponibles (se sortean aleatoriamente)

| Evento | Inyección |
|---|---|
| `KillPodGateway` / `KillPodUsers` / `KillPodPharmacy` | caída de pod aleatorio (auto-curación del ReplicaSet) |
| `CpuSpike` | busy-loops al 100 % en todos los pods de users-service (20 s) |
| `LowMemory` | buffer de 300 MB en pods de pharmacy (límite 384Mi → uso > 85 %) |
| `DiskFill` | archivo de 500 MB en `/tmp` de un pod del gateway + limpieza |
| `NetemBlackout` | `tc netem loss 100%` 15 s (**interrupción de tráfico de red**) vía contenedor efímero; el ReplicaSet recrea los pods con red limpia |
| `DbDisconnect` | Service `pharmago-db` aislado 15 s (selector a label inexistente) |
| `LatencySpike` | lock transaccional `TABLOCKX` + `WAITFOR DELAY` 15 s en SQL Server |
| `DbHeavyQueries` | consulta con producto cartesiano para saturar la BD |
| `RateLimitBurst` | 120 peticiones instantáneas desde la IP `10.99.99.99` → ola de 429 |
| `ScaleZeroBlackout` | pharmacy-service escalado a 0 réplicas por 15 s |

## Cobertura de la rúbrica (escenarios de caos)

| Requisito | Evento / mecanismo |
|---|---|
| Inyección de requests | mezcla 10 % de requests inválidas en el tráfico + `RateLimitBurst` (429 con header `Retry-After`) |
| Sobrecarga de CPU | `CpuSpike` |
| Sobrecarga de memoria | `LowMemory` (300 MB / 384Mi) |
| Sobrecarga de storage | `DiskFill` (500 MB) |
| Interrupción de tráfico de red | `NetemBlackout` (tc netem loss 100 %) |
| Desconexión de componentes internos | `DbDisconnect` (Service selector) y `ScaleZeroBlackout` (scale 0) |

## Corrida acotada (para automatizar o grabar evidencia)

```powershell
$env:CHAOS_DURATION_SEC = "420"; .\chaos.ps1
```

A los 420 s el motor corta solo (mismo `finally`: restauración + resumen + reporte).
Sin la variable, corre indefinido hasta `Ctrl+C`.

## Limpieza de emergencia

```powershell
.\chaos-cleanup.ps1 -Force
```

Limpia NetworkPolicies con label `chaos=pharmago`, qdiscs `netem` residuales y
archivos `/tmp/*` de caos, y restaura réplicas de los deployments.
