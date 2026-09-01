# Repetición del Módulo D en GCP/GKE

Estado: **procedimiento preparado, pendiente de validar en un sandbox GCP**.
No debe presentarse como evidencia ejecutada hasta completar todos los pasos.

## Prerrequisitos

- Proyecto sandbox y costos autorizados.
- APIs de GKE, Artifact Registry, Cloud SQL, Logging y Monitoring habilitadas.
- `gcloud`, Terraform, `kubectl`, Helm, Istio y Docker disponibles.
- Ninguna carga ajena al laboratorio en el clúster.

Usar variables explícitas; no copiar IDs históricos del README:

```powershell
$GcpProject = 'REEMPLAZAR_PROJECT_ID'
$GcpRegion = 'us-central1'
$GkeCluster = 'REEMPLAZAR_CLUSTER'
gcloud config set project $GcpProject
gcloud container clusters get-credentials $GkeCluster `
  --region $GcpRegion --project $GcpProject
$GkeContext = (kubectl config current-context).Trim()
```

## Infraestructura

La IaC está en `infrastructure/gcp`. Revisar costos y el plan antes de aplicar:

```powershell
$env:TF_VAR_project_id = $GcpProject
$env:TF_VAR_region = $GcpRegion
$env:TF_VAR_environment = 'dev'
$env:TF_VAR_db_password = Read-Host 'Password temporal Cloud SQL'
terraform -chdir=infrastructure/gcp init
terraform -chdir=infrastructure/gcp plan -out=tfplan
terraform -chdir=infrastructure/gcp apply tfplan
```

No versionar contraseñas ni `tfplan`. Construir las tres imágenes con tags
inmutables y desplegar namespaces, Istio, OTel stack y servicios mediante los
charts/manifiestos del repositorio. En el sandbox del Módulo D desplegar
`data-service` con `--set chaosControl.enabled=true`; fuera del sandbox conservar
el valor predeterminado `false`. Confirmar sidecars `2/2 Running`.

## Preflight y baseline

```powershell
kubectl config current-context
.\chaos\scripts\preflight.ps1 -ExpectedContext $GkeContext
istioctl analyze --all-namespaces
```

Medir al menos diez minutos de baseline en GKE antes de fijar el umbral D1. El
umbral local de 200 ms no debe copiarse si el baseline GCP es diferente.
Verificar además que `/chaos/status` de `data-service` esté en `normal`.

## Alertas

Usar un solo backend para medir MTTD:

- Prometheus: reglas de `chaos/observability`.
- Cloud Monitoring: políticas PromQL equivalentes.

Registrar intervalos de scrape/alineación/evaluación y probar el canal de
notificación antes del game day. Medir por separado detección y entrega.

## Ejecución

`run-load.ps1` conserva el kubeconfig actual cuando el contexto no es local.

```powershell
.\chaos\local\run-load.ps1 -Experiment d1 -ExpectedContext $GkeContext `
  -Duration 7m -Rate 5 -RunId formal-gcp-d1

.\chaos\local\run-load.ps1 -Experiment d2 -ExpectedContext $GkeContext `
  -Duration 7m -Rate 10 -RunId formal-gcp-d2
```

Ejecutar los experimentos por separado siguiendo la cronología 1 + 5 + 1 de
`chaos/README.md` y pasando `$GkeContext` a `Validate`, `Apply` y `Rollback`.

## Cierre

1. Confirmar que D1 no deja fallas Istio y D2 queda en `scenario=normal`.
2. Confirmar métricas en baseline y alertas resueltas.
3. Guardar horas UTC, gráficas, configuración efectiva y salida k6.
4. Destruir recursos solo con autorización del dueño del sandbox.

Reportar local y GCP por separado; no asumir resultados equivalentes.
