# ==============================================================================
# Terraform — GCP: Modulo C — Outputs
# ==============================================================================

output "security_dashboard_url" {
  description = "URL del dashboard 'Golden Signals de Seguridad' en Cloud Monitoring"
  value       = "https://console.cloud.google.com/monitoring/dashboards/builder/${basename(google_monitoring_dashboard.security_golden_signals.id)}?project=${var.project_id}"
}

output "flow_logs_query" {
  description = "Consulta lista para pegar en el Logs Explorer y ver los VPC Flow Logs"
  value       = "log_id(\"compute.googleapis.com/vpc_flows\") AND resource.labels.subnetwork_name=\"${data.google_compute_subnetwork.gke_subnet.name}\""
}

output "flow_logs_config" {
  description = <<-EOT
    Datos de la subred leidos del proyecto, mas el comando exacto para
    habilitar los flow logs si aun no lo estan (el data source de Terraform no
    expone ese campo; se comprueba con scripts/modulo-c-validacion.sh).
  EOT
  value = {
    subnet               = data.google_compute_subnetwork.gke_subnet.name
    region               = data.google_compute_subnetwork.gke_subnet.region
    rango                = data.google_compute_subnetwork.gke_subnet.ip_cidr_range
    intranode_visibility = data.google_container_cluster.otel_cluster.enable_intranode_visibility
    comprobar_flow_logs  = "gcloud compute networks subnets update ${var.environment}-gke-subnet --region=${var.region} --project=${var.project_id} --enable-flow-logs --logging-aggregation-interval=interval-30-sec --logging-flow-sampling=1.0 --logging-metadata=include-all"
  }
}

output "security_alert_policies" {
  description = "Politicas de alerta de seguridad creadas por el Modulo C"
  value = {
    "SEC-1_auth_fallida"       = google_monitoring_alert_policy.failed_auth.name
    "SEC-2_par_no_autorizado"  = google_monitoring_alert_policy.unexpected_service_pair.name
    "SEC-3_volumen_ew_anomalo" = google_monitoring_alert_policy.east_west_volume_anomaly.name
    "SEC-4_conexiones_negadas" = google_monitoring_alert_policy.denied_connections.name
    "SEC-5_egress_anomalo"     = google_monitoring_alert_policy.anomalous_egress.name
    "SEC-6_cve_critico"        = google_monitoring_alert_policy.critical_cve.name
    "SEC-7_postura_gke"        = google_monitoring_alert_policy.gke_posture.name
  }
}

output "security_exporter_service_account" {
  description = "Service account del exportador de seguridad (anotar en el KSA observability/security-exporter)"
  value       = google_service_account.security_exporter.email
}

output "scc_status" {
  description = "Estado de Security Command Center en este despliegue"
  value = var.scc_organization_id == "" ? join("", [
    "SCC NO activado: el proyecto no pertenece a una organizacion (var.scc_organization_id vacia). ",
    "Cobertura equivalente activa: GKE Security Posture + Artifact Analysis + Cloud Audit Logs. ",
    "Ver docs/MODULO-C-NETWORK-SECURITY.md, seccion 'Plan B sin organizacion'.",
    ]) : join("", [
    "SCC activo sobre organizations/", var.scc_organization_id,
    " con exportacion continua a Pub/Sub.",
  ])
}

output "modulo_c_next_steps" {
  description = "Pasos posteriores al apply para generar evidencia del Modulo C"
  value       = <<-EOT
    # 1. Aplicar la politica de autorizacion zero-trust del mesh

    # 2. Desplegar el exportador de seguridad (CVEs -> OTLP -> Collector)
    kubectl apply -f security/cve-exporter.yaml
    kubectl annotate serviceaccount security-exporter -n observability \
      iam.gke.io/gcp-service-account=${google_service_account.security_exporter.email}

    # 3. Importar el dashboard de Grafana
    #    grafana/dashboards/security-golden-signals.json

    # 4. Ejecutar el escenario de validacion (genera trafico anomalo y mide MTTD)
    ./scripts/modulo-c-validacion.sh ${var.project_id}
  EOT
}
