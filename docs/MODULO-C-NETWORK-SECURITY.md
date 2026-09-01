# Módulo C — Network and Security Observability

> Extiende el sistema observable de los Módulos A y B con la capa que faltaba:
> **quién habla con quién por la red, quién intenta entrar sin permiso y qué
> vulnerabilidades corren en producción.**

> **Estado del entorno y registro de cambios:** ver
> [`MODULO-C-CAMBIOS.md`](MODULO-C-CAMBIOS.md) — qué se tocó, qué no, y cómo
> revertir cada cosa. Dos condicionantes verificados en consola que afectan a
> lo que sigue:
>
> - El proyecto `observabilidad` **no pertenece a ninguna organización**, así
>   que Security Command Center no es activable (§6).
> - El Módulo C es un **root module aparte** (`infrastructure/gcp-modulo-c/`) con
>   su propio state, porque el state de los Módulos A/B no está en el repo y
>   aplicar desde `infrastructure/gcp/` intentaría recrear la infraestructura.
> - **Istio no está instalado** en `dev-otel-cluster`. Las señales L3/L4 y de
>   plano de control funcionan igual; lo que queda sin fuente hasta que el
>   Módulo A despliegue el mesh es la señal de autenticación fallida a nivel de
>   *aplicación* y el dashboard de Grafana. El requisito del enunciado se cumple
>   con Cloud Audit Logs, que sí funciona hoy.

---

## 1. Qué pide el módulo y dónde está resuelto

| Requisito del laboratorio | Implementación | Archivo |
|---|---|---|
| Habilitar VPC Flow Logs (GCP) | Comando `gcloud` o bloque `log_config` en la subred | [`gcp-modulo-c/PARCHE-modulo-a.md`](../infrastructure/gcp-modulo-c/PARCHE-modulo-a.md) §1 |
| Habilitar VPC Flow Logs (AWS) | `aws_flow_log` a CloudWatch Logs (caliente) y a S3/Parquet (frío). **Codificado y validado, no aplicado**: el trabajo se hace sobre GCP y no hay cuenta AWS (README §9) | [`infrastructure/aws/vpc-flow-logs.tf`](../infrastructure/aws/vpc-flow-logs.tf) |
| Alertas sobre tráfico anómalo entre servicios | 5 políticas: par no autorizado, desviación sobre baseline móvil, egress anómalo, escaneo, auth fallida | [`gcp-modulo-c/security-alerts.tf`](../infrastructure/gcp-modulo-c/security-alerts.tf) |
| Security Command Center (GCP) **o** AWS Security Hub | Ambos codificados. SCC condicionado a organización; Security Hub CSPM + GuardDuty + Inspector para AWS; **plan B activo sin organización** (§6) | [`gcp-modulo-c/security-command-center.tf`](../infrastructure/gcp-modulo-c/security-command-center.tf) |
| Dashboard "Golden Signals de Seguridad" | Dashboard de **Cloud Monitoring**, alimentado por fuentes nativas | [`gcp-modulo-c/dashboards/security-golden-signals.json.tftpl`](../infrastructure/gcp-modulo-c/dashboards/security-golden-signals.json.tftpl) |

---

## 2. La decisión de diseño que sostiene todo el módulo

**Un flujo de red sin frontera que cruzar no es observable.**

VPC Flow Logs registra paquetes. Por sí solo dice que `10.48.2.7` habló con
`10.48.1.3` en el puerto 8080 — información verdadera y prácticamente inútil
para seguridad: no distingue una llamada legítima de un movimiento lateral,
porque en una red plana **ambas cosas se ven exactamente igual**.

Este módulo resuelve eso en tres capas que se apoyan una en otra:

```
  Capa 3: DASHBOARD        Golden Signals de Seguridad
                           auth fallida · N-S/E-W · CVEs activos
                                    ▲
  Capa 2: SEÑAL            métricas basadas en logs + métricas OTel
                           (lo que convierte eventos en series temporales)
                                    ▲
  Capa 1: FRONTERA         reglas de firewall (N-S y egress)          ← activo
                           IAM + Cloud Audit Logs (plano de control)  ← activo
                           AuthorizationPolicy del mesh (RBAC E-W)    ← opcional,
                                                                        requiere Istio
```

Sin la capa 1 no hay nada que medir en la capa 2: las reglas de firewall y los
audit logs son los que producen los eventos de rechazo que después se miden.

[`security/opcional-istio/authorization-policy.yaml`](../security/opcional-istio/authorization-policy.yaml)
añadiría una **segunda** fuente para el Golden Signal 1 —los `403
RBAC_ACCESS_DENIED` del mesh—, pero **no es un requisito del enunciado y hoy no
se puede aplicar** porque Istio no está instalado. Queda escrita, corregida
contra los charts reales y lista para cuando el Módulo A despliegue el mesh.
Está fuera de `mesh/` a propósito: esa carpeta es del Módulo A.

### Matriz de comunicación autorizada

Es el contrato contra el que se mide "anómalo". Está declarada dos veces a
propósito — como control en el mesh y como filtro en las métricas — para que
una desviación se detecte aunque el mesh no la haya podido bloquear (por
ejemplo, un pod sin sidecar inyectado).

Verificada contra los charts de `helm/` — labels, puertos y ServiceAccounts reales, no supuestos. **Los puertos no son todos 8080**, y darlo por hecho habría denegado todo el tráfico legítimo:

```
  Internet ──────► service-a     :8000   label app=service-a            ns services
  service-a ─────► service-b     :8001   label app=service-b            ns services
  service-a ─────► data-service  :8080   label app.kubernetes.io/name   ns services
  service-b ─────► data-service  :8080
  data-service ──► rds-sim       :5432   label app.kubernetes.io/name   ns services
  (todos) ───────► otel-collector:4317   ns observability, sin sidecar
```

| Servicio | ServiceAccount | Origen del dato |
|---|---|---|
| `service-a` | `service-a-sa` | `helm/service-a/values.yaml` |
| `service-b` | `service-b-sa` | `helm/service-b/values.yaml` |
| `data-service` | `default` | el chart no define `serviceAccountName` |

Cualquier otro par origen–destino–puerto dispara **SEC-2**.

---

## 3. Los tres Golden Signals de Seguridad

### 3.1 Intentos de autenticación fallidos

Se mide en **dos planos distintos**, porque un atacante puede fallar en
cualquiera de los dos y son eventos de naturaleza opuesta:

| Plano | Qué captura | Fuente | Métrica |
|---|---|---|---|
| Control | Llamadas a la API de GCP rechazadas (`PERMISSION_DENIED`, `UNAUTHENTICATED`) | Cloud Audit Logs | `security/failed_auth_control_plane` |
| Datos | `401`/`403` vistos por los sidecars Envoy, con `response_flags=RBAC_ACCESS_DENIED` | Access logs del mesh | `security/failed_auth_workload` |

Los Data Access audit logs **no están activos por defecto**. Se habilitan solo
para Secret Manager
([`network-security.tf`](../infrastructure/gcp-modulo-c/network-security.tf),
`google_project_iam_audit_config`): es donde vive la DSN de la base de datos, y
un `PERMISSION_DENIED` contra ese secreto es la señal con más valor forense y
menos ruido del proyecto. Habilitarlos para todos los servicios multiplicaría
el volumen de logs —y la factura— sin añadir señal proporcional.

### 3.2 Tráfico Norte-Sur / Este-Oeste

La separación no se hace por convención sino por un campo del propio registro:
**solo los extremos externos a Google Cloud llevan anotación geográfica**
(`src_location` / `dest_location` con país y ASN).

| Métrica | Criterio | Uso |
|---|---|---|
| `security/flow_east_west` | `src_vpc` **y** `dest_vpc` presentes | Matriz de comunicación real |
| `security/flow_east_west_bytes` | ídem, distribución de `bytes_sent` | Cola p99: exfiltración interna |
| `security/flow_ingress_internet` | `src_location` presente, `reporter=DEST` | Superficie de exposición |
| `security/flow_egress_internet` | `dest_location` presente, `reporter=SRC` | Llamadas a casa / C2 |
| `security/flow_unexpected_pair` | E-W + puerto fuera de la matriz | Movimiento lateral |

`reporter="SRC"` evita contar dos veces el mismo flujo: cada conexión se
registra por el extremo origen y por el destino.

### 3.3 CVEs activos

El escaneo de vulnerabilidades de workloads de GKE **quedó deprecado**, así
que la fuente soportada es **Artifact Analysis** sobre las imágenes del
Artifact Registry (escaneo automático on-push).

El puente hasta el dashboard es
[`services/cve-exporter/`](../services/cve-exporter/): un pod que consulta la
API de Container Analysis y publica los hallazgos **como métricas OTel** hacia
el Collector que ya existe.

```
security-exporter ──OTLP──► OTel Collector ──┬──► Prometheus ──► Grafana
                                             └──► Cloud Monitoring ──► Dashboard
```

Esa decisión es coherente con el ADR-001: el exportador no escribe contra la
API de Cloud Monitoring ni contra un formato propietario. Habla OTLP; el
Collector decide el destino. Una sola fuente alimenta los dos dashboards.

Detalle deliberado: el exportador emite **`0` explícito** para las severidades
sin hallazgos. Sin eso, la serie desaparece al corregir el último CVE crítico y
el panel queda con un hueco — "no hay dato" y "cero vulnerabilidades" se verían
igual. Por la misma razón existe `security.exporter.up`: un panel de CVEs en
cero porque el exportador está caído es un falso negativo peligroso.

---

## 4. Alertas de tráfico anómalo: dos detectores, no uno

El ADR-002 midió que el 35 % de los falsos positivos del sistema actual vienen
de estacionalidad que ningún umbral fijo cubre. Ese hallazgo se aplica aquí:

| Alerta | Tipo de detección | Por qué así |
|---|---|---|
| **SEC-1** auth fallida | Umbral (>5 en 5 min) | El volumen normal es cero; el umbral solo filtra errores de cliente aislados |
| **SEC-2** par no autorizado | Determinista (>0) | La matriz es cerrada. Precisión ≈ 1.0, recall bajo |
| **SEC-3** volumen E-W | **Baseline móvil** (`ALIGN_PERCENT_CHANGE`) | Precisión menor, recall alto. Detecta lo legítimo en volumen ilegítimo |
| **SEC-4** conexiones denegadas | Umbral (>10 en 5 min) | Un escaneo produce decenas de intentos; uno aislado es ruido |
| **SEC-5** egress anómalo | Baseline móvil **+** p99 absoluto | Dos condiciones porque exfiltrar 2 GB en **una** conexión no altera el *número* de flujos |
| **SEC-6** CVE crítico | Determinista (>0) | — |
| **SEC-7** postura GKE | Determinista (>0) | — |

SEC-2 y SEC-3 son complementarias, no redundantes: la determinista tiene
precisión alta y recall bajo; la estadística, al revés. Juntas cubren el plano
que ninguna cubre sola.

**Toda alerta es accionable por construcción**: el campo `documentation` de
cada política incluye los labels de la serie que disparó, cómo interpretar el
hallazgo y los pasos concretos de investigación. Una alerta que no dice qué
mirar no cuenta como accionable en el criterio del Módulo D.

En AWS, el papel de `ALIGN_PERCENT_CHANGE` lo cumple
`ANOMALY_DETECTION_BAND(metrica, 2)`: banda de confianza aprendida en vez de
umbral fijo. Mismo principio, distinta sintaxis.

---

## 5. El dashboard

El entregable es el dashboard de **Cloud Monitoring**, porque es el único que
puede mostrar los tres Golden Signals con datos reales hoy:

| Señal | Fuente | ¿Existe hoy? |
|---|---|---|
| Auth fallidos | Cloud Audit Logs | Sí |
| Tráfico N-S / E-W | VPC Flow Logs | Sí, en cuanto se habiliten |
| CVEs activos | Artifact Analysis vía `security-exporter` | Sí |

Había construido además un panel equivalente en Grafana sobre métricas de Istio
(`istio_requests_total`). **Se retiró**: sin Istio esas series no existen, y
Prometheus solo scrapea el OTel Collector, así que el panel habría salido vacío.
Un dashboard que no pinta nada es peor que no entregarlo.

Cuando el Módulo A despliegue el mesh, ese panel L7 recupera sentido como
complemento: vería la intención (ruta, código de respuesta, identidad SPIFFE)
donde el de Cloud Monitoring ve el paquete.

---

## 6. Security Command Center: la restricción y el plan B

**SCC solo se puede activar sobre una organización.** La activación "a nivel de
proyecto" que documenta Google también exige que el proyecto pertenezca a una
organización; lo único que cambia es el alcance de la facturación. Un proyecto
creado bajo una cuenta personal (sin Cloud Identity / Workspace) queda en
*"No organization"* y SCC **no es activable en él**, ni por consola ni por API.

Por eso todo el código de SCC está condicionado a `var.scc_organization_id`, y
el módulo entrega una cobertura equivalente que **sí funciona sin
organización**:

| Capacidad de SCC | Sustituto sin organización | Estado |
|---|---|---|
| Vulnerability Assessment | Artifact Analysis (escaneo on-push) | Activo |
| Security Health Analytics | GKE Security Posture (auditoría de configuración) | Activo |
| Event Threat Detection | Métricas de log sobre Cloud Audit Logs | Activo |
| Findings API centralizada | Cloud Monitoring + dashboard del módulo | Activo |

Lo que se pierde es **alcance** (SCC ve toda la organización y correla entre
proyectos) y **catálogo de detectores**, no la arquitectura de la solución: la
señal termina en el mismo dashboard por el mismo camino.

Además, el enunciado permite explícitamente elegir: *"Security Command Center
(GCP) **o** AWS Security Hub básico"*. Security Hub **se habilita por cuenta,
sin organización** — es la ruta abierta si se dispone de una cuenta AWS. Ambas
están codificadas.

Si el proyecto sí pertenece a una organización:

```bash
gcloud organizations list      # obtener el ID numérico
terraform apply -var="scc_organization_id=123456789012"
```

---

## 7. Paridad GCP ↔ AWS

| Señal | GCP | AWS |
|---|---|---|
| Flujos de red | VPC Flow Logs → Cloud Logging | VPC Flow Logs → CloudWatch Logs + S3/Parquet |
| Archivo forense | Sink a BigQuery | S3 + Athena (particionado por hora) |
| Métricas de flujo | Métricas basadas en logs | Metric filters de CloudWatch |
| Postura / CSPM | Security Command Center | Security Hub CSPM + FSBP + CIS |
| Detección de amenazas | Event Threat Detection | GuardDuty |
| CVEs de contenedor | Artifact Analysis | Amazon Inspector (ECR) |
| Auditoría del plano de control | Cloud Audit Logs | CloudTrail |
| Detección sin umbral fijo | `ALIGN_PERCENT_CHANGE` | `ANOMALY_DETECTION_BAND` |
| Notificación | Notification channel | SNS |

**Estado del módulo AWS: escrito y validado (`terraform validate`), no
aplicado.** El proyecto no dispone de cuenta AWS activa — la misma restricción
ya documentada en el README §9 para el backend "AWS RDS" de `data-service`.
Ahí cabía una simulación (`rds-sim`: mismo protocolo, mismo driver, misma
instrumentación); aquí no, porque VPC Flow Logs y Security Hub son servicios
gestionados, no protocolos que se puedan emular en otro sitio. Lo que sí es
exigible —y es lo que se entrega— es que la solución esté **diseñada y
codificada** para los dos proveedores con paridad de señales.

---

## 8. Costo y control de volumen

VPC Flow Logs se factura como ingesta de Cloud Logging. Las decisiones tomadas
para que un laboratorio quepa en los créditos de la prueba gratuita:

| Parámetro | Valor | Efecto |
|---|---|---|
| `flow_logs_sampling` | `1.0` | **Sin muestreo.** Un flujo malicioso suele ser un único flujo de pocos bytes; con 0.5 se pierde la mitad de las veces |
| `flow_logs_aggregation_interval` | `INTERVAL_30_SEC` | ~1/6 del volumen de 5 s manteniendo el MTTD objetivo de 2 min |
| `flow_logs_filter_expr` | Excluye health checkers de GCP (`35.191.0.0/16`, `130.211.0.0/22`) | En un clúster GKE ese tráfico puede ser >40 % de los registros y tiene riesgo cero |
| Data Access audit logs | Solo Secret Manager | El resto de servicios generaría volumen sin señal proporcional |

El control de costo se hace **filtrando ruido conocido, no muestreando
señal**. Es la diferencia entre no registrar lo que no importa y registrar al
azar.

Si aun así el volumen preocupa, `INTERVAL_1_MIN` reduce otro ~50 % a cambio de
empeorar el MTTD hasta ~3 min, lo que rompería el objetivo del Módulo D.

---

## 9. Despliegue paso a paso

```bash
# ── 1. OBLIGATORIO — habilitar los VPC Flow Logs ────────────────────────────
# Verificado en consola: hoy están desactivados en dev-gke-subnet.
gcloud compute networks subnets update dev-gke-subnet \
  --region=us-central1 --project=project-546ee9f1-20e7-4368-919 \
  --enable-flow-logs \
  --logging-aggregation-interval=interval-30-sec \
  --logging-flow-sampling=1.0 \
  --logging-metadata=include-all

# ── 2. Aplicar el Módulo C ──────────────────────────────────────────────────
# Root module aparte: lee la infraestructura existente, no la gestiona.
cd infrastructure/gcp-modulo-c
terraform init
terraform apply \
  -var="project_id=project-546ee9f1-20e7-4368-919" \
  -var="environment=dev" \
  -var="region=us-central1" \
  -var="security_alert_email=jorgeayva@unisabana.edu.co"

# ── 3. Exportador de CVEs ───────────────────────────────────────────────────
PROJECT=project-546ee9f1-20e7-4368-919; ENV=dev; REGION=us-central1
docker build -t $REGION-docker.pkg.dev/$PROJECT/otel-lab/security-exporter:1.0.0 \
  ./services/cve-exporter
docker push $REGION-docker.pkg.dev/$PROJECT/otel-lab/security-exporter:1.0.0

sed -e "s/PROJECT_ID_PLACEHOLDER/$PROJECT/g" \
    -e "s/ENV_PLACEHOLDER/$ENV/g" \
    -e "s/REGION_PLACEHOLDER/$REGION/g" \
    security/cve-exporter.yaml | kubectl apply -f -

# ── 4. Evidencia ────────────────────────────────────────────────────────────
./scripts/modulo-c-validacion.sh $PROJECT dev us-central1
```

**El paso 1 no es opcional.** Sin flow logs el módulo se aplica sin errores pero
todos los paneles de tráfico quedan vacíos y nada lo explica. Por eso el script
del paso 4 aborta con un mensaje explícito si los encuentra apagados, en vez de
generar tráfico durante siete minutos para nada.

Los pasos 2 y 3 **no tocan** la infraestructura de los Módulos A/B: el Terraform
la lee con data sources y el exportador se despliega en `observability` como un
pod más.

---

## 10. Evidencia esperada

`scripts/modulo-c-validacion.sh` inyecta cuatro comportamientos anómalos
controlados y mide cuánto tarda cada uno en ser visible en Cloud Logging:

| Escenario | Acción inyectada | Señal | Alerta |
|---|---|---|---|
| A | Pod sin autorización llama a `data-service` | `403 RBAC_ACCESS_DENIED` | SEC-1 |
| B | Conexión E-W a los puertos 9999 / 6379 / 27017 | `flow_unexpected_pair` | SEC-2 |
| C | Egress a `1.1.1.1:4444` y `8.8.8.8:6667` | `firewall_denied` | SEC-4 |
| D | Lectura no autorizada del secreto con la DSN | `PERMISSION_DENIED` en audit logs | SEC-1 |

El MTTD se descompone así, y el script mide el primer sumando con precisión:

```
MTTD = t_visible_en_logs  +  t_agregación_métrica  +  t_evaluación_alerta
       (medido, ~30-60s)     (≤ 60 s)                (60 s SEC-2 / 300 s resto)
```

Capturas a incluir en el informe:

1. Consola de VPC → subred con *Flow Logs: activado* e intervalo de agregación.
2. Logs Explorer con un registro `vpc_flows` desplegado, mostrando
   `src_gke_details` / `dest_gke_details` (prueba de que `INCLUDE_ALL_METADATA`
   está haciendo su trabajo).
3. Dashboard *Golden Signals de Seguridad* de Cloud Monitoring con datos.
4. Dashboard homónimo de Grafana con el pico de 403 del escenario A.
5. Lista de incidentes abiertos tras ejecutar el script.
6. Cuerpo de una notificación de alerta, mostrando la sección "Qué hacer".
7. Consola de GKE → Postura de seguridad, con los hallazgos de configuración.
8. `gcloud artifacts docker images list-vulnerabilities` sobre una imagen del
   registro.

---

## 11. Limitaciones conocidas

| Limitación | Impacto | Mitigación aplicada |
|---|---|---|
| VPC Flow Logs no registra tráfico entre pods del mismo nodo | En un clúster de 2 nodos, ~la mitad de los pares E-W son invisibles para los flow logs | `enable_intranode_visibility`, **desactivada por defecto**: activarla en un clúster en uso dispara una actualización continua de nodos. Se activa con ventana de mantenimiento (`-var="enable_intranode_visibility=true"`). Mientras tanto, el panel L7 de Grafana sí ve ese tráfico, porque los sidecars lo interceptan antes de llegar a la red |
| Los flow logs son L3/L4: no ven rutas HTTP ni identidades | No distinguen `GET /health` de `GET /records?all=true` | El dashboard L7 de Grafana cubre ese plano |
| SCC requiere organización | No activable en cuenta personal | Plan B del §6, con equivalencia documentada |
| Artifact Analysis escala por imagen escaneada | Costo proporcional al número de builds | Escaneo on-push, no continuo; agrupación por imagen sin digest en el exportador |
| `ALIGN_PERCENT_CHANGE` necesita historial | Las primeras horas tras el despliegue puede dar falsos positivos | `duration = 300s` exige persistencia antes de disparar |
| Módulo AWS no aplicado | Sin evidencia de ejecución real en AWS | Código validado y paridad de señales documentada (§7) |
