output "flow_logs_log_group" {
  description = "Log group de CloudWatch con los VPC Flow Logs"
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "flow_logs_s3_bucket" {
  description = "Bucket de archivo a largo plazo de los flow logs (Parquet particionado, consultable con Athena)"
  value       = aws_s3_bucket.flow_logs_archive.bucket
}

output "security_dashboard_url" {
  description = "URL del dashboard de CloudWatch"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.security_golden_signals.dashboard_name}"
}

output "security_hub_console_url" {
  description = "Consola de Security Hub CSPM"
  value       = "https://${var.region}.console.aws.amazon.com/securityhub/home?region=${var.region}#/summary"
}

output "security_alarms" {
  description = "Alarmas de seguridad creadas, con su equivalente en GCP"
  value = {
    "AWS-SEC-1  (== SEC-1 GCP)" = aws_cloudwatch_metric_alarm.unauthorized_api_calls.alarm_name
    "AWS-SEC-1b (== SEC-1 GCP)" = aws_cloudwatch_metric_alarm.console_login_failures.alarm_name
    "AWS-SEC-2  (== SEC-2 GCP)" = aws_cloudwatch_metric_alarm.unexpected_east_west.alarm_name
    "AWS-SEC-3  (== SEC-3 GCP)" = aws_cloudwatch_metric_alarm.east_west_anomaly.alarm_name
    "AWS-SEC-4  (== SEC-4 GCP)" = aws_cloudwatch_metric_alarm.rejected_connections.alarm_name
    "AWS-SEC-5  (== SEC-5 GCP)" = aws_cloudwatch_metric_alarm.egress_anomaly.alarm_name
  }
}
