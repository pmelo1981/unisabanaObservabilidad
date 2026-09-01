variable "region" {
  description = "Region de AWS"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Nombre del entorno"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC del laboratorio. Espeja el 10.0.0.0/20 de la subred de GKE en GCP para que las reglas de deteccion E-W sean comparables entre nubes."
  type        = string
  default     = "10.100.0.0/16"
}

variable "flow_logs_retention_days" {
  description = "Retencion de los VPC Flow Logs en CloudWatch Logs"
  type        = number
  default     = 14
}

variable "flow_logs_max_aggregation_interval" {
  description = <<-EOT
    Intervalo maximo de agregacion de los flujos, en segundos. AWS solo admite
    60 o 600. Se usa 60 por la misma razon que en GCP se usa INTERVAL_30_SEC:
    el objetivo de MTTD del Modulo D es < 2 min, y con 600 s la deteccion
    nunca podria bajar de 10 minutos.
  EOT
  type        = number
  default     = 60

  validation {
    condition     = contains([60, 600], var.flow_logs_max_aggregation_interval)
    error_message = "AWS solo admite 60 o 600 segundos."
  }
}

variable "alert_email" {
  description = "Correo suscrito al topico SNS de alertas de seguridad. Vacio = no se crea suscripcion."
  type        = string
  default     = ""
}

variable "rejected_connections_threshold" {
  description = "Conexiones REJECT en 5 min que disparan la alarma de escaneo (equivalente a SEC-4 en GCP)"
  type        = number
  default     = 10
}

variable "failed_auth_threshold" {
  description = "Llamadas a la API rechazadas por permisos en 5 min que disparan alarma (equivalente a SEC-1 en GCP)"
  type        = number
  default     = 5
}

variable "enable_guardduty" {
  description = "Habilita GuardDuty. Es la pieza que en AWS cubre lo que en GCP hace Event Threat Detection de SCC."
  type        = bool
  default     = true
}

variable "enable_inspector" {
  description = "Habilita Amazon Inspector para el escaneo de CVEs de imagenes en ECR (equivalente a Artifact Analysis)."
  type        = bool
  default     = true
}
