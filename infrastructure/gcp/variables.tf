variable "project_id" {
  description = "ID del proyecto de GCP"
  type        = string
  # No tiene default: debe pasarse explicitamente
  # export TF_VAR_project_id=mi-proyecto-gcp
}

variable "region" {
  description = "Region de GCP para todos los recursos"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona principal de GCP"
  type        = string
  default     = "us-central1-a"
}

variable "environment" {
  description = "Nombre del entorno (production, staging, dev)"
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "dev"], var.environment)
    error_message = "environment debe ser production, staging o dev."
  }
}

variable "gke_node_count" {
  description = "Numero de nodos del GKE node pool"
  type        = number
  default     = 2
}

variable "gke_machine_type" {
  description = "Tipo de maquina para nodos GKE"
  type        = string
  default     = "e2-standard-2"  # 2 vCPU, 8 GB RAM
}

variable "db_tier" {
  description = "Tier de Cloud SQL PostgreSQL"
  type        = string
  default     = "db-f1-micro"  # Para dev; usar db-custom-2-4096 en prod
}

variable "db_user" {
  description = "Usuario de la base de datos"
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Contrasena de la base de datos"
  type        = string
  sensitive   = true
  # Pasar via: TF_VAR_db_password=secret o terraform.tfvars
}
