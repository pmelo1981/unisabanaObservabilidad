# ==============================================================================
# Terraform — GCP: Modulo C — Network & Security Observability
#
#   1. Reglas de firewall con logging (senal de conexiones denegadas)
#   2. Cloud Audit Logs de acceso a datos (senal de autenticacion fallida)
#   3. Metricas basadas en logs derivadas de VPC Flow Logs, firewall logs,
#      audit logs y access logs de Envoy
#
# Los VPC Flow Logs se habilitan en la subred (ver main.tf). Este archivo es
# lo que los convierte de "un rio de JSON en Cloud Logging" en series
# temporales consultables, alertables y graficables.
# ==============================================================================

locals {
  # Nombre completo de la subred monitorizada, para los filtros de logs.
  monitored_subnet = data.google_compute_subnetwork.gke_subnet.name

  # Lista de puertos legitimos del mesh, ya formateada para la sintaxis de
  # consulta de Cloud Logging:  jsonPayload.connection.dest_port=(80 OR 443)
  ew_allowed_ports_expr = join(" OR ", [for p in var.ew_allowed_ports : tostring(p)])

  # Predicado reutilizable: "este flujo es este-oeste" (ambos extremos dentro
  # de la VPC). Si el destino fuera Internet, dest_vpc no existiria en el
  # registro; ese es exactamente el criterio que separa E-W de N-S.
  flow_log_base = <<-EOT
    log_id("compute.googleapis.com/vpc_flows")
    resource.type="gce_subnetwork"
    resource.labels.subnetwork_name="${data.google_compute_subnetwork.gke_subnet.name}"
  EOT
}

# ==============================================================================
# 1. REGLAS DE FIREWALL CON LOGGING
# ==============================================================================
# Estas reglas no son "seguridad decorativa": son SENSORES. Cada intento que
# deniegan genera un registro en compute.googleapis.com/firewall con
# disposition=DENIED, que es la materia prima de la metrica de escaneo de
# puertos y de la alerta de trafico anomalo norte-sur.

# ── Norte-Sur: bloquea y registra el acceso desde Internet a puertos de
#    administracion y de base de datos. Ningun componente legitimo de este
#    laboratorio expone estos puertos a Internet (Cloud SQL es IP privada,
#    no hay SSH a nodos: se usa Workload Identity y kubectl via API server).
resource "google_compute_firewall" "deny_admin_ingress_from_internet" {
  name        = "${var.environment}-deny-admin-ingress"
  network     = data.google_compute_network.otel_vpc.name
  description = "Modulo C — deniega y registra acceso N-S a puertos de administracion/DB"
  priority    = 900
  direction   = "INGRESS"

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "tcp"
    ports    = ["22", "23", "3389", "5432", "6379", "27017"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# ── Este-Oeste / egress: bloquea y registra la salida hacia puertos tipicos
#    de command-and-control y de movimiento lateral. Un contenedor
#    comprometido que intente "llamar a casa" queda registrado aqui.
#    No se tocan 80/443/53, de los que depende el cluster.
resource "google_compute_firewall" "deny_suspicious_egress" {
  name        = "${var.environment}-deny-suspicious-egress"
  network     = data.google_compute_network.otel_vpc.name
  description = "Modulo C — deniega y registra egress a puertos asociados a C2 / movimiento lateral"
  priority    = 900
  direction   = "EGRESS"

  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "tcp"
    ports    = ["23", "445", "1433", "3389", "4444", "5555", "6667", "9001"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# ==============================================================================
# 2. CLOUD AUDIT LOGS — DATA ACCESS
# ==============================================================================
# Los Admin Activity logs son gratuitos y estan siempre activos. Los Data
# Access NO se activan por defecto: sin esta configuracion, un intento fallido
# de leer el secreto con la DSN de la base de datos no deja rastro alguno.

resource "google_project_iam_audit_config" "data_access" {
  for_each = toset(var.data_access_audit_services)

  project = var.project_id
  service = each.value

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# ==============================================================================
# 3. METRICAS BASADAS EN LOGS
# ==============================================================================

# ── 3.1 GOLDEN SIGNAL 1: intentos de autenticacion/autorizacion fallidos ──────

# (a) Plano de control de GCP: quien intento hacer algo sin permiso.
#     status.code 7  = PERMISSION_DENIED
#     status.code 16 = UNAUTHENTICATED
resource "google_logging_metric" "failed_auth_control_plane" {
  name        = "security/failed_auth_control_plane"
  description = "Modulo C — llamadas a la API de GCP rechazadas por falta de permisos o credenciales"

  filter = <<-EOT
    (log_id("cloudaudit.googleapis.com/activity") OR log_id("cloudaudit.googleapis.com/data_access") OR log_id("cloudaudit.googleapis.com/policy"))
    AND (protoPayload.status.code=7 OR protoPayload.status.code=16)
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "principal"
      value_type  = "STRING"
      description = "Identidad que realizo el intento"
    }
    labels {
      key         = "service"
      value_type  = "STRING"
      description = "Servicio de GCP objetivo"
    }
    labels {
      key         = "method"
      value_type  = "STRING"
      description = "Metodo de la API invocado"
    }
  }

  label_extractors = {
    principal = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
    service   = "EXTRACT(protoPayload.serviceName)"
    method    = "EXTRACT(protoPayload.methodName)"
  }

  depends_on = [google_project_service.modulo_c_apis]
}

# (b) Plano de datos del mesh: 401/403 vistos por los sidecars Envoy.
#     response_flags="RBAC_ACCESS_DENIED" identifica especificamente los
#     rechazos por AuthorizationPolicy de Istio (security/opcional-istio/authorization-policy.yaml),
#     es decir, un servicio intentando hablar con otro al que no tiene derecho.
resource "google_logging_metric" "failed_auth_workload" {
  name        = "security/failed_auth_workload"
  description = "Modulo C — respuestas 401/403 registradas por los sidecars Envoy (autenticacion/autorizacion E-W y N-S)"

  filter = <<-EOT
    resource.type="k8s_container"
    resource.labels.cluster_name="${data.google_container_cluster.otel_cluster.name}"
    (jsonPayload.response_code=401 OR jsonPayload.response_code=403)
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "namespace"
      value_type  = "STRING"
      description = "Namespace del pod que devolvio el rechazo"
    }
    labels {
      key         = "response_code"
      value_type  = "STRING"
      description = "401 (no autenticado) o 403 (no autorizado)"
    }
    labels {
      key         = "response_flags"
      value_type  = "STRING"
      description = "Bandera de Envoy: RBAC_ACCESS_DENIED indica rechazo por AuthorizationPolicy"
    }
  }

  label_extractors = {
    namespace      = "EXTRACT(resource.labels.namespace_name)"
    response_code  = "EXTRACT(jsonPayload.response_code)"
    response_flags = "EXTRACT(jsonPayload.response_flags)"
  }

}

# ── 3.2 GOLDEN SIGNAL 2: trafico este-oeste ──────────────────────────────────

# Numero de flujos E-W. reporter="SRC" evita contar dos veces el mismo flujo
# (cada flujo se reporta por el extremo origen y por el destino).
resource "google_logging_metric" "flow_east_west" {
  name        = "security/flow_east_west"
  description = "Modulo C — flujos este-oeste (ambos extremos dentro de la VPC), por par de namespaces y puerto"

  filter = <<-EOT
    ${local.flow_log_base}
    jsonPayload.reporter="SRC"
    jsonPayload.src_vpc.vpc_name:*
    jsonPayload.dest_vpc.vpc_name:*
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "src_namespace"
      value_type  = "STRING"
      description = "Namespace del pod origen"
    }
    labels {
      key         = "dest_namespace"
      value_type  = "STRING"
      description = "Namespace del pod destino"
    }
    labels {
      key         = "dest_port"
      value_type  = "STRING"
      description = "Puerto destino"
    }
  }

  label_extractors = {
    src_namespace  = "EXTRACT(jsonPayload.src_gke_details.pod.pod_namespace)"
    dest_namespace = "EXTRACT(jsonPayload.dest_gke_details.pod.pod_namespace)"
    dest_port      = "EXTRACT(jsonPayload.connection.dest_port)"
  }

}

# Volumen (bytes) del trafico E-W. Es una metrica de DISTRIBUCION porque lo
# relevante para detectar exfiltracion no es la media sino la cola: un unico
# flujo de 2 GB entre dos pods que normalmente intercambian 3 KB.
resource "google_logging_metric" "flow_east_west_bytes" {
  name        = "security/flow_east_west_bytes"
  description = "Modulo C — bytes por flujo este-oeste (distribucion)"

  filter = <<-EOT
    ${local.flow_log_base}
    jsonPayload.reporter="SRC"
    jsonPayload.src_vpc.vpc_name:*
    jsonPayload.dest_vpc.vpc_name:*
  EOT

  value_extractor = "EXTRACT(jsonPayload.bytes_sent)"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "By"

    labels {
      key         = "src_namespace"
      value_type  = "STRING"
      description = "Namespace del pod origen"
    }
    labels {
      key         = "dest_namespace"
      value_type  = "STRING"
      description = "Namespace del pod destino"
    }
  }

  label_extractors = {
    src_namespace  = "EXTRACT(jsonPayload.src_gke_details.pod.pod_namespace)"
    dest_namespace = "EXTRACT(jsonPayload.dest_gke_details.pod.pod_namespace)"
  }

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 20
      growth_factor      = 4
      scale              = 64
    }
  }

}

# ── 3.3 GOLDEN SIGNAL 3: trafico norte-sur ───────────────────────────────────
# La presencia de src_location / dest_location en el registro es la marca de
# que ese extremo esta FUERA de Google Cloud: solo los endpoints externos
# llevan anotacion geografica (pais, region, ASN).

resource "google_logging_metric" "flow_ingress_internet" {
  name        = "security/flow_ingress_internet"
  description = "Modulo C — flujos norte-sur entrantes desde Internet, por pais de origen y puerto destino"

  filter = <<-EOT
    ${local.flow_log_base}
    jsonPayload.reporter="DEST"
    jsonPayload.src_location.country:*
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "src_country"
      value_type  = "STRING"
      description = "Pais de origen del extremo externo"
    }
    labels {
      key         = "dest_port"
      value_type  = "STRING"
      description = "Puerto destino dentro de la VPC"
    }
  }

  label_extractors = {
    src_country = "EXTRACT(jsonPayload.src_location.country)"
    dest_port   = "EXTRACT(jsonPayload.connection.dest_port)"
  }

}

resource "google_logging_metric" "flow_egress_internet" {
  name        = "security/flow_egress_internet"
  description = "Modulo C — flujos norte-sur salientes hacia Internet, por pais y ASN de destino"

  filter = <<-EOT
    ${local.flow_log_base}
    jsonPayload.reporter="SRC"
    jsonPayload.dest_location.country:*
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "dest_country"
      value_type  = "STRING"
      description = "Pais de destino del extremo externo"
    }
    labels {
      key         = "dest_asn"
      value_type  = "STRING"
      description = "ASN de destino: distingue un CDN legitimo de un hosting desconocido"
    }
    labels {
      key         = "dest_port"
      value_type  = "STRING"
      description = "Puerto destino"
    }
  }

  label_extractors = {
    dest_country = "EXTRACT(jsonPayload.dest_location.country)"
    dest_asn     = "EXTRACT(jsonPayload.dest_location.asn)"
    dest_port    = "EXTRACT(jsonPayload.connection.dest_port)"
  }

}

resource "google_logging_metric" "flow_egress_internet_bytes" {
  name        = "security/flow_egress_internet_bytes"
  description = "Modulo C — bytes por flujo saliente a Internet (distribucion): senal primaria de exfiltracion"

  filter = <<-EOT
    ${local.flow_log_base}
    jsonPayload.reporter="SRC"
    jsonPayload.dest_location.country:*
  EOT

  value_extractor = "EXTRACT(jsonPayload.bytes_sent)"

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "DISTRIBUTION"
    unit        = "By"

    labels {
      key         = "dest_country"
      value_type  = "STRING"
      description = "Pais de destino"
    }
  }

  label_extractors = {
    dest_country = "EXTRACT(jsonPayload.dest_location.country)"
  }

  bucket_options {
    exponential_buckets {
      num_finite_buckets = 20
      growth_factor      = 4
      scale              = 64
    }
  }

}

# ── 3.4 Trafico anomalo entre servicios (deteccion deterministica) ────────────
# La matriz de comunicacion legitima de este sistema es pequena y conocida:
# service-a -> service-b, service-a/-b -> data-service, todos -> Collector,
# data-service -> PostgreSQL. Cualquier flujo pod->pod hacia un puerto que no
# esta en esa matriz es, por definicion, inesperado.
#
# Esta metrica NO sustituye a la deteccion estadistica (ver security-alerts.tf,
# politica de desviacion sobre baseline): la complementa. La deteccion
# deterministica tiene precision ~1.0 y recall bajo; la estadistica, al reves.
#
# ------------------------------------------------------------------------------
# CORRECCION DEL 2026-09-01 — la version inicial de esta metrica genero una
# tormenta de falsos positivos (~1 correo por minuto). Dos causas reales,
# ambas verificadas leyendo los flow logs del proyecto, no supuestas:
#
#   1) VPC Flow Logs registra las DOS direcciones de cada conexion como
#      entradas independientes, ambas con reporter="SRC". En la direccion de
#      RESPUESTA el destino es el puerto EFIMERO del cliente, que nunca puede
#      estar en una lista de puertos de servicio. Ejemplo real observado:
#
#        kube-state-metrics:8080 -> prometheus-server:37936   <- la respuesta
#
#      Es decir: toda conversacion legitima cuyo puerto de servidor no
#      estuviera en la lista disparaba la alerta por su propia respuesta.
#      Filtro anadido: dest_port<32768 (Linux usa 32768-60999 como rango
#      efimero), que se queda solo con la direccion cliente -> servidor.
#
#   2) El alcance era todo el cluster. Los namespaces de plataforma hablan
#      legitimamente por puertos que no estan —ni deben estar— en la matriz
#      de la aplicacion: kubelet 10250, pushgateway 9091, node-local-dns
#      10054. Se acota el destino al namespace de la aplicacion, que es donde
#      el movimiento lateral importa para este modulo.
#
#   3) El filtro exigia reporter="SRC", y eso la dejaba CIEGA al escaneo que
#      pretende detectar. Comprobado inyectando el ataque en el cluster: una
#      conexion RECHAZADA (RST, puerto cerrado) se registra con
#
#        reporter: DEST
#
#      y NO genera registro del lado SRC. El movimiento lateral consiste
#      justamente en tocar puertos cerrados: la metrica no habria visto
#      ninguno. La restriccion estaba puesta para no contar dos veces los
#      flujos establecidos, que ambos extremos reportan — una preocupacion
#      irrelevante aqui, porque el umbral de SEC-2 es >0 (es un detector de
#      presencia, no un medidor de volumen) y la agrupacion por par de pods
#      colapsa los duplicados. Se elimina la restriccion.
#
# Comprobacion del filtro final sobre 3 HORAS de trafico real del cluster,
# con el ataque ya inyectado: devuelve EXACTAMENTE UNA entrada, y es el
# ataque (DEST, puerto 9999, service-b). Cero ruido, senal capturada.
#
# NOTA para reproducir el ataque: hay que apuntar a la IP DEL POD, no al
# nombre DNS del Service. Un Service resuelve a una ClusterIP, y una conexion
# a una ClusterIP en un puerto sin backend produce un flow log SIN
# dest_gke_details (no hay pod detras que anotar), asi que no cae en esta
# metrica por mucho que el puerto sea ilegitimo. Ver scripts/modulo-c-validacion.sh.
# ------------------------------------------------------------------------------
resource "google_logging_metric" "flow_unexpected_pair" {
  name        = "security/flow_unexpected_pair"
  description = "Modulo C — flujos este-oeste hacia puertos fuera de la matriz de comunicacion autorizada"

  filter = <<-EOT
    ${local.flow_log_base}
    jsonPayload.src_gke_details.pod.pod_namespace:*
    jsonPayload.dest_gke_details.pod.pod_namespace="${var.app_namespace}"
    jsonPayload.connection.dest_port<32768
    NOT jsonPayload.connection.dest_port=(${local.ew_allowed_ports_expr})
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "src_pod"
      value_type  = "STRING"
      description = "Pod origen del flujo inesperado"
    }
    labels {
      key         = "dest_pod"
      value_type  = "STRING"
      description = "Pod destino del flujo inesperado"
    }
    labels {
      key         = "dest_port"
      value_type  = "STRING"
      description = "Puerto no autorizado"
    }
  }

  label_extractors = {
    src_pod   = "EXTRACT(jsonPayload.src_gke_details.pod.pod_name)"
    dest_pod  = "EXTRACT(jsonPayload.dest_gke_details.pod.pod_name)"
    dest_port = "EXTRACT(jsonPayload.connection.dest_port)"
  }

}

# ── 3.5 Conexiones denegadas por el firewall ─────────────────────────────────
resource "google_logging_metric" "firewall_denied" {
  name        = "security/firewall_denied"
  description = "Modulo C — conexiones denegadas por reglas de firewall (escaneo de puertos, C2, movimiento lateral)"

  filter = <<-EOT
    log_id("compute.googleapis.com/firewall")
    jsonPayload.disposition="DENIED"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "rule"
      value_type  = "STRING"
      description = "Regla de firewall que denego el trafico"
    }
    labels {
      key         = "src_ip"
      value_type  = "STRING"
      description = "IP origen del intento"
    }
    labels {
      key         = "dest_port"
      value_type  = "STRING"
      description = "Puerto destino del intento"
    }
  }

  label_extractors = {
    rule      = "EXTRACT(jsonPayload.rule_details.reference)"
    src_ip    = "EXTRACT(jsonPayload.connection.src_ip)"
    dest_port = "EXTRACT(jsonPayload.connection.dest_port)"
  }

  depends_on = [
    google_compute_firewall.deny_admin_ingress_from_internet,
    google_compute_firewall.deny_suspicious_egress,
  ]
}

# ── 3.6 Hallazgos de configuracion de GKE Security Posture ───────────────────
# Complementa a los CVEs: un contenedor sin vulnerabilidades pero corriendo
# como root privilegiado es igual de explotable.
resource "google_logging_metric" "gke_posture_findings" {
  name        = "security/gke_posture_findings"
  description = "Modulo C — hallazgos de auditoria de configuracion de workloads de GKE Security Posture"

  filter = <<-EOT
    resource.type="k8s_cluster"
    resource.labels.cluster_name="${data.google_container_cluster.otel_cluster.name}"
    jsonPayload.@type="type.googleapis.com/cloud.kubernetes.security.containersecurity_logging.Finding"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"

    labels {
      key         = "severity"
      value_type  = "STRING"
      description = "Severidad del hallazgo"
    }
    labels {
      key         = "finding_type"
      value_type  = "STRING"
      description = "Tipo de hallazgo de configuracion"
    }
  }

  label_extractors = {
    severity     = "EXTRACT(jsonPayload.misconfig.severity)"
    finding_type = "EXTRACT(jsonPayload.finding.type)"
  }

}
