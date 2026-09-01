# ==============================================================================
# Terraform — GCP: Modulo C — Dashboard "Golden Signals de Seguridad"
# ==============================================================================
# El dashboard vive como codigo (plantilla JSON + Terraform), igual que el
# dashboard de SLIs de Grafana del Modulo A. Se despliega en Cloud Monitoring
# porque ahi es donde nacen las senales nativas (flow logs, firewall logs,
# audit logs) sin necesidad de un exportador intermedio.
#
# El equivalente para Grafana, alimentado por las metricas de Istio/Envoy que
# ya scrapea Prometheus, esta en grafana/dashboards/security-golden-signals.json.
# Los dos paneles son complementarios, no redundantes:
#
#   Cloud Monitoring  -> capa L3/L4: quien hablo con quien, cuantos bytes,
#                        que se denego. Ve el trafico que NO pasa por el mesh.
#   Grafana / Istio    -> capa L7: que ruta, que codigo de respuesta, que
#                        identidad SPIFFE. Ve la intencion, no solo el paquete.
# ==============================================================================

resource "google_monitoring_dashboard" "security_golden_signals" {
  dashboard_json = templatefile("${path.module}/dashboards/security-golden-signals.json.tftpl", {
    project_id             = var.project_id
    failed_auth_threshold  = var.failed_auth_threshold
    denied_threshold       = var.denied_connections_threshold
    alert_unexpected_pair  = google_monitoring_alert_policy.unexpected_service_pair.name
    alert_anomalous_egress = google_monitoring_alert_policy.anomalous_egress.name
  })

  depends_on = [
    google_logging_metric.failed_auth_control_plane,
    google_logging_metric.failed_auth_workload,
    google_logging_metric.flow_east_west,
    google_logging_metric.flow_east_west_bytes,
    google_logging_metric.flow_ingress_internet,
    google_logging_metric.flow_egress_internet,
    google_logging_metric.flow_egress_internet_bytes,
    google_logging_metric.flow_unexpected_pair,
    google_logging_metric.firewall_denied,
  ]
}
