# Módulo C — Manual resumido y guion de demostración

> **Qué es esto.** Lo mínimo que hay que saber para entender el Módulo C y para
> grabar el video de sustentación. El detalle técnico completo, incluidos los
> errores que se encontraron y cómo se corrigieron, está en
> `docs/MODULO-C-CAMBIOS.md`.

**Proyecto:** `observabilidad` · `project-546ee9f1-20e7-4368-919`
**Clúster:** `dev-otel-cluster` · `us-central1` · **Subred:** `dev-gke-subnet`
**Cuenta para GCP:** `jorgeayva@unisabana.edu.co`

---

## 1. Qué pedía el punto C y dónde está cada cosa

| Requisito del enunciado | Cómo se cumple | Estado |
|---|---|---|
| Habilitar **VPC Flow Logs (GCP)** | Activados en `dev-gke-subnet`: agregación 30 s, muestreo 1.0, metadatos completos | ✅ Activo |
| Habilitar **VPC Flow Logs (AWS)** | `infrastructure/aws/` — codificado y validado | ⚠️ **No aplicado.** Decisión del equipo: se trabajó sobre GCP y no hay cuenta AWS |
| **Alertas de tráfico anómalo entre servicios** | 6 alert policies (SEC‑1 a SEC‑5, SEC‑7) sobre 10 métricas basadas en logs | ✅ Aplicadas y **verificadas disparando** |
| **Security Command Center *o* Security Hub básico** | Ninguno de los dos está activo. Cobertura por otra vía: GKE Security Posture + Artifact Analysis + Cloud Audit Logs | ⚠️ **Cubierto por sustitución**, no por SCC. Ver §4 |
| **Dashboard "Golden Signals de Seguridad"** | Panel único: auth fallida ✅ · tráfico N‑S/E‑W ✅ · **CVEs ❌ (muestra error)** | ⚠️ **2 de 3 señales con datos.** Ver §4 |

> **Léase con cuidado antes de la sustentación.** El enunciado usa **"y"** en
> los flow logs (*"VPC Flow Logs (GCP) **y** VPC Flow Logs (AWS)"*) y **"o"**
> solo en el de SCC (*"Security Command Center (GCP) **o** AWS Security Hub"*).
> Es decir: los flow logs de AWS **sí** forman parte del enunciado literal, y no
> están desplegados. Conviene declararlo de forma explícita en la entrega y en
> el video, con la justificación (no hay cuenta de AWS; el módulo está escrito y
> validado en `infrastructure/aws/`), en lugar de dejar que el evaluador lo
> descubra.

**Estado honesto: el punto C está cumplido en su parte de GCP y le faltan tres
piezas**, ninguna de ellas resoluble desde el Módulo C: los flow logs de AWS,
la activación de SCC, y la señal de CVEs del dashboard. Las tres, con evidencia
y arreglo, están en `docs/MODULO-C-HALLAZGOS-PARA-EL-EQUIPO.md`.

---

## 2. Qué se desplegó

Todo el Módulo C vive en un **root module de Terraform independiente**,
`infrastructure/gcp-modulo-c/`, con su propio state. Lee la infraestructura de
los Módulos A/B con **data sources**, nunca con `resource`: Terraform no puede
modificar ni destruir lo que solo lee, así que `terraform destroy` aquí borra
únicamente el Módulo C.

| Componente | Detalle |
|---|---|
| VPC Flow Logs | `dev-gke-subnet`, con filtro CEL que excluye los health checkers de Google (ruido constante, ~40 % de los registros) |
| 2 reglas de firewall | `dev-deny-admin-ingress` y `dev-deny-suspicious-egress`. No son decorativas: son **sensores**, cada denegación genera un log |
| 10 métricas basadas en logs | Autenticación fallida (plano de control y workload), tráfico E‑W, N‑S, egress, pares no autorizados, denegaciones de firewall, postura de GKE |
| 6 alert policies | SEC‑1 auth fallida · SEC‑2 tráfico E‑W no autorizado · SEC‑3 desviación de volumen E‑W · SEC‑4 conexiones denegadas · SEC‑5 egress anómalo · SEC‑7 postura de GKE |
| Dashboard | *Golden Signals de Seguridad* |
| `security-exporter` | Deployment en `observability` con Workload Identity propia; publica CVEs activos vía OTLP |

**Enlaces para el video**

- Dashboard: `https://console.cloud.google.com/monitoring/dashboards/builder/c91eb981-9525-4fc8-9aa6-9ba9932e04ed?project=project-546ee9f1-20e7-4368-919`
- Incidentes: `https://console.cloud.google.com/monitoring/alerting/incidents?project=project-546ee9f1-20e7-4368-919`
- Alertas: `https://console.cloud.google.com/monitoring/alerting/policies?project=project-546ee9f1-20e7-4368-919`

---

## 3. Cómo probarlo — guion para el video

Todo desde **Cloud Shell**, con la cuenta de la universidad.

### Paso 0 — Preparar

```bash
P=project-546ee9f1-20e7-4368-919
gcloud config set project $P
gcloud container clusters get-credentials dev-otel-cluster --region us-central1 --project $P
```

### Paso 1 — Mostrar que los VPC Flow Logs están activos

```bash
gcloud compute networks subnets describe dev-gke-subnet \
  --region us-central1 --project $P \
  --format="value(enableFlowLogs, logConfig.aggregationInterval, logConfig.flowSampling, logConfig.metadata)"
```

Debe responder: `True  INTERVAL_30_SEC  1.0  INCLUDE_ALL_METADATA`

### Paso 2 — Mostrar que el Módulo C está desplegado y es idempotente

```bash
cd ~/unisabanaObservabilidad/infrastructure/gcp-modulo-c
terraform state list | wc -l      # ~30 recursos
gcloud alpha monitoring policies list --project $P --format="value(displayName,enabled)"
```

> **Nota:** `terraform plan` siempre reporta **1 cambio** en el dashboard.
> No es deriva real: Google normaliza el JSON del dashboard del lado del
> servidor, así que Terraform ve un diff permanente. Aplicarlo no cambia nada.
> Es un detalle conocido de `google_monitoring_dashboard`, no un pendiente.

### Paso 3 — Inyectar un ataque y verlo detectado (lo importante del video)

Este es el escenario de **movimiento lateral**: un pod intenta abrir conexiones
hacia puertos que no pertenecen a la matriz de comunicación autorizada.

```bash
# 3.1 Crear la sonda
kubectl run modulo-c-probe -n services --image=nicolaka/netshoot \
  --restart=Never --command -- sleep 1800
kubectl wait --for=condition=Ready pod/modulo-c-probe -n services --timeout=180s

# 3.2 Elegir un pod destino que esté en OTRO nodo que la sonda
kubectl get pods -n services -o custom-columns='NAME:.metadata.name,IP:.status.podIP,NODE:.spec.nodeName'
```

> **Por qué el destino debe ser una IP de pod y estar en otro nodo:**
> una conexión a la *ClusterIP* de un Service en un puerto sin backend genera
> flow log **sin** `dest_gke_details` (no hay pod detrás que anotar), y el
> tráfico entre dos pods del **mismo nodo** no aparece en los flow logs porque
> la visibilidad intranodo está desactivada. Cualquiera de las dos cosas hace
> que la prueba "falle" sin que falle nada.

```bash
# 3.3 Inyectar (sustituye IP_DESTINO por la IP del pod elegido)
date '+T0 = %H:%M:%S'
kubectl exec -n services modulo-c-probe -- sh -c \
  'for i in 1 2 3 4 5 6 7 8 9 10; do nc -z -w2 IP_DESTINO 9999; nc -z -w2 IP_DESTINO 6379; done'
```

### Paso 4 — Mostrar la detección

**a) El flujo aparece en Cloud Logging** (~5 min después):

```bash
gcloud logging read 'log_id("compute.googleapis.com/vpc_flows")
  AND jsonPayload.connection.dest_port=9999
  AND jsonPayload.dest_gke_details.pod.pod_namespace="services"' \
  --project $P --freshness=15m --limit 3 \
  --format="value(timestamp, jsonPayload.reporter, jsonPayload.dest_gke_details.pod.pod_name)"
```

**b) Se abre el incidente SEC‑2** (~9 min después de T0): abrir la consola de
incidentes y mostrar `[SEC-2] Tráfico E-W hacia un puerto no autorizado`, con
`src_pod` y `dest_pod` en el detalle. Llega también un correo a
`jorgeayva@unisabana.edu.co`.

**c) El dashboard** refleja el pico en el panel de tráfico E‑W.

### Paso 5 — Limpiar

```bash
kubectl delete pod modulo-c-probe -n services
```

El script `scripts/modulo-c-validacion.sh` automatiza los pasos 3 y 4 —
incluida la elección del pod destino en otro nodo— y mide los tiempos:

```bash
./scripts/modulo-c-validacion.sh $P dev us-central1
./scripts/modulo-c-validacion.sh $P --limpiar
```

---

## 4. Qué NO se hizo, y por qué

> Los defectos ajenos al Módulo C que se encontraron por el camino están
> recogidos, con evidencia y comandos para reproducirlos, en
> **`docs/MODULO-C-HALLAZGOS-PARA-EL-EQUIPO.md`**. Ese es el documento para
> pasarle al equipo.

Dos cosas quedaron fuera. Ninguna es un olvido, y ninguna depende del Módulo C.

**SEC‑6 (alerta de CVE crítico) no se creó.** El `Deployment/otel-collector`
corre con la ServiceAccount `default` del namespace `observability`, sin
anotación de Workload Identity. Con Workload Identity activo en el clúster, ese
pod queda **sin identidad de GCP** y su exporter falla cada 10 s con
`PermissionDenied: monitoring.timeSeries.create denied`. Consecuencia: **ninguna
métrica OTel de ningún servicio del laboratorio llega a Cloud Monitoring** —
solo a Prometheus, por eso Grafana se ve bien y no se había notado.

No es un defecto del Módulo C y el recurso pertenece al Módulo A, así que no se
tocó. SEC‑6 queda escrita en el código detrás de `var.enable_cve_alert = false`
para que `terraform apply` termine limpio en vez de fallar siempre. El
diagnóstico, los comandos exactos y la reversión están en
`infrastructure/gcp-modulo-c/PARCHE-modulo-a.md` §5. El día que se aplique,
activar SEC‑6 es cambiar esa variable a `true`.

**Security Command Center no se activó.** El proyecto sí está dentro de una
organización (`797643117080`), pero **la organización no tiene SCC activado en
ningún nivel** (los 18 servicios están `INHERITED/DISABLED`) y la cuenta no
tiene permisos de SCC sobre la organización. Activarlo tiene implicación de
**costo** sobre un proyecto compartido: es decisión del equipo y de quien
responde por la facturación.

El requisito queda cubierto por la vía que el propio enunciado admite: GKE
Security Posture (gratuito), Artifact Analysis y Cloud Audit Logs alimentan las
mismas señales del dashboard, y **SEC‑7 ya ha abierto incidentes reales** con
hallazgos de configuración de workloads.

---

## 5. Dos cosas que conviene decir en el video

**El MTTD medido es 8 min 51 s, y el objetivo del Módulo D es < 2 min.**
No se cumple, y el desglose dice exactamente por qué: **el 75 % es latencia de
ingesta de VPC Flow Logs**, no configuración nuestra. Bajar el intervalo de
agregación no lo arregla —el cuello de botella es la ingesta, no la agregación—
y multiplicaría el volumen y el costo sin mover la aguja. Para detección en
segundos hace falta telemetría del plano de datos (eBPF / GKE Dataplane V2, o
access logs de un service mesh), que es una decisión de arquitectura, no un
ajuste de umbral. Medición completa en `MODULO-C-CAMBIOS.md` §15.

**Los VPC Flow Logs están activados con `gcloud`, no desde Terraform.**
La subred pertenece al state de los Módulos A/B, así que **el próximo
`terraform apply` de ese módulo los apagará**. Y el fallo sería silencioso: el
Módulo C seguiría aplicándose sin errores, pero todos los paneles de tráfico
quedarían vacíos sin que nada lo explique. La versión declarativa está lista en
`PARCHE-modulo-a.md` §1 opción B y hay que aplicarla desde el state del Módulo
A. Por eso el script de validación **aborta con un mensaje explícito** si los
encuentra apagados, en lugar de reportar un falso "no se detectó nada".
