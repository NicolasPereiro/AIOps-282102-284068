<#
.SYNOPSIS
    Limpieza de emergencia para los escenarios de caos.

.DESCRIPTION
    - Borra NetworkPolicies con label chaos=pharmago.
    - Quita qdisc netem de pods con contenedor efímero chaos-net.
    - Borra /tmp/chaos_fill de los pods.
    - Opcionalmente restaura réplicas de los deployments.

.EXAMPLE
    .\chaos-cleanup.ps1 -Force

.EXAMPLE
    .\chaos-cleanup.ps1 -RestoreReplicas -Force
#>

[CmdletBinding()]
param(
    [string]$Namespace = "pharmago",
    [string]$Target = "",
    [switch]$RestoreReplicas,
    [switch]$Force
)

$ErrorActionPreference = "Continue"

# Helpers de consola (equivalentes a los del orquestador; archivo autocontenido).
function Write-Section([string]$Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text)      { Write-Host "  [PASS] $Text" -ForegroundColor Green }
function Write-Fail([string]$Text)    { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text)    { Write-Host "  $Text" -ForegroundColor Gray }
function Write-Warn([string]$Text)    { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }

function Assert-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Falta el comando '$Name' en PATH."
    }
}

Assert-Command "kubectl"

if (-not $Force) {
    Write-Warn "Se van a limpiar artefactos de caos en el namespace '$Namespace'."
    $answer = Read-Host "Escribí CLEAN para continuar"
    if ($answer -ne "CLEAN") {
        Write-Info "Cancelado."
        exit 0
    }
}

Write-Section "NetworkPolicies"
$policies = kubectl get networkpolicy -n $Namespace -l chaos=pharmago -o name 2>$null
if ($policies) {
    kubectl delete networkpolicy -n $Namespace -l chaos=pharmago --ignore-not-found 2>&1 | Out-Host
} else {
    Write-Info "No hay NetworkPolicies de caos."
}

Write-Section "Pods con chaos-net / archivos temporales"
$podJson = kubectl get pods -n $Namespace -o json 2>$null | Out-String
if ($podJson) {
    $pods = ($podJson | ConvertFrom-Json).items
    foreach ($pod in $pods) {
        $name = $pod.metadata.name
        if ($Target -and $name -notlike "$Target*") { continue }
        $ephemeral = @($pod.spec.ephemeralContainers) | ForEach-Object { $_.name }
        if ($ephemeral -contains "chaos-net") {
            Write-Info "Quitando netem de $name"
            kubectl exec -n $Namespace $name -c chaos-net -- tc qdisc del dev eth0 root 2>$null | Out-Null
            Write-Info "Recreando $name para eliminar el contenedor efímero"
            kubectl delete pod $name -n $Namespace --wait=false 2>$null | Out-Host
        }
        kubectl exec -n $Namespace $name -- rm -f /tmp/chaos_fill 2>$null | Out-Null
    }
}

if ($RestoreReplicas) {
    Write-Section "Restaurando réplicas"
    foreach ($deployment in @(
        "pharmago-api-gateway",
        "pharmago-users-service",
        "pharmago-pharmacy-service",
        "pharmago-ui"
    )) {
        kubectl scale deployment $deployment -n $Namespace --replicas=2 2>&1 | Out-Host
    }
    kubectl scale deployment pharmago-db -n $Namespace --replicas=1 2>&1 | Out-Host
}

Write-Section "Estado final"
kubectl get pods -n $Namespace -o wide 2>&1 | Out-Host
kubectl get networkpolicy -n $Namespace 2>$null | Out-Host
Write-Ok "Limpieza completada."
