# ==============================================================================
# Terraform — GCP: Modulo C — Security Command Center + Artifact Analysis
# ==============================================================================
# RESTRICCION DEL PRODUCTO, no de este codigo:
#
#   Security Command Center solo se puede activar sobre una ORGANIZACION.
#   La activacion "a nivel de proyecto" que documenta Google tambien exige
#   que el proyecto pertenezca a una organizacion; lo unico que cambia es el
#   alcance de la facturacion. Un proyecto creado bajo una cuenta personal
#   (sin Cloud Identity / Workspace) queda en "No organization" y SCC no es
#   activable en el, ni por consola ni por API.
#
#   Por eso todo lo que hay aqui esta guardado por 'count' sobre
#   var.scc_organization_id, y el modulo define un plan B de paridad
#   funcional que SI funciona sin organizacion:
#
#   | Capacidad de SCC              | Sustituto sin organizacion               |
#   |-------------------------------|------------------------------------------|
#   | Vulnerability Assessment      | Artifact Analysis (escaneo on-push)      |
#   | Security Health Analytics     | GKE Security Posture (config auditing)   |
#   | Event Threat Detection        | Metricas de log de Cloud Audit Logs      |
#   | Findings API centralizada     | Cloud Monitoring + dashboard del modulo  |
#
#   La diferencia real es de alcance (SCC ve toda la organizacion y correla
#   entre proyectos) y de catalogo de detectores, no de arquitectura de la
#   solucion: la senal termina en el mismo dashboard por el mismo camino.
# ==============================================================================

# ── Topico Pub/Sub para hallazgos en tiempo real (solo con organizacion) ──────
resource "google_pubsub_topic" "scc_findings" {
  count = var.scc_organization_id == "" ? 0 : 1

  name = "${var.environment}-scc-findings"

  depends_on = [google_project_service.modulo_c_apis]
}

# ── Exportacion continua de hallazgos de SCC ─────────────────────────────────
# Envia a Pub/Sub, en el momento en que se crean o actualizan, los hallazgos
# activos de severidad alta o critica. El cve-exporter los lee (o, si se
# prefiere, se puede enganchar cualquier consumidor) y los publica como
# metrica OTel para el dashboard.
resource "google_scc_notification_config" "high_severity" {
  count = var.scc_organization_id == "" ? 0 : 1

  config_id    = "${var.environment}-high-severity"
  organization = var.scc_organization_id
  description  = "Modulo C — hallazgos activos HIGH/CRITICAL hacia Pub/Sub"
  pubsub_topic = google_pubsub_topic.scc_findings[0].id

  streaming_config {
    filter = var.scc_notification_filter
  }
}

# ==============================================================================
# Artifact Analysis — fuente de la senal "CVEs activos"
# ==============================================================================
# El escaneo automatico se activa habilitando la API containerscanning (se
# declara en main.tf, junto al resto de APIs del modulo, controlada por
# var.enable_container_scanning). Desde ese momento cada imagen que se sube al
# Artifact Registry se analiza y sus vulnerabilidades quedan como 'occurrences'
# consultables por la API de Container Analysis. No requiere organizacion.
# ==============================================================================
# Identidad del exportador de seguridad (services/cve-exporter/)
# ==============================================================================
# Un pod que lee la postura de seguridad del proyecto y la publica como
# metricas OTel. Se le da el minimo privilegio: SOLO lectura de hallazgos.

resource "google_service_account" "security_exporter" {
  account_id   = "${var.environment}-security-exporter"
  display_name = "Security Exporter — Modulo C"
  description  = "Lee hallazgos de Artifact Analysis y SCC y los publica como metricas OTel"
}

# Lectura de las vulnerabilidades detectadas en las imagenes del registro
resource "google_project_iam_member" "security_exporter_containeranalysis" {
  project = var.project_id
  role    = "roles/containeranalysis.occurrences.viewer"
  member  = "serviceAccount:${google_service_account.security_exporter.email}"
}

# Lectura de metadatos de las imagenes del Artifact Registry
resource "google_project_iam_member" "security_exporter_artifactregistry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.security_exporter.email}"
}

# Lectura de hallazgos de SCC (solo si hay organizacion)
resource "google_organization_iam_member" "security_exporter_scc" {
  count = var.scc_organization_id == "" ? 0 : 1

  org_id = var.scc_organization_id
  role   = "roles/securitycenter.findingsViewer"
  member = "serviceAccount:${google_service_account.security_exporter.email}"
}

# ── Workload Identity: el KSA observability/security-exporter actua como el GSA
resource "google_service_account_iam_member" "security_exporter_workload_identity" {
  service_account_id = google_service_account.security_exporter.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[observability/security-exporter]"
}
