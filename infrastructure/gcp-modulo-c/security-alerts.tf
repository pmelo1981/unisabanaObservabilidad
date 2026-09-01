# ==============================================================================
#
# NOTA APRENDIDA EN EL APPLY REAL (2026-09-01):
# Cloud Monitoring RECHAZA cualquier filtro de alert policy que no restrinja
# resource.type:
#   "must specify a restriction on resource.type in the filter"
# 'terraform validate' NO detecta esto — es una validacion del servidor, no del
# esquema. Por eso todos los filtros de abajo llevan su resource.type explicito.
# Terraform — GCP: Modulo C — Politicas de alerta de seguridad
# ==============================================================================
# Filosofia de deteccion, heredada del ADR-002 (AIOps):
#
#   - Las alertas DETERMINISTICAS (par de servicios no autorizado, CVE
#     critico, hallazgo SCC) tienen precision ~1.0: si disparan, hay algo.
#     Umbral estatico > 0, sin ventana de persistencia.
#
#   - Las alertas VOLUMETRICAS (trafico E-W, egress a Internet) NO usan umbral
#     estatico. Usan ALIGN_PERCENT_CHANGE, que compara cada ventana contra la
#     ventana anterior: es un baseline movil. El ADR-002 midio que el 35% de
#     los falsos positivos del sistema actual venian de estacionalidad diaria
#     (relacion pico-valle 4:1) que ningun umbral fijo puede cubrir.
#
#   - Toda alerta lleva 'documentation' con los labels de la serie que la
#     disparo y el enlace al Logs Explorer con la consulta ya escrita: una
#     alerta que no dice que mirar no es accionable (criterio del Modulo D).
# ==============================================================================

# ── Canal de notificacion ─────────────────────────────────────────────────────
resource "google_monitoring_notification_channel" "security_email" {
  count = var.security_alert_email == "" ? 0 : 1

  display_name = "Seguridad — OTel Lab"
  type         = "email"

  labels = {
    email_address = var.security_alert_email
  }
}

locals {
  security_channels = var.security_alert_email == "" ? [] : [google_monitoring_notification_channel.security_email[0].id]

  logs_explorer_url = "https://console.cloud.google.com/logs/query;query=%s?project=${var.project_id}"

  # Etiquetas comunes: permiten filtrar el canal de seguridad en la consola
  # y separar estas alertas de las de SLO/AIOps de los modulos A/B.
  security_labels = {
    modulo  = "c"
    dominio = "security"
  }
}

# ==============================================================================
# SEC-1 — Intentos de autenticacion fallidos (Golden Signal 1)
# ==============================================================================
resource "google_monitoring_alert_policy" "failed_auth" {
  display_name = "[SEC-1] Rafaga de autenticacion/autorizacion fallida"
  combiner     = "OR"
  severity     = "WARNING"

  # Plano de control: llamadas a la API de GCP rechazadas
  conditions {
    display_name = "PERMISSION_DENIED/UNAUTHENTICATED en la API de GCP"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.failed_auth_control_plane.name}\" AND resource.type=\"audited_resource\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.failed_auth_threshold
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.principal", "metric.label.service"]
      }

      trigger {
        count = 1
      }
    }
  }

  # Plano de datos: 401/403 en los sidecars del mesh
  conditions {
    display_name = "401/403 en los sidecars Envoy"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.failed_auth_workload.name}\" AND resource.type=\"k8s_container\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.failed_auth_threshold
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.namespace", "metric.label.response_code", "metric.label.response_flags"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.security_channels

  alert_strategy {
    auto_close = "3600s"

    notification_rate_limit {
      period = "300s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[SEC-1] Autenticacion fallida en $${resource.label.project_id}"
    content   = <<-EOT
      ## Que paso

      Se superaron ${var.failed_auth_threshold} intentos fallidos de
      autenticacion/autorizacion en una ventana de 5 minutos.

      | Campo | Valor |
      |---|---|
      | Identidad / namespace | `$${metric.label.principal}$${metric.label.namespace}` |
      | Servicio | `$${metric.label.service}` |
      | Metodo | `$${metric.label.method}` |
      | Codigo | `$${metric.label.response_code}` |
      | Bandera Envoy | `$${metric.label.response_flags}` |

      ## Como interpretarlo

      - `response_flags = RBAC_ACCESS_DENIED` significa que un servicio del
        mesh intento hablar con otro al que la `AuthorizationPolicy` no le da
        derecho (`security/opcional-istio/authorization-policy.yaml`). Es movimiento lateral o un
        despliegue mal configurado, no un error del cliente.
      - Un `principal` con muchos `PERMISSION_DENIED` contra
        `secretmanager.googleapis.com` es un intento de leer la DSN de la base
        de datos.

      ## Que hacer

      1. Abrir el Logs Explorer y filtrar por la identidad/namespace de arriba.
      2. Correlacionar por `trace_id`: los logs de aplicacion llevan el
         contexto OTel inyectado, asi que el request rechazado se puede seguir
         hasta su traza completa en Jaeger.
      3. Si es RBAC del mesh, confirmar contra la matriz de comunicacion
         autorizada documentada en `docs/MODULO-C-NETWORK-SECURITY.md`.
    EOT
  }

  user_labels = local.security_labels
}

# ==============================================================================
# SEC-2 — Trafico anomalo entre servicios: par/puerto no autorizado
# ==============================================================================
# Deteccion deterministica. Umbral > 0 porque la matriz de comunicacion es
# cerrada: cualquier flujo fuera de ella es, por construccion, una desviacion.
resource "google_monitoring_alert_policy" "unexpected_service_pair" {
  display_name = "[SEC-2] Trafico E-W hacia un puerto no autorizado"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "Flujo pod->pod fuera de la matriz de comunicacion"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.flow_unexpected_pair.name}\" AND resource.type=\"gce_subnetwork\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.src_pod", "metric.label.dest_pod", "metric.label.dest_port"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.security_channels

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[SEC-2] Flujo E-W no autorizado: $${metric.label.src_pod} -> $${metric.label.dest_pod}:$${metric.label.dest_port}"
    content   = <<-EOT
      ## Que paso

      El pod `$${metric.label.src_pod}` abrio una conexion hacia
      `$${metric.label.dest_pod}` en el puerto `$${metric.label.dest_port}`,
      que no pertenece a la matriz de comunicacion autorizada del sistema
      (`var.ew_allowed_ports`).

      ## Por que importa

      Los tres microservicios de este sistema solo se hablan por un conjunto
      cerrado de puertos (8080 API, 5432 PostgreSQL, 4317/4318 OTLP, 15xxx
      plano de Istio). Un flujo fuera de ese conjunto es movimiento lateral,
      un sidecar mal configurado o un contenedor que no deberia estar ahi.

      ## Que hacer

      1. `kubectl describe pod $${metric.label.src_pod}` — verificar imagen y
         service account.
      2. Revisar los access logs de Envoy del pod origen: si el flujo no
         aparece ahi pero si en los flow logs, el trafico esta esquivando el
         sidecar (posible `excludeOutboundPorts` o pod sin inyeccion).
      3. Contrastar con la `AuthorizationPolicy`: si el mesh no lo rechazo,
         la politica tiene un hueco.
    EOT
  }

  user_labels = local.security_labels
}

# ==============================================================================
# SEC-3 — Trafico anomalo entre servicios: desviacion sobre baseline movil
# ==============================================================================
# Deteccion estadistica. ALIGN_PERCENT_CHANGE compara cada ventana de 5 min
# contra la anterior; no hay umbral absoluto que envejezca ni que haya que
# recalibrar (deriva del baseline = 11.8% de los FP segun el ADR-002).
resource "google_monitoring_alert_policy" "east_west_volume_anomaly" {
  display_name = "[SEC-3] Volumen E-W desviado del baseline"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Flujos E-W ${var.ew_traffic_baseline_deviation_percent}% por encima de la ventana anterior"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.flow_east_west.name}\" AND resource.type=\"gce_subnetwork\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.ew_traffic_baseline_deviation_percent
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENT_CHANGE"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.src_namespace", "metric.label.dest_namespace"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.security_channels

  alert_strategy {
    auto_close = "1800s"

    notification_rate_limit {
      period = "600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[SEC-3] Volumen E-W anomalo: $${metric.label.src_namespace} -> $${metric.label.dest_namespace}"
    content   = <<-EOT
      ## Que paso

      El numero de flujos este-oeste entre los namespaces
      `$${metric.label.src_namespace}` y `$${metric.label.dest_namespace}`
      subio mas de un ${var.ew_traffic_baseline_deviation_percent}% respecto
      de la ventana de 5 minutos anterior, y se mantuvo asi durante 5 minutos.

      ## Diferencia con SEC-2

      SEC-2 detecta un flujo que *no deberia existir*. SEC-3 detecta un flujo
      *legitimo en volumen ilegitimo*: enumeracion de la base de datos,
      reintentos en bucle tras un fallo, o un cliente comprometido paginando
      todo el dataset por la API valida.

      ## Que hacer

      1. Comparar con el panel de trafico E-W del dashboard *Golden Signals de
         Seguridad*: si el pico coincide con un despliegue, es ruido conocido.
      2. Cruzar con las metricas RED del dashboard de SLIs: si el volumen sube
         pero la tasa de peticiones de negocio no, el trafico no viene de
         usuarios.
      3. Revisar la distribucion `security/flow_east_west_bytes`: un p99 muy
         por encima de la media apunta a extraccion masiva de datos.
    EOT
  }

  user_labels = local.security_labels
}

# ==============================================================================
# SEC-4 — Escaneo de puertos / conexiones denegadas
# ==============================================================================
resource "google_monitoring_alert_policy" "denied_connections" {
  display_name = "[SEC-4] Conexiones denegadas por el firewall"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Mas de ${var.denied_connections_threshold} denegaciones en 5 min"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.firewall_denied.name}\" AND resource.type=\"gce_subnetwork\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.denied_connections_threshold
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.src_ip", "metric.label.rule"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.security_channels

  alert_strategy {
    auto_close = "3600s"

    notification_rate_limit {
      period = "600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[SEC-4] $${metric.label.src_ip} acumula denegaciones en $${metric.label.rule}"
    content   = <<-EOT
      ## Que paso

      La IP `$${metric.label.src_ip}` acumulo mas de
      ${var.denied_connections_threshold} conexiones denegadas por la regla
      `$${metric.label.rule}` en 5 minutos.

      ## Como leerlo

      - Regla `deny-admin-ingress` + muchos puertos destino distintos desde la
        misma IP externa = **escaneo de puertos norte-sur**.
      - Regla `deny-suspicious-egress` + IP origen *interna* = **un pod del
        cluster intentando salir a un puerto de C2**. Esto es mucho mas grave:
        implica que ya hay algo ejecutandose dentro.

      ## Que hacer

      1. Mirar el label `dest_port` en el dashboard: un solo puerto es un
         intento dirigido; muchos, un barrido.
      2. Si el origen es interno, identificar el pod por IP con
         `kubectl get pods -A -o wide | grep <ip>` y aislarlo.
    EOT
  }

  user_labels = local.security_labels
}

# ==============================================================================
# SEC-5 — Egress anomalo hacia Internet (exfiltracion)
# ==============================================================================
resource "google_monitoring_alert_policy" "anomalous_egress" {
  display_name = "[SEC-5] Egress anomalo hacia Internet"
  combiner     = "OR"
  severity     = "ERROR"

  # (a) Salto en el NUMERO de flujos salientes respecto del baseline movil
  conditions {
    display_name = "Flujos salientes desviados del baseline"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.flow_egress_internet.name}\" AND resource.type=\"gce_subnetwork\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.ew_traffic_baseline_deviation_percent
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENT_CHANGE"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.dest_country", "metric.label.dest_asn"]
      }

      trigger {
        count = 1
      }
    }
  }

  # (b) Un unico flujo saliente desproporcionado (p99 > 50 MB). Este caso NO
  #     lo detecta la condicion (a): exfiltrar 2 GB en una sola conexion es un
  #     unico flujo, no un salto en el numero de flujos.
  conditions {
    display_name = "Flujo saliente individual > 50 MB (p99)"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.flow_egress_internet_bytes.name}\" AND resource.type=\"gce_subnetwork\""
      comparison      = "COMPARISON_GT"
      threshold_value = 52428800
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_PERCENTILE_99"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.dest_country"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.security_channels

  alert_strategy {
    auto_close = "3600s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[SEC-5] Egress anomalo hacia $${metric.label.dest_country} (ASN $${metric.label.dest_asn})"
    content   = <<-EOT
      ## Que paso

      El trafico saliente hacia `$${metric.label.dest_country}`
      (ASN `$${metric.label.dest_asn}`) se desvio del comportamiento normal,
      por numero de flujos o por tamano de un flujo individual.

      ## Contexto que necesitas

      Este sistema tiene un perfil de egress muy pequeno y predecible:
      Artifact Registry, las APIs de Google (`*.googleapis.com`) y poco mas.
      Cloud SQL es IP privada. Cualquier destino externo fuera de los ASN de
      Google merece explicacion.

      ## Que hacer

      1. Filtrar los flow logs por `jsonPayload.dest_location.asn` y sacar la
         IP y el puerto destino concretos.
      2. Identificar el pod origen por `jsonPayload.src_gke_details.pod`.
      3. Contrastar con `security/flow_egress_internet_bytes`: si el p99 es
         ordenes de magnitud mayor que la mediana, es transferencia masiva,
         no telemetria.
    EOT
  }

  user_labels = local.security_labels
}

# ==============================================================================
# SEC-6 — CVE critico activo en imagenes desplegadas
# ==============================================================================
# La metrica la publica services/cve-exporter/ via OTLP -> Collector ->
# Cloud Monitoring, con el prefijo declarado en otel-collector/config-gcp.yaml
# (custom.googleapis.com/otel).
resource "google_monitoring_alert_policy" "critical_cve" {
  display_name = "[SEC-6] CVE critico activo en una imagen del registro"
  combiner     = "OR"
  severity     = "ERROR"

  conditions {
    display_name = "Al menos un CVE de severidad CRITICAL sin corregir"

    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/otel/security.cves.active\" AND resource.type=\"generic_node\" AND metric.label.severity=\"CRITICAL\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["metric.label.image", "metric.label.fixable"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.security_channels

  alert_strategy {
    auto_close = "86400s"

    notification_rate_limit {
      period = "3600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[SEC-6] CVE critico en $${metric.label.image}"
    content   = <<-EOT
      ## Que paso

      Artifact Analysis reporta al menos un CVE de severidad `CRITICAL` en la
      imagen `$${metric.label.image}`. `fixable=$${metric.label.fixable}`
      indica si existe version corregida disponible.

      ## Que hacer

      1. `gcloud artifacts docker images list-vulnerabilities <imagen>` para el
         detalle por paquete.
      2. Si `fixable=true`, reconstruir la imagen con la base actualizada y
         volver a publicar: el escaneo on-push cierra el hallazgo solo.
      3. Si `fixable=false`, documentar la excepcion y evaluar mitigacion de
         red (la `AuthorizationPolicy` del mesh limita el radio de explosion).
    EOT
  }

  user_labels = local.security_labels
}

# ==============================================================================
# SEC-7 — Hallazgo de configuracion de GKE Security Posture
# ==============================================================================
resource "google_monitoring_alert_policy" "gke_posture" {
  display_name = "[SEC-7] Hallazgo de configuracion de workload en GKE"
  combiner     = "OR"
  severity     = "WARNING"

  conditions {
    display_name = "Hallazgo de GKE Security Posture"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.gke_posture_findings.name}\" AND resource.type=\"k8s_cluster\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.severity", "metric.label.finding_type"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.security_channels

  alert_strategy {
    auto_close = "86400s"

    notification_rate_limit {
      period = "3600s"
    }
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[SEC-7] $${metric.label.finding_type} ($${metric.label.severity})"
    content   = <<-EOT
      GKE Security Posture detecto `$${metric.label.finding_type}` con
      severidad `$${metric.label.severity}` en un workload del cluster.

      Ejemplos tipicos: contenedor privilegiado, `hostPath` montado,
      capabilities de Linux innecesarias, ausencia de `securityContext`,
      o un boletin de seguridad de GKE que afecta a la version del cluster.

      Detalle completo en la consola: **Kubernetes Engine > Postura de
      seguridad**.
    EOT
  }

  user_labels = local.security_labels
}
