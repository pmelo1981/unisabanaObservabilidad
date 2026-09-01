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
| `security/failed_auth_workload`, `flow_east_west_bytes`, `flow_egress_internet_bytes`, `gke_posture_findings` | ✅ Creadas | resto de métricas basadas en logs (10 en total) |
| Alerta **SEC-1** Ráfaga de auth fallida | ✅ Creada | `alertPolicies/2821121601167144740` |
| Alerta **SEC-2** Tráfico E-W no autorizado | ✅ Creada | `alertPolicies/11068496798239839244` — corregida, ver §12 |
| Alerta **SEC-3** Volumen E-W desviado | ✅ Creada | `alertPolicies/7308953874817893058` |
| Alerta **SEC-4** Conexiones denegadas | ✅ Creada | `alertPolicies/10116743042310907219` |
| Alerta **SEC-5** Egress anómalo | ✅ Creada | `alertPolicies/17773790989406348272` |
| Alerta **SEC-6** CVE crítico | ⛔ **No creada** | Bloqueada por dependencia externa. Ver §13 |
| Alerta **SEC-7** Postura de GKE | ✅ Creada | `alertPolicies/7308953874817893225` |
| **Dashboard** Golden Signals de Seguridad | ✅ Creado | `dashboards/c91eb981-9525-4fc8-9aa6-9ba9932e04ed` |
| GSA `dev-security-exporter` + Workload Identity | ✅ Creada | roles `containeranalysis.occurrences.viewer`, `artifactregistry.reader` |
| Deployment `security-exporter` (namespace `observability`) | ✅ Corriendo | imagen `us-central1-docker.pkg.dev/…/otel-lab/security-exporter:1.0.0`, sondeo OK: *"8 series de CVE"* |

**Falta para cerrar el módulo:** ejecutar `scripts/modulo-c-validacion.sh` para
la evidencia y la medición de MTTD; y, si el equipo lo decide, SEC-6 (§13).

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
| Habilitar VPC Flow Logs (GCP) | `infrastructure/gcp-modulo-c/PARCHE-modulo-a.md` §1 | ✅ **Aplicado y activo** (§0) |
| Habilitar VPC Flow Logs (AWS) | `infrastructure/aws/` | Codificado y validado, **no aplicado** (se trabaja sobre GCP, no hay cuenta AWS) |
| Alertas de tráfico anómalo entre servicios | `infrastructure/gcp-modulo-c/security-alerts.tf` → SEC-2, SEC-3, SEC-4, SEC-5 | ✅ **Aplicadas.** SEC-2 corregida tras una tormenta de falsos positivos (§12) |
| Security Command Center **o** AWS Security Hub | `security-command-center.tf` / `infrastructure/aws/security-hub.tf` | Bloqueado por falta de organización → plan B activo (§6) |
| Dashboard Golden Signals de Seguridad | `dashboards/security-golden-signals.json.tftpl` | ✅ **Creado.** El panel de CVEs queda vacío hasta que se arregle el collector (§13) |

---

## 3. Estado real del entorno, verificado en consola

Todo lo de esta tabla se comprobó directamente en el proyecto, no se supuso.

| Elemento | Valor |
|---|---|
| Proyecto | `observabilidad` · `project-546ee9f1-20e7-4368-919` · nº `725349944399` |
| Organización del proyecto | **Ninguna** (`No organization`). Existe `jorgeayva-org` (`1096573089885`) pero el proyecto no está dentro |
| VPC | `dev-otel-vpc`, modo personalizado |
| Subred | `dev-gke-subnet`, `us-central1`, `10.0.0.0/20`; secundarios `gke-pods 10.48.0.0/14`, `gke-services 10.52.0.0/20` |
| **VPC Flow Logs** | ✅ **Activos** desde el 2026-09-01 (agregación 30 s, muestreo 1.0, metadatos completos) |
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

---

## 12. Tormenta de falsos positivos de SEC-2, y los dos defectos que la causaban

**Qué pasó.** Al poco de aplicar SEC-2 empezó a llegar aproximadamente un correo
por minuto. Ejemplo real:

```
src_pod  : otel-stack-kube-state-metrics-5455fd7f6c-gkkfm
dest_pod : otel-stack-prometheus-server-5555974f8f-r7888
dest_port: 37936
```

Tráfico interno y legítimo del stack de observabilidad, marcado como movimiento
lateral. Este es exactamente el modo de fallo que `variables.tf` advertía para
`ew_allowed_ports`: *"la reacción natural del operador ante una alerta permanente
es silenciarla"*. Se cumplió sobre el propio módulo que lo advertía.

Al investigarlo aparecieron **dos defectos independientes**. El segundo estaba
tapado por el primero.

### Defecto 1 — el filtro contaba la dirección de respuesta

VPC Flow Logs registra **las dos direcciones** de cada conexión como entradas
distintas, ambas con `reporter="SRC"`. En la dirección de respuesta el puerto de
destino es el **puerto efímero del cliente** (Linux: 32768–60999), que por
definición nunca estará en una lista de puertos de servicio.

Consecuencia: toda conversación legítima cuyo puerto de servidor no estuviera en
la lista **se denunciaba a sí misma** con su propia respuesta.

Además el alcance era todo el clúster, y los namespaces de plataforma hablan
legítimamente por puertos que no pertenecen —ni deben pertenecer— a la matriz de
la aplicación: kubelet 10250, pushgateway 9091, node-local-dns 10054.

**Corrección** (`network-security.tf`, métrica `flow_unexpected_pair`):

```
jsonPayload.dest_gke_details.pod.pod_namespace="${var.app_namespace}"
jsonPayload.connection.dest_port<32768
```

**Verificación antes de reactivar, sobre tráfico real del clúster:** el filtro
corregido devuelve **cero** entradas en 2 horas, y el escenario B de
`scripts/modulo-c-validacion.sh` (sonda → `data-service:9999`) sigue cayendo
dentro de él. Es decir: se quitó el ruido sin quitar la señal.

### Defecto 2 — un incidente por cada puerto

Cloud Monitoring abre **un incidente por cada combinación distinta de las
etiquetas de `group_by_fields`**, y cada incidente manda un correo al abrirse y
otro al cerrarse. SEC-2 agrupaba por `src_pod`, `dest_pod` **y `dest_port`**.

`dest_port` es una etiqueta de cardinalidad no acotada. Un escaneo de 20 puertos
—que es **un solo** evento de seguridad— habría producido 20 incidentes y 40
correos.

Este defecto **no era visible** mientras el defecto 1 lo tapaba, y habría
estallado igual el día de un escaneo real, que es justo el día en que uno
necesita que el buzón sea legible.

**Corrección** (`security-alerts.tf`): agrupar por el par de pods. Un escaneo es
un incidente, con la granularidad que sirve para triage —*quién habló con
quién*—; los puertos concretos se leen en los logs enlazados desde el incidente,
que es donde hay que mirarlos de todos modos.

### Defecto 3 — el filtro era ciego al ataque que dice detectar

Este apareció al **ejecutar la validación**, no revisando código, y es el más
grave de los tres: los dos primeros producían ruido; este producía **silencio**.

El filtro exigía `jsonPayload.reporter="SRC"`. Al inyectar el ataque real
contra el clúster, el registro que llegó fue:

```
reporter   : DEST
dest_port  : 9999
dest_pod   : service-b-7646f985b9-4vrj4  (namespace services)
src_pod    : modulo-c-probe
```

**`reporter: DEST`, y ningún registro del lado SRC.** Una conexión *rechazada*
—puerto cerrado, RST— la reporta el extremo destino. Y el movimiento lateral
consiste precisamente en tocar puertos cerrados: la métrica no habría visto
ni uno.

La restricción estaba puesta para no contar dos veces los flujos establecidos,
que ambos extremos reportan. Es una preocupación irrelevante aquí: el umbral
de SEC-2 es `> 0` —es un detector de presencia, no un medidor de volumen— y la
agrupación por par de pods colapsa los duplicados. Se elimina.

**Verificación del filtro final**, sobre 3 horas de tráfico real del clúster
con el ataque ya inyectado: devuelve **exactamente una entrada**, y es el
ataque. Cero ruido, señal capturada.

### El escenario de validación tampoco servía

Al perseguir el defecto 3 salió otro, en `scripts/modulo-c-validacion.sh`: el
escenario B hacía `nc` contra el **nombre DNS del Service**, que resuelve a una
ClusterIP.

Una conexión a una ClusterIP en un puerto sin backend sí genera flow log, pero
**sin `dest_gke_details`**: no hay ningún pod detrás de esa IP:puerto que GKE
pueda anotar. Comprobado lado a lado en el mismo minuto:

| Destino | ¿`dest_gke_details`? |
|---|---|
| ClusterIP `10.52.13.115:9999` | **No** |
| Pod IP `10.48.3.6:9999` | **Sí** — `services / service-b-…-4vrj4` |

Es decir, el escenario no podía producir la señal que decía probar: daba un
**falso negativo silencioso**, que en una prueba de detección es peor que no
probar. Corregido para apuntar a la IP del pod, y además a un pod en **otro
nodo**: sin visibilidad intranodo (§4 del parche, desactivada) el tráfico
dentro de un mismo nodo no aparece en los flow logs.

### Un fallo silencioso más, en el propio script

Durante la ejecución, la sesión de Cloud Shell **perdió la cuenta activa de
gcloud**. Cada `gcloud logging read` del script empezó a devolver un error de
autenticación que el `2>/dev/null` de `esperar_log()` se tragaba, y el script
habría informado *"NO apareció en 420s"* — es decir, habría reportado un fallo
de **detección** cuando lo que había era un fallo de **credenciales**.

Se añadió una comprobación de credenciales al principio del script, antes de
cualquier otra cosa, que aborta con un mensaje explícito.

### Nota operativa: Terraform es el dueño de `enabled`

Desactivar la política a mano (`PATCH … {"enabled":false}`) es válido para cortar
la sangría, pero **el siguiente `terraform apply` la vuelve a activar**, porque
`enabled` es un campo gestionado. Pasó en este incidente. Si hay que dejar una
política apagada de forma duradera, se apaga en el código, no en la consola.

### Estado verificado tras la corrección

| Comprobación | Resultado |
|---|---|
| Último punto no-cero de la métrica | 08:13:45 |
| Hora de la comprobación | 08:34:45 |
| Minutos en cero | **21** |
| `SEC-2 enabled` | **True** — activa y callada, no silenciada |

### Riesgo análogo pendiente de vigilar

**SEC-4** agrupa por `metric.label.src_ip`, que también es de cardinalidad no
acotada. No se ha tocado porque su umbral no es 0 (`denied_connections_threshold`
= 10 en 5 min), lo que amortigua el efecto, y porque `src_ip` es justamente el
campo útil para triar una denegación de firewall. Pero ante un escaneo
distribuido produciría un incidente por IP origen. Si eso ocurre, la corrección
es la misma que la de SEC-2: agrupar solo por `rule`.

---

## 13. SEC-6 no creada: el pipeline OTel → Cloud Monitoring está roto

**No es un defecto del Módulo C, y no lo introdujo el Módulo C.** Se descubrió al
desplegar el `security-exporter`.

El `Deployment/otel-collector` corre con la KSA `default` del namespace
`observability`, que **no tiene la anotación de Workload Identity**. Con Workload
Identity activo —y lo está—, el metadata server no le entrega a esa KSA la
identidad del nodo: el pod queda **sin identidad de GCP**. Da igual que
`dev-gke-nodes-sa` sí tenga `roles/monitoring.metricWriter`; el pod nunca llega a
usar esa cuenta.

Evidencia, cada 10 segundos en los logs del collector:

```
Exporting failed. Dropping data. {"kind":"exporter","data_type":"metrics",
 "name":"googlecloud","error":"rpc error: code = PermissionDenied
 desc = Permission monitoring.timeSeries.create denied ..."}
```

Y el proyecto no tiene **ni un solo** descriptor `workload.googleapis.com/*`.

**Alcance real, más allá del Módulo C:** ninguna métrica OTel de `service-a`,
`service-b` ni `data-service` ha llegado nunca a Cloud Monitoring. Llegan solo a
Prometheus, que es el otro exporter del pipeline — por eso Grafana se ve bien y
nadie lo había notado.

El `security-exporter` del Módulo C **sí funciona**: su KSA sí tiene Workload
Identity y su sondeo es correcto (*"8 series de CVE, 0 series de SCC"*). Sus
datos mueren en el mismo punto que los de los demás.

**Decisión tomada:** no tocarlo. El recurso pertenece al Módulo A y la
instrucción del proyecto es no modificar lo hecho por otros. SEC-6 queda escrita
en `security-alerts.tf` detrás de `var.enable_cve_alert = false`, para que el
`terraform apply` termine limpio en vez de fallar con un 404 en cada ejecución.

El arreglo, con los comandos exactos y su reversión, está en
`infrastructure/gcp-modulo-c/PARCHE-modulo-a.md` §5. El día que se aplique, SEC-6
es cambiar una variable a `true` y aplicar.
