# ===============================================================================
# Cloud Monitoring - Application anomaly detection
# ===============================================================================

resource "google_monitoring_alert_policy" "correlated_anomaly" {
  display_name = "[APP-1] Anomalia correlacionada en data-service"
  combiner     = "OR"

  documentation {
    content   = <<-EOT
      El detector de data-service publico una anomalia correlacionada.

      La condicion solo se activa cuando $error_z > 2 sigma$ y $latency_p99 > 200 ms$.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Detector correlacionado activo durante 60 segundos"

    condition_threshold {
      filter          = "metric.type=\"workload.googleapis.com/anomaly_detector_correlated_firing\" AND resource.type=\"generic_node\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }
}