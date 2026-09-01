# Hallazgos para el equipo — encontrados desde el Módulo C

> **Qué es esto.** Defectos que **no pertenecen al Módulo C** pero que lo
> afectan, o que afectan al proyecto entero. No se ha tocado ninguno: el
> recurso es de otro módulo y la decisión es del equipo. Todos están
> verificados contra el proyecto real, con el comando para reproducirlos.
>
> Proyecto: `project-546ee9f1-20e7-4368-919` · Fecha: 2026-09-01

---

## Resumen

| # | Hallazgo | Impacto | Dueño |
|---|---|---|---|
| 1 | El `otel-collector` corre sin identidad de GCP | **Ninguna métrica OTel del laboratorio llega a Cloud Monitoring** | Módulo A |
| 2 | Dos configuraciones distintas del collector; corre la que el repo NO documenta | El prefijo de métricas de GCP se pierde | Módulo A |
| 3 | `data-service` con `RUN_AS_NONROOT` y `PRIVILEGE_ESCALATION` | Hallazgo de seguridad activo | Dueño de `helm/data-service` |
| 4 | VPC Flow Logs activados fuera de Terraform | El próximo `apply` del Módulo A los apaga **en silencio** | Módulo A |
| 5 | Security Command Center no activado en la organización | Requisito del punto C sin cubrir por la vía principal | Equipo + facturación |
| 6 | AWS no desplegado | El enunciado pide GCP **y** AWS para los flow logs | Equipo |

Los hallazgos **1 y 2 juntos** son la razón de que el panel *"CVEs críticos
activos"* del dashboard muestre un error. Ninguno de los dos está en el
Módulo C.

---

## 1. El `otel-collector` corre sin identidad de GCP

El `Deployment/otel-collector` del namespace `observability` usa la
ServiceAccount **`default`**, que no tiene la anotación de Workload Identity.
Con Workload Identity activo en el clúster —y lo está—, el metadata server no
le entrega a esa KSA la identidad del nodo: **el pod queda sin ninguna
identidad de GCP.**

Da igual que `dev-gke-nodes-sa` sí tenga `roles/monitoring.metricWriter`: el
pod nunca llega a usar esa cuenta.

**Reproducir:**

```bash
kubectl logs -n observability deploy/otel-collector --tail=200 | grep googlecloud
```

Devuelve, cada 10 segundos:

```
Exporting failed. Dropping data. {"kind":"exporter","data_type":"metrics",
 "name":"googlecloud","error":"rpc error: code = PermissionDenied
 desc = Permission monitoring.timeSeries.create denied ..."}
```

Y el proyecto no tiene **ni un solo** descriptor `workload.googleapis.com/*`:

```bash
curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  --data-urlencode 'filter=metric.type=starts_with("workload.googleapis.com/")' \
  "https://monitoring.googleapis.com/v3/projects/$PROJECT/metricDescriptors"
```

**Alcance real:** ninguna métrica OTel de `service-a`, `service-b`,
`data-service` ni del `security-exporter` ha llegado nunca a Cloud Monitoring.
Llegan solo a Prometheus, que es el otro exporter del pipeline — **por eso
Grafana se ve bien y nadie lo había notado.**

**Arreglo** (aditivo y reversible; reinicia un pod):

```bash
PROJECT=project-546ee9f1-20e7-4368-919

gcloud iam service-accounts create dev-otel-collector \
  --project=$PROJECT --display-name="OTel Collector"

gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:dev-otel-collector@$PROJECT.iam.gserviceaccount.com" \
  --role="roles/monitoring.metricWriter"

gcloud iam service-accounts add-iam-policy-binding \
  dev-otel-collector@$PROJECT.iam.gserviceaccount.com \
  --project=$PROJECT --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$PROJECT.svc.id.goog[observability/otel-collector]"

kubectl create serviceaccount otel-collector -n observability
kubectl annotate serviceaccount otel-collector -n observability \
  iam.gke.io/gcp-service-account=dev-otel-collector@$PROJECT.iam.gserviceaccount.com
kubectl set serviceaccount deployment/otel-collector otel-collector -n observability
```

**Revertir:** `kubectl set serviceaccount deployment/otel-collector default -n observability`

**Comprobar** (~2 min tras el reinicio): `kubectl logs -n observability deploy/otel-collector --tail=50 | grep -c PermissionDenied` debe dar `0`.

---

## 2. El repo tiene dos configuraciones del collector, y corre la que no documenta

Este es el hallazgo menos obvio y probablemente el más útil.

El repositorio contiene `otel-collector/config-gcp.yaml`, que el `README.md`
(línea 435) presenta como *"Pipeline GKE: OTLP → Jaeger / Prometheus / Cloud
Logging"*, y que `helm/otel-stack/values.yaml` (línea 20) menciona como
*"Configmap con la configuracion del Collector (config-gcp.yaml)"*.

**Ese archivo no se usa.** El que corre es el bloque embebido en
`helm/otel-stack/templates/collector.yaml`, que reimplementa un subconjunto y
**pierde configuración por el camino**:

| Ajuste en `config-gcp.yaml` | ¿Está en el chart que corre? |
|---|---|
| `metric.prefix: "custom.googleapis.com/otel"` | **No** |
| `log.default_log_name` | **No** |
| `log.service_resource_labels` | **No** |
| `metric.instrumentation_library_labels` | **No** |

**Reproducir:**

```bash
grep -n "prefix" otel-collector/config-gcp.yaml
kubectl get cm -n observability otel-collector-config -o jsonpath='{.data.config\.yaml}' | grep -A6 'googlecloud:'
```

El primero muestra el prefijo; el segundo, que en el clúster no está.

**Por qué importa para el Módulo C:** el dashboard y la alerta SEC‑6 consultan
`custom.googleapis.com/otel/security.cves.active`, que es el nombre que
resultaría del prefijo **documentado**. Sin ese prefijo, el exporter
`googlecloud` usa su valor por defecto (`workload.googleapis.com/`) y la
métrica saldría con otro nombre.

Es decir: el Módulo C está alineado con la configuración que el repositorio
declara; lo que no coincide es lo desplegado.

**Decisión que hay que tomar** (cualquiera de las dos cierra el hueco, pero hay
que elegir una y dejarla escrita):

- **a)** Añadir el bloque `metric.prefix` al chart, para que lo desplegado
  coincida con lo documentado. Es la opción coherente con el README.
- **b)** Asumir el prefijo por defecto y **borrar `otel-collector/config-gcp.yaml`**
  o marcarlo como no usado, para que nadie más se guíe por él. En ese caso el
  Módulo C debe cambiar sus dos referencias a
  `workload.googleapis.com/security.cves.active`.

Mientras el repo mantenga dos configuraciones distintas presentándose como una,
este error se volverá a cometer.

---

## 3. `data-service` tiene hallazgos de seguridad activos

GKE Security Posture reporta, en estado `ACTIVE`:

```
RUN_AS_NONROOT         apps/v1/namespaces/services/Deployment/data-service
PRIVILEGE_ESCALATION   apps/v1/namespaces/services/Deployment/data-service
```

Severidad `SEVERITY_MEDIUM`. La alerta **SEC‑7 del Módulo C los está
notificando correctamente** — no es ruido, es la detección funcionando.

**Reproducir:**

```bash
gcloud logging read 'resource.type="k8s_cluster"
  AND jsonPayload.@type="type.googleapis.com/cloud.kubernetes.security.containersecurity_logging.Finding"
  AND jsonPayload.state="ACTIVE"' \
  --project $PROJECT --freshness=12h \
  --format='value(jsonPayload.finding,jsonPayload.resourceName)' | sort -u
```

**Arreglo**, en `helm/data-service`:

```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
```

---

## 4. Los VPC Flow Logs se apagarán con el próximo `apply` del Módulo A

Están activados con `gcloud`, no desde Terraform, porque la subred pertenece al
state de los Módulos A/B y el Módulo C solo la **lee** (data source).

**El próximo `terraform apply` de `infrastructure/gcp/` los apagará.** Y el
fallo sería silencioso: el Módulo C se seguiría aplicando sin errores, pero
todos los paneles de tráfico quedarían vacíos sin que nada lo explique.

La versión declarativa está lista en
`infrastructure/gcp-modulo-c/PARCHE-modulo-a.md` §1 opción B; hay que aplicarla
**desde el state del Módulo A**, no desde aquí.

Mitigación ya implementada: `scripts/modulo-c-validacion.sh` **aborta con un
mensaje explícito** si encuentra los flow logs apagados, en lugar de reportar
un falso *"no se detectó nada"*.

---

## 5. Security Command Center no está activado

Verificado con la API, no supuesto:

| Comprobación | Resultado |
|---|---|
| ¿El proyecto está en una organización? | **Sí**, `797643117080` |
| APIs `securitycenter` y `securitycentermanagement` | Habilitadas |
| API de gestión de SCC con ámbito de proyecto | HTTP **200** — hay acceso |
| Los 18 servicios de SCC | `intended=INHERITED` / `effective=DISABLED` |
| `securitycenter.findings.list` a nivel de organización | **403** para `jorgeayva@unisabana.edu.co` |
| API de findings | *"SCC Legacy has been permanently disabled — migrate to Standard or Premium tier"* |

**La organización no tiene SCC activado en ningún nivel**, y la cuenta del
proyecto no tiene permisos de SCC sobre la organización. Activarlo tiene
**implicación de costo** y requiere permisos de organización: es decisión del
equipo y de quien responde por la facturación.

> Nota: la consola muestra *"No organization"* en el panel del proyecto porque
> la cuenta no puede **leer** el recurso de organización. La jerarquía real se
> consulta con `gcloud projects get-ancestors`.

---

## 6. AWS no está desplegado

El enunciado del punto C dice, literalmente:

> *"Habilitar VPC Flow Logs (GCP) **y** VPC Flow Logs (AWS)."*

Es una **"y"**, no una "o" — a diferencia del punto de SCC, donde sí dice
*"Security Command Center (GCP) **o** AWS Security Hub"*.

`infrastructure/aws/` contiene el módulo completo (`vpc-flow-logs.tf`,
`security-hub.tf`, `alarms-dashboard.tf`), escrito y validado, pero **no
aplicado**: el equipo decidió trabajar sobre GCP y no hay cuenta de AWS.

Es una decisión legítima, pero conviene **declararla explícitamente en la
entrega y en el video** en lugar de dejar que el evaluador la descubra.
