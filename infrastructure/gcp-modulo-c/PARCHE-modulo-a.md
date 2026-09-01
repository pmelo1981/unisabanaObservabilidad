# Parche para el Terraform del Módulo A

> Lo único del Módulo C que **no se puede hacer desde `infrastructure/gcp-modulo-c/`**,
> porque toca recursos que pertenecen al state de los Módulos A/B.
>
> Nada de este archivo está aplicado. `infrastructure/gcp/` está **byte a byte
> como lo dejaron los compañeros**.

---

## Por qué existe este archivo

`infrastructure/gcp/main.tf` tiene el backend remoto comentado (líneas 28–32),
así que el `terraform.tfstate` de la infraestructura quedó en la máquina de
quien la aplicó y no está en el repositorio.

Eso significa que **no se puede editar `infrastructure/gcp/` y aplicar desde un
clon limpio**: Terraform no vería la infraestructura existente e intentaría
crearla de cero, fallando con `already exists` a mitad de camino y dejando un
state parcial.

Por eso el Módulo C vive en su propio directorio con su propio state, y lo poco
que sí requiere tocar recursos ajenos queda aquí, documentado, para que lo
aplique quien tenga el state — o para hacerlo con `gcloud`, que no necesita
state ninguno.

---

## 1. VPC Flow Logs — **obligatorio**

Sin esto, el Módulo C se aplica sin errores pero los paneles de tráfico N-S/E-W
y las alertas SEC-2, SEC-3 y SEC-5 quedan **vacíos**. Es el único requisito duro.

Estado verificado en consola el 2026-09-01: **desactivados** en `dev-gke-subnet`.

### Opción A — `gcloud` (inmediata, no necesita state)

```bash
gcloud compute networks subnets update dev-gke-subnet \
  --region=us-central1 \
  --project=project-546ee9f1-20e7-4368-919 \
  --enable-flow-logs \
  --logging-aggregation-interval=interval-30-sec \
  --logging-flow-sampling=1.0 \
  --logging-metadata=include-all \
  --logging-filter-expr="!(inIpRange(connection.src_ip, '35.191.0.0/16') || inIpRange(connection.src_ip, '130.211.0.0/22'))"
```

**Revertir:**

```bash
gcloud compute networks subnets update dev-gke-subnet \
  --region=us-central1 --project=project-546ee9f1-20e7-4368-919 \
  --no-enable-flow-logs
```

> ⚠️ **Aviso de deriva.** Si se activa por `gcloud` pero no se añade el bloque
> de la Opción B, el día que alguien aplique `infrastructure/gcp/` con su state
> los flow logs se **volverán a apagar**: Terraform corregirá la diferencia
> contra lo que dice el código. Lo correcto es hacer las dos: `gcloud` ahora
> para no bloquear el trabajo, y el bloque después para que sea permanente.

### Opción B — Terraform (permanente, la aplica quien tenga el state)

En `infrastructure/gcp/main.tf`, dentro del recurso
`google_compute_subnetwork.gke_subnet`, después del segundo bloque
`secondary_ip_range`:

```hcl
  # ── Módulo C: VPC Flow Logs ─────────────────────────────────────────────────
  # GCP solo permite habilitarlos dentro del recurso de la subred; no existe
  # un recurso separado. INCLUDE_ALL_METADATA es obligatorio para el módulo:
  # sin él no se emiten src_gke_details / dest_gke_details (cluster, pod,
  # namespace) ni src_location / dest_location (país y ASN del extremo
  # externo), que son los campos con los que se distingue norte-sur de
  # este-oeste y se atribuye un flujo a un microservicio concreto.
  log_config {
    aggregation_interval = "INTERVAL_30_SEC"
    flow_sampling        = 1.0
    metadata             = "INCLUDE_ALL_METADATA"
    filter_expr          = "!(inIpRange(connection.src_ip, '35.191.0.0/16') || inIpRange(connection.src_ip, '130.211.0.0/22'))"
  }
```

**Por qué estos valores**

| Parámetro | Valor | Razón |
|---|---|---|
| `flow_sampling` | `1.0` — sin muestreo | Un flujo malicioso suele ser un único flujo de pocos bytes; con `0.5` se pierde la mitad de las veces |
| `aggregation_interval` | `INTERVAL_30_SEC` | ~1/6 del volumen de 5 s manteniendo el MTTD objetivo de 2 min del Módulo D |
| `filter_expr` | Excluye health checkers de Google | En un clúster GKE ese tráfico puede ser >40 % de los registros y tiene riesgo cero |

El control de costo se hace **filtrando ruido conocido, no muestreando señal**.

---

## 2. Registro de workloads en Cloud Logging — opcional

Solo hace falta si algún día se instala Istio: los access logs de los sidecars
Envoy son la segunda fuente de la señal de autenticación fallida. **Hoy no
aporta nada**, porque no hay Istio en el clúster.

```bash
gcloud container clusters update dev-otel-cluster \
  --region=us-central1 --project=project-546ee9f1-20e7-4368-919 \
  --logging=SYSTEM,WORKLOAD
```

Equivalente en `infrastructure/gcp/gke.tf` → `logging_config`:
`enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]`

**Revertir:** `--logging=SYSTEM`

> ⚠️ Aumenta el volumen de ingesta de Cloud Logging en proporción al tráfico.

---

## 3. GKE Security Posture — opcional

Auditoría de configuración de workloads (contenedores privilegiados,
`hostPath`, capabilities, ausencia de `securityContext`) y boletines de
seguridad de GKE. **Sin costo adicional** y, a diferencia de Security Command
Center, no requiere organización. Alimenta la alerta SEC-7.

```bash
gcloud container clusters update dev-otel-cluster \
  --region=us-central1 --project=project-546ee9f1-20e7-4368-919 \
  --security-posture=basic
```

Equivalente en `gke.tf`:

```hcl
  security_posture_config {
    mode               = "BASIC"
    vulnerability_mode = "VULNERABILITY_DISABLED"
  }
```

`vulnerability_mode` se deja desactivado a propósito: el escaneo de
vulnerabilidades de workloads de GKE quedó deprecado, y la ruta soportada para
CVEs es Artifact Analysis sobre Artifact Registry, que es lo que usa el módulo.

**Revertir:** `--security-posture=disabled`

---

## 4. Visibilidad intranodo — opcional, con ventana de mantenimiento

VPC Flow Logs **no registra el tráfico entre pods que corren en el mismo nodo**.
En un clúster de 6 nodos con 4 workloads en `services`, una parte del
este-oeste queda fuera de los flow logs.

```bash
gcloud container clusters update dev-otel-cluster \
  --region=us-central1 --project=project-546ee9f1-20e7-4368-919 \
  --enable-intra-node-visibility
```

> ⚠️ **Esto dispara una actualización continua de los nodos.** Es una operación
> soportada y sin pérdida de datos, pero mueve pods y puede causar
> interrupciones breves. En un clúster con trabajo de otros compañeros encima,
> se programa; no se hace sobre la marcha.

Se puede entregar el módulo sin activarlo: la limitación queda documentada en
`docs/MODULO-C-NETWORK-SECURITY.md` §11.

**Revertir:** `--no-enable-intra-node-visibility` (vuelve a mover los nodos).

---

## Orden recomendado

1. **§1 opción A** — flow logs con `gcloud`. Es lo único obligatorio.
2. `terraform apply` en `infrastructure/gcp-modulo-c/`.
3. `scripts/modulo-c-validacion.sh` para generar la evidencia.
4. **§3** si se quiere la señal de postura de GKE (gratis, sin riesgo).
5. **§1 opción B** cuando el dueño del state esté disponible, para que los flow
   logs no se apaguen en el próximo apply del Módulo A.
6. §2 y §4 solo si el equipo decide instalar Istio o abrir ventana de
   mantenimiento.
