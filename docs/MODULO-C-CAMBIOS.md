# Módulo C — Registro de cambios y guía de reversión

> Documento de control. Qué se tocó, qué **no** se tocó, qué se activa en GCP y
> cómo deshacer cada cosa. Escrito para que cualquiera del equipo pueda
> revertirlo entero sin preguntar.

**Autor:** Jorge Andrés Ayala · **Rama:** `modulo-c-network-security` · **Base:** `28ca467` · **Fecha:** 2026-09-01

---

## 0. Estado APLICADO en el proyecto (2026-09-01)

Lo siguiente ya está **creado y corriendo** en `project-546ee9f1-20e7-4368-919`,
aplicado desde Cloud Shell con la cuenta `jorgeayva@unisabana.edu.co`:

| Recurso | Estado | Detalle |
|---|---|---|
| **VPC Flow Logs** en `dev-gke-subnet` | ✅ Activo | agregación 30 s, muestreo 1.0, `INCLUDE_ALL_METADATA`, filtro CEL que excluye health checkers |
| `dev-deny-admin-ingress` | ✅ Creada | INGRESS deny 22/23/3389/5432/6379/27017 desde `0.0.0.0/0`, con logging |
| `dev-deny-suspicious-egress` | ✅ Creada | EGRESS deny 23/445/1433/3389/4444/5555/6667/9001, con logging |
| `security/failed_auth_control_plane` | ✅ Creada | labels: `principal`, `service` |
| `security/firewall_denied` | ✅ Creada | labels: `rule`, `src_ip`, `dest_port` |
| `security/flow_east_west` | ✅ Creada | labels: `src_namespace`, `dest_namespace`, `dest_port` |
| `security/flow_ingress_internet` | ✅ Creada | labels: `src_country`, `dest_port` |
| `security/flow_egress_internet` | ✅ Creada | labels: `dest_country`, `dest_asn`, `dest_port` |
| `security/flow_unexpected_pair` | ✅ Creada | labels: `src_pod`, `dest_pod`, `dest_port` |
| Canal de notificación (email) | ✅ Creado | `jorgeayva@unisabana.edu.co` |
| Alerta **SEC-2** | ✅ Creada | tráfico E-W hacia puerto no autorizado |

Pendiente de aplicar: alertas SEC-1, SEC-3, SEC-4, SEC-5 y el dashboard.

### Hallazgo del apply real

Cloud Monitoring **rechaza** cualquier filtro de alert policy que no restrinja
`resource.type`:

```
must specify a restriction on "resource.type" in the filter
```

`terraform validate` **no** detecta esto — es una validación del servidor, no del
esquema. El Terraform de `infrastructure/gcp-modulo-c/security-alerts.tf` se
corrigió con el `resource.type` explícito de cada métrica
(`gce_subnetwork` para las de red y firewall, `audited_resource` para los audit
logs, `k8s_container` para el mesh, `k8s_cluster` para la postura de GKE).

Es exactamente el tipo de fallo que solo aparece aplicando de verdad.

---

## 1. Resumen en una línea

El Módulo C vive **entero** en directorios nuevos. Sobre lo que ya existía en el
repositorio solo se modificaron **dos archivos**: `README.md` (una sección
añadida al final) y `.gitignore` (dos líneas).

```bash
# Comprobación — debe devolver exactamente estos dos:
git diff --name-status origin/main..modulo-c-network-security | grep '^M'
#   M  .gitignore
#   M  README.md
```

`infrastructure/gcp/`, `helm/`, `mesh/`, `services/` y `grafana/` quedan **byte
a byte** como los dejaron los compañeros.

---

## 2. Alcance: solo lo que pide el enunciado

| Requisito | Dónde | Estado |
|---|---|---|
| Habilitar VPC Flow Logs (GCP) | `infrastructure/gcp-modulo-c/PARCHE-modulo-a.md` §1 | Comando listo. **Verificado: hoy están desactivados** |
| Habilitar VPC Flow Logs (AWS) | `infrastructure/aws/` | Codificado y validado, **no aplicado** (se trabaja sobre GCP, no hay cuenta AWS) |
| Alertas de tráfico anómalo entre servicios | `infrastructure/gcp-modulo-c/security-alerts.tf` → SEC-2, SEC-3, SEC-4, SEC-5 | Listo para aplicar |
| Security Command Center **o** AWS Security Hub | `security-command-center.tf` / `infrastructure/aws/security-hub.tf` | Bloqueado por falta de organización → plan B activo (§6) |
| Dashboard Golden Signals de Seguridad | `dashboards/security-golden-signals.json.tftpl` | Listo para aplicar |

---

## 3. Estado real del entorno, verificado en consola

Todo lo de esta tabla se comprobó directamente en el proyecto, no se supuso.

| Elemento | Valor |
|---|---|
| Proyecto | `observabilidad` · `project-546ee9f1-20e7-4368-919` · nº `725349944399` |
| Organización del proyecto | **Ninguna** (`No organization`). Existe `jorgeayva-org` (`1096573089885`) pero el proyecto no está dentro |
| VPC | `dev-otel-vpc`, modo personalizado |
| Subred | `dev-gke-subnet`, `us-central1`, `10.0.0.0/20`; secundarios `gke-pods 10.48.0.0/14`, `gke-services 10.52.0.0/20` |
| **VPC Flow Logs** | **Desactivados** |
| Clúster | `dev-otel-cluster`, regional `us-central1`, 6 nodos, 12 vCPU, 48 GB — sano |
| `var.environment` | **`dev`** (deducido de los nombres, coincide con el Terraform) |
| Istio | **No instalado** — no existe `istio-system` |
| Namespaces | `services` y `observability` |
| `data-service` | Deployment y Service `data-service-data-service`, namespace **`services`** |
| `rds-sim` | namespace `services`, puerto 5432 |
| Puertos reales | `service-a` **8000**, `service-b` **8001**, `data-service` **8080** |
| Ajeno al módulo | `otel-stack-grafana` está en `0/1` — reportado, no tocado |

**Los nombres de la VPC, subred y clúster coinciden exactamente con el Terraform
de `infrastructure/gcp/`**, así que la infraestructura se creó con ese código y
`environment = dev`.

---

## 4. El problema del state, y por qué el módulo vive aparte

`infrastructure/gcp/main.tf` tiene el backend remoto **comentado** (líneas
28–32) y en el repositorio **no hay ningún `.tfstate`**. El state quedó en la
máquina de quien aplicó.

Consecuencia: **editar `infrastructure/gcp/` y aplicar desde un clon limpio no
modificaría la infraestructura — intentaría crearla otra vez**, fallando con
`already exists` a mitad de camino y dejando un state parcial. Es la forma más
rápida de romper el trabajo de los compañeros.

Por eso el Módulo C es un **root module independiente** en
`infrastructure/gcp-modulo-c/`:

- Tiene su **propio state**, que solo conoce los recursos del Módulo C.
- Lee la infraestructura existente con **data sources**, nunca con `resource`.
  Terraform no puede modificar ni destruir lo que solo lee.
- `terraform destroy` ahí borra **únicamente** el Módulo C.

Si `environment` se pone mal, los data sources fallan en el `plan` con
`not found`: el módulo no puede aplicarse contra recursos equivocados.

---

## 5. Archivos nuevos

```
infrastructure/gcp-modulo-c/          root module independiente (own state)
  main.tf                             provider, APIs, data sources
  variables.tf                        variables del módulo
  network-security.tf                 2 reglas de firewall-sensor, audit config,
                                      9 métricas basadas en logs
  security-alerts.tf                  7 alert policies
  security-command-center.tf          SCC condicionado + identidad del exportador
  security-dashboard.tf               dashboard de Cloud Monitoring
  outputs.tf
  dashboards/security-golden-signals.json.tftpl
  PARCHE-modulo-a.md                  lo único que toca recursos ajenos, SIN aplicar

infrastructure/aws/                   módulo AWS (validado, no aplicado)
security/cve-exporter.yaml            despliegue del exportador de CVEs
security/opcional-istio/              políticas de autorización — OPCIONAL (§7)
services/cve-exporter/                código del exportador
scripts/modulo-c-validacion.sh        escenario de validación
docs/MODULO-C-NETWORK-SECURITY.md     documentación del módulo
docs/MODULO-C-CAMBIOS.md              este documento
```

**Revertir:** borrar los directorios. Nada del resto del repo depende de ellos.

---

## 6. Los dos archivos existentes modificados

### `README.md`
Sección **§13 Observabilidad de Red y Seguridad** añadida al final. Las
secciones §1–§12 quedan intactas, numeración y texto incluidos.
**Revertir:** borrar desde `## 13. Observabilidad de Red y Seguridad`.

### `.gitignore`
Dos líneas para no subir los directorios `.terraform/`.
**Revertir:** borrar el bloque `# Terraform (local)`.

### Archivos que se tocaron y se restauraron
Durante el trabajo, `terraform fmt -recursive` reformateó `cloud-sql.tf`,
`outputs.tf` y `variables.tf` (solo alineación de `=`), y una versión anterior
de este módulo modificaba `main.tf` y `gke.tf`. **Todo eso está revertido**: esos
cinco archivos están como en `origin/main`. Lo que necesitaban aportar vive
ahora en `PARCHE-modulo-a.md`, sin aplicar.

---

## 7. Qué se activa en GCP al aplicar

`cd infrastructure/gcp-modulo-c && terraform apply` crea **solo** esto:

| Recurso | Efecto | Riesgo | Revertir |
|---|---|---|---|
| 5 APIs (`containeranalysis`, `containerscanning`, `securitycenter`, `cloudasset`, `pubsub`) | Habilitación | Ninguno. `disable_on_destroy = false` para no apagar APIs que otros usen | — |
| `dev-deny-admin-ingress` | Deniega 22/23/3389/5432/6379/27017 desde Internet | ⚠️ Rompería `gcloud compute ssh` a los nodos, si alguien lo usa | `terraform destroy -target=google_compute_firewall.deny_admin_ingress_from_internet` |
| `dev-deny-suspicious-egress` | Deniega salida a 23/445/1433/3389/4444/5555/6667/9001 | Ninguno: nada legítimo usa esos puertos | ídem |
| Data Access audit logs (Secret Manager) | Registra accesos al secreto de la BD | Volumen bajo | `-target=google_project_iam_audit_config.data_access` |
| 9 métricas basadas en logs | Solo leen logs | Ninguno | `-target=google_logging_metric.<nombre>` |
| 7 alert policies | Notifican por correo | Ninguno. Sin `security_alert_email` no notifican | ídem |
| Dashboard de Cloud Monitoring | Panel nuevo | Ninguno | ídem |
| Service account del exportador | Identidad de **solo lectura** de hallazgos | Ninguno | ídem |

**Reversión total:** `terraform destroy` dentro de `infrastructure/gcp-modulo-c/`.
No puede tocar la VPC, el clúster ni Cloud SQL: no están en su state.

Aparte, el paso obligatorio de `PARCHE-modulo-a.md` §1 (flow logs) se revierte con
`gcloud compute networks subnets update dev-gke-subnet --region=us-central1 --no-enable-flow-logs`.

### Costo
El componente dominante es la ingesta de VPC Flow Logs en Cloud Logging.
Mitigado con agregación de 30 s y un filtro CEL que excluye los health checkers
de Google (>40 % de los registros en un clúster GKE). Se conserva muestreo
`1.0`: **se filtra ruido conocido, no se muestrea señal al azar**. Artifact
Analysis cobra ~USD 0,26 por imagen escaneada y se puede desactivar con
`-var="enable_container_scanning=false"`.

---

## 8. Errores propios detectados y corregidos antes de aplicar

Se auditó el código contra los charts de `helm/` y contra el clúster real.
Aparecieron cinco fallos, cuatro capaces de romper algo:

| # | Error | Qué habría pasado | Corrección |
|---|---|---|---|
| 1 | Selector `app.kubernetes.io/name` para `service-a`/`service-b` | Los pods llevan `app: service-a`. Con el `deny-all` del namespace, **ningún ALLOW habría hecho match: caída total** | Labels verificados contra los charts |
| 2 | Puerto 8080 asumido para todos | `service-a` escucha en 8000 y `service-b` en 8001. Mismo efecto | Puertos corregidos |
| 3 | `ew_allowed_ports` sin 8000 ni 8001 | SEC-2 habría marcado como anómalo **todo** el tráfico legítimo `service-a → service-b` | Lista corregida |
| 4 | Políticas apuntando al namespace `data-service` | En el clúster todo vive en `services`. Las reglas no habrían aplicado | Namespaces corregidos |
| 5 | Módulo dentro de `infrastructure/gcp/` | `terraform apply` habría intentado recrear la VPC, el clúster y Cloud SQL | Root module independiente (§4) |

---

## 9. Lo que se decidió NO hacer

| No se hizo | Por qué |
|---|---|
| Instalar Istio | Pertenece al Módulo A. El README §10 ya dice que quedó validado en `kind` y pendiente en GKE |
| Mover el proyecto a `jorgeayva-org` | Activaría SCC, pero cambia la herencia de IAM y políticas de **todo el equipo**. Decisión del grupo (§10) |
| Levantar `otel-stack-grafana`, que está caído | Es del Módulo A. Reportado, no tocado |
| Modificar los charts de Helm | Son de los compañeros. La única mejora detectada —dar SA propia a `data-service` en vez de usar `default`— queda como recomendación |
| Tocar `infrastructure/gcp/` | Ver §4. Lo necesario está en `PARCHE-modulo-a.md`, sin aplicar |

### Dos cosas que quité de mi propio trabajo

**El dashboard de Grafana.** Lo había construido sobre métricas de Istio
(`istio_requests_total`). Sin Istio no existe ninguna de esas series, y
Prometheus solo scrapea el OTel Collector: el panel habría salido **vacío**.
Entregar un dashboard que no pinta nada es peor que no entregarlo. El
entregable es el de **Cloud Monitoring**, que se alimenta de fuentes nativas y
cubre los tres Golden Signals hoy.

**La política de autorización del mesh.** No la pide el enunciado; la añadí como
segunda fuente de "auth fallidos" y encima hoy no se puede aplicar. Movida a
`security/opcional-istio/` (fuera de `mesh/`, que es del Módulo A), corregida y
lista por si algún día se instala Istio. El requisito se cumple sin ella con
Cloud Audit Logs.

---

## 10. Decisión pendiente: Security Command Center

SCC exige que el proyecto pertenezca a una organización, en todos sus modos de
activación. `observabilidad` está en `No organization`.

| Opción | Qué implica | Impacto |
|---|---|---|
| **A. Plan B (activo por defecto)** | Artifact Analysis + GKE Security Posture + Cloud Audit Logs | Ninguno |
| **B. AWS Security Hub** | El enunciado lo permite; se habilita por cuenta, sin organización | Requiere cuenta AWS, que no hay |
| **C. Mover el proyecto a `jorgeayva-org`** | SCC activable con `-var="scc_organization_id=1096573089885"` | ⚠️ Cambia herencia de IAM y políticas. **Decisión del grupo** |

---

## 11. Orden de ejecución y verificación

```bash
# 1. OBLIGATORIO — habilitar los flow logs (hoy están apagados)
gcloud compute networks subnets update dev-gke-subnet \
  --region=us-central1 --project=project-546ee9f1-20e7-4368-919 \
  --enable-flow-logs \
  --logging-aggregation-interval=interval-30-sec \
  --logging-flow-sampling=1.0 \
  --logging-metadata=include-all

# 2. Aplicar el Módulo C (no toca nada de los Módulos A/B)
cd infrastructure/gcp-modulo-c
terraform init
terraform apply \
  -var="project_id=project-546ee9f1-20e7-4368-919" \
  -var="environment=dev" \
  -var="region=us-central1" \
  -var="security_alert_email=jorgeayva@unisabana.edu.co"

# 3. Comprobar que llegan registros (2-3 min después)
gcloud logging read 'log_id("compute.googleapis.com/vpc_flows")' \
  --project project-546ee9f1-20e7-4368-919 --limit 3

# 4. Evidencia: inyecta tráfico anómalo y mide la latencia de detección
./scripts/modulo-c-validacion.sh project-546ee9f1-20e7-4368-919 dev us-central1
```

El paso 1 no es opcional: sin flow logs el módulo se aplica sin errores pero
todos los paneles de tráfico quedan vacíos, y nada lo explica. Por eso el script
de validación aborta con un mensaje explícito si los encuentra apagados.
