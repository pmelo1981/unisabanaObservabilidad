# Guía reproducible de Chaos Engineering

Esta guía ejecuta los dos experimentos de la Actividad 3.3: D1 añade 200 ms a
`service-b` mediante Istio y D2 produce 10 % de HTTP 500 mediante el motor de
caos oficial de `data-service`. Existe una única implementación por experimento.

## Seguridad y preparación local

- Usar únicamente el clúster sandbox dedicado.
- Ejecutar D1 y D2 por separado y excluir `/health`.
- Abortar ante pérdida de telemetría o impacto fuera del namespace esperado.
- Confirmar el rollback antes de iniciar el siguiente experimento.

## Recrear el sandbox local desde cero

Con Docker Desktop activo, desde la raíz del repositorio:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.tools\kind.exe create cluster --config .\chaos\local\kind-config.yaml `
  --kubeconfig .\.tools\kubeconfig
$env:KUBECONFIG = (Resolve-Path '.tools\kubeconfig')
kubectl wait --for=condition=Ready node/otel-chaos-control-plane --timeout=180s
```

Instalar Istio y crear namespaces:

```powershell
.\.tools\istio\istio-1.30.3\bin\istioctl.exe install `
  -f .\mesh\istio-operator.yaml -y
kubectl apply -f .\mesh\namespaces.yaml
```

Construir las imágenes consolidadas:

```powershell
docker build -t otel-lab/service-a:modulo-d-local .\services\service-a
docker build -t otel-lab/service-b:modulo-d-local .\services\service-b
docker build -t otel-lab/data-service:modulo-d-local .\services\data-service
```

Cargarlas en kind:

```powershell
.\.tools\kind.exe load docker-image otel-lab/service-a:modulo-d-local `
  --name otel-chaos
.\.tools\kind.exe load docker-image otel-lab/service-b:modulo-d-local `
  --name otel-chaos
.\.tools\kind.exe load docker-image otel-lab/data-service:modulo-d-local `
  --name otel-chaos
```

Desplegar bases, observabilidad y servicios, y luego el mesh estable:

```powershell
.\chaos\local\deploy.ps1 -ExpectedContext kind-otel-chaos
kubectl apply -f .\mesh\data-service-traffic.yaml
kubectl apply -f .\mesh\peer-authentication.yaml
kubectl apply -f .\mesh\peer-authentication-observability.yaml
kubectl apply -f .\mesh\telemetry.yaml
kubectl get pods -A
```

Los servicios de negocio deben quedar `2/2 Running`; el segundo contenedor es
el sidecar Envoy de Istio.

En cada PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$env:KUBECONFIG = (Resolve-Path '.tools\kubeconfig')
kubectl config current-context
```

El resultado debe ser `kind-otel-chaos`. Verificar el entorno:

```powershell
.\chaos\scripts\preflight.ps1 -ExpectedContext kind-otel-chaos
kubectl get pods -A
```

En una terminal exclusiva abrir Prometheus:

```powershell
kubectl port-forward -n observability svc/otel-stack-prometheus-server 19091:80
```

Usar `http://localhost:19091/alerts`. Si el puerto ya está ocupado y la página
abre, reutilizarlo; si no abre, elegir otro puerto local.

En otra terminal abrir Grafana:

```powershell
kubectl port-forward -n observability svc/otel-stack-grafana 13000:80
```

- Prometheus: `http://localhost:19091`
- Alertas: `http://localhost:19091/alerts`
- Grafana: `http://localhost:13000`
- Usuario Grafana: `admin`

Obtener la contraseña de Grafana sin escribirla en archivos:

```powershell
$encoded = kubectl get secret otel-stack-grafana -n observability `
  -o jsonpath="{.data.admin-password}"
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
```

## Cronología formal 1 + 5 + 1

### Terminales necesarias

Usar **cuatro terminales PowerShell**. En cada una ejecutar primero:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$env:KUBECONFIG = (Resolve-Path '.tools\kubeconfig')
kubectl config current-context
```

El contexto debe responder `kind-otel-chaos`.

#### Terminal 1 — Prometheus

```powershell
kubectl port-forward -n observability `
  svc/otel-stack-prometheus-server 19091:80
```

Dejarla abierta sin escribir más comandos. En el navegador abrir
`http://localhost:19091/alerts`.

#### Terminal 2 — Grafana

```powershell
kubectl port-forward -n observability `
  svc/otel-stack-grafana 13000:80
```

Dejarla abierta sin escribir más comandos. En el navegador abrir
`http://localhost:13000`. Esta terminal es opcional durante la corrida: si se
omite, Grafana puede abrirse después para consultar el histórico.

#### Terminal 3 — carga k6

Para D1 ejecutar:

```powershell
.\chaos\local\run-load.ps1 -Experiment d1 `
  -ExpectedContext kind-otel-chaos -Duration 7m -Rate 5 `
  -RunId formal-local-d1
```

Para D2 ejecutar, en una corrida separada:

```powershell
.\chaos\local\run-load.ps1 -Experiment d2 `
  -ExpectedContext kind-otel-chaos -Duration 7m -Rate 10 `
  -RunId formal-local-d2
```

No ejecutar D1 y D2 al mismo tiempo. Dejar esta terminal ocupada hasta que
aparezca `LOAD_FINISHED_UTC`.

#### Terminal 4 — control del experimento

Esta terminal se usa para ejecutar `Validate`, esperar un minuto desde
`LOAD_STARTED_UTC`, ejecutar `Apply`, esperar cinco minutos desde
`*_APPLIED_UTC` y finalmente ejecutar `Rollback`. Los comandos específicos de
D1 y D2 aparecen en sus respectivas secciones más adelante.

El navegador no cuenta como terminal. Con Grafana abierto durante la corrida se
usan cuatro terminales; sin Grafana en vivo bastan tres.

| Momento | Acción |
|---:|---|
| 00:00 | Iniciar carga k6 por siete minutos |
| 01:00 | Aplicar caos y guardar `*_APPLIED_UTC` |
| 01:00–06:00 | Mantener el caos cinco minutos |
| Primer `FIRING` | Guardar hora y captura, sin retirar aún el caos |
| 06:00 | Rollback y `*_ROLLBACK_CONFIRMED_UTC` |
| 07:00 aprox. | Resumen k6 y `LOAD_FINISHED_UTC` |

`MTTD = primera observación FIRING - *_APPLIED_UTC`; debe ser menor de 120 s.
El resumen k6 mezcla baseline, caos y recuperación, por lo que debe acompañarse
de la gráfica de la ventana perturbada.

## D1 — latencia en service-b

Terminal de carga:

```powershell
.\chaos\local\run-load.ps1 -Experiment d1 -ExpectedContext kind-otel-chaos `
  -Duration 7m -Rate 5 -RunId formal-local-d1
```

Un minuto después, en otra terminal:

```powershell
.\chaos\experiments\service-b-latency\run.ps1 `
  -ExpectedContext kind-otel-chaos -Action Validate
.\chaos\experiments\service-b-latency\run.ps1 `
  -ExpectedContext kind-otel-chaos -Action Apply `
  -Confirmation MODULO-D-SANDBOX
```

Cinco minutos después de `D1_APPLIED_UTC`:

```powershell
.\chaos\experiments\service-b-latency\run.ps1 `
  -ExpectedContext kind-otel-chaos -Action Rollback `
  -Confirmation MODULO-D-SANDBOX
kubectl get virtualservice chaos-d1-service-b-latency -n services `
  --ignore-not-found
```

El último comando no debe devolver ningún recurso.

## D2 — errores en data-service

Confirmar primero que el motor esté habilitado para el sandbox pero inactivo:

```powershell
kubectl run chaos-status-check --rm -i --restart=Never -n data-service `
  --image=curlimages/curl:8.12.1 -- `
  curl -fsS http://data-service.data-service.svc.cluster.local:8080/chaos/status
```

Debe indicar `control_enabled: true`, `enabled: false` y `scenario: normal`.
Iniciar carga directa:

```powershell
.\chaos\local\run-load.ps1 -Experiment d2 -ExpectedContext kind-otel-chaos `
  -Duration 7m -Rate 10 -RunId formal-local-d2
```

Un minuto después:

```powershell
.\chaos\experiments\data-service-errors\run.ps1 `
  -ExpectedContext kind-otel-chaos -Action Validate
.\chaos\experiments\data-service-errors\run.ps1 `
  -ExpectedContext kind-otel-chaos -Action Apply `
  -Confirmation MODULO-D-SANDBOX
```

Cinco minutos después de `D2_APPLIED_UTC`:

```powershell
.\chaos\experiments\data-service-errors\run.ps1 `
  -ExpectedContext kind-otel-chaos -Action Rollback `
  -Confirmation MODULO-D-SANDBOX
.\chaos\experiments\data-service-errors\run.ps1 `
  -ExpectedContext kind-otel-chaos -Action Validate
```

La validación debe mostrar todos los pods con `enabled=False` y
`scenario=normal`.

## Evidencias mínimas

1. Contexto y pods saludables.
2. Baseline.
3. D1: `VirtualService` activo; D2: `/chaos/status` con 10 % y HTTP 500.
4. Alerta `FIRING` con hora UTC.
5. Gráfica baseline–caos–recuperación.
6. Resumen k6.
7. Rollback y ausencia de una falla activa.

Los runbooks están en `docs/runbooks/`. Las pruebas de humo existentes no son
la corrida formal. Para GKE continuar con [`gcp/README.md`](gcp/README.md).

La corrida formal local D2 validada con esta implementación está registrada en
[`docs/evidencias/modulo-d/2026-09-01-formal-local-d2/README.md`](../docs/evidencias/modulo-d/2026-09-01-formal-local-d2/README.md).
