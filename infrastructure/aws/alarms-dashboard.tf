# ==============================================================================
# Terraform — AWS: alarmas y dashboard "Golden Signals de Seguridad"
# ==============================================================================

resource "aws_sns_topic" "security_alerts" {
  name = "${var.environment}-security-alerts"
}

resource "aws_sns_topic_subscription" "security_email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ── AWS-SEC-1 — autenticacion fallida (espeja SEC-1 de GCP) ──────────────────
resource "aws_cloudwatch_metric_alarm" "unauthorized_api_calls" {
  alarm_name          = "[AWS-SEC-1] Rafaga de llamadas a la API no autorizadas"
  alarm_description   = "Equivalente a SEC-1 en GCP. Mas de ${var.failed_auth_threshold} llamadas rechazadas por permisos en 5 min. Investigar el principal en CloudTrail Insights."
  namespace           = "OTelLab/Security"
  metric_name         = aws_cloudwatch_log_metric_filter.unauthorized_api_calls.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.failed_auth_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "console_login_failures" {
  alarm_name          = "[AWS-SEC-1b] Inicios de sesion fallidos en la consola"
  alarm_description   = "Tres o mas autenticaciones fallidas en consola en 5 min: fuerza bruta o credencial rotada sin actualizar."
  namespace           = "OTelLab/Security"
  metric_name         = aws_cloudwatch_log_metric_filter.console_login_failures.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}

# ── AWS-SEC-2 — trafico E-W no autorizado (espeja SEC-2) ─────────────────────
resource "aws_cloudwatch_metric_alarm" "unexpected_east_west" {
  alarm_name          = "[AWS-SEC-2] Trafico E-W hacia un puerto no autorizado"
  alarm_description   = "Equivalente a SEC-2 en GCP. Flujo aceptado entre dos direcciones internas hacia un puerto fuera de la matriz de comunicacion."
  namespace           = "OTelLab/Security"
  metric_name         = aws_cloudwatch_log_metric_filter.unexpected_east_west.metric_transformation[0].name
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}

# ── AWS-SEC-3 — volumen E-W anomalo (espeja SEC-3) ───────────────────────────
# CloudWatch Anomaly Detection cumple aqui el papel que en GCP cumple
# ALIGN_PERCENT_CHANGE: banda de confianza aprendida en vez de umbral fijo.
resource "aws_cloudwatch_metric_alarm" "east_west_anomaly" {
  alarm_name          = "[AWS-SEC-3] Volumen E-W fuera de la banda esperada"
  alarm_description   = "Equivalente a SEC-3 en GCP. El volumen este-oeste salio de la banda de anomalia aprendida (2 desviaciones). No usa umbral estatico."
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "banda"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "volumen"
    return_data = true

    metric {
      namespace   = "OTelLab/Security"
      metric_name = aws_cloudwatch_log_metric_filter.east_west_bytes.metric_transformation[0].name
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "banda"
    expression  = "ANOMALY_DETECTION_BAND(volumen, 2)"
    label       = "Banda esperada de trafico E-W"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}

# ── AWS-SEC-4 — conexiones rechazadas (espeja SEC-4) ─────────────────────────
resource "aws_cloudwatch_metric_alarm" "rejected_connections" {
  alarm_name          = "[AWS-SEC-4] Conexiones rechazadas por security groups / NACL"
  alarm_description   = "Equivalente a SEC-4 en GCP. Mas de ${var.rejected_connections_threshold} flujos REJECT en 5 min: escaneo de puertos o servicio mal configurado."
  namespace           = "OTelLab/Security"
  metric_name         = aws_cloudwatch_log_metric_filter.rejected_connections.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.rejected_connections_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}

# ── AWS-SEC-5 — egress anomalo (espeja SEC-5) ────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "egress_anomaly" {
  alarm_name          = "[AWS-SEC-5] Egress a Internet fuera de la banda esperada"
  alarm_description   = "Equivalente a SEC-5 en GCP. Senal primaria de exfiltracion: el caudal saliente se sale de la banda aprendida."
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "banda"
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "egress"
    return_data = true

    metric {
      namespace   = "OTelLab/Security"
      metric_name = aws_cloudwatch_log_metric_filter.north_south_egress_bytes.metric_transformation[0].name
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "banda"
    expression  = "ANOMALY_DETECTION_BAND(egress, 2)"
    label       = "Banda esperada de egress"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.security_alerts.arn]
}

# ==============================================================================
# DASHBOARD
# ==============================================================================
resource "aws_cloudwatch_dashboard" "security_golden_signals" {
  dashboard_name = "${var.environment}-golden-signals-seguridad"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "text", x = 0, y = 0, width = 24, height = 1
        properties = {
          markdown = "## Golden Signals de Seguridad — Modulo C (AWS)\nAutenticacion fallida · Trafico N-S / E-W · CVEs activos. Fuentes: VPC Flow Logs, CloudTrail, Security Hub CSPM e Inspector."
        }
      },
      {
        type = "metric", x = 0, y = 1, width = 8, height = 6
        properties = {
          title = "Golden Signal 1 — Autenticacion fallida",
          view  = "timeSeries", stacked = true, region = var.region, period = 300, stat = "Sum",
          metrics = [
            ["OTelLab/Security", "UnauthorizedAPICalls", { label = "Llamadas API no autorizadas" }],
            ["OTelLab/Security", "ConsoleLoginFailures", { label = "Logins de consola fallidos" }],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 1, width = 8, height = 6
        properties = {
          title = "Golden Signal 2 — Trafico N-S vs E-W (bytes)",
          view  = "timeSeries", stacked = false, region = var.region, period = 300, stat = "Sum",
          metrics = [
            ["OTelLab/Security", "EastWestBytes", { label = "Este-Oeste" }],
            ["OTelLab/Security", "NorthSouthIngressBytes", { label = "Norte-Sur entrante" }],
            ["OTelLab/Security", "NorthSouthEgressBytes", { label = "Norte-Sur saliente" }],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 1, width = 8, height = 6
        properties = {
          title = "Conexiones rechazadas y flujos E-W no autorizados",
          view  = "timeSeries", stacked = true, region = var.region, period = 300, stat = "Sum",
          metrics = [
            ["OTelLab/Security", "RejectedConnections", { label = "REJECT" }],
            ["OTelLab/Security", "UnexpectedEastWestFlows", { label = "E-W no autorizado" }],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 7, width = 12, height = 6
        properties = {
          title = "Golden Signal 3 — Hallazgos de Security Hub por severidad",
          view  = "timeSeries", stacked = true, region = var.region, period = 300, stat = "Maximum",
          metrics = [
            ["AWS/SecurityHub", "Findings", "Severity", "CRITICAL", { label = "CRITICAL" }],
            ["AWS/SecurityHub", "Findings", "Severity", "HIGH", { label = "HIGH" }],
            ["AWS/SecurityHub", "Findings", "Severity", "MEDIUM", { label = "MEDIUM" }],
          ]
        }
      },
      {
        type = "log", x = 12, y = 7, width = 12, height = 6
        properties = {
          title  = "Flujos rechazados recientes",
          region = var.region,
          query  = "SOURCE '${aws_cloudwatch_log_group.flow_logs.name}' | fields @timestamp, srcaddr, dstaddr, dstport, action | filter action = 'REJECT' | sort @timestamp desc | limit 50"
        }
      },
    ]
  })
}
