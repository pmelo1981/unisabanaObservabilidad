# ==============================================================================
# Terraform — GCP: Cloud SQL PostgreSQL
# ==============================================================================

# ── VPC Peering para Cloud SQL (acceso privado) ───────────────────────────────
resource "google_compute_global_address" "private_ip_range" {
  name          = "${var.environment}-sql-private-ip"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.otel_vpc.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.otel_vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  depends_on              = [google_project_service.required_apis]
}

# ── Cloud SQL Instance ─────────────────────────────────────────────────────────
resource "google_sql_database_instance" "otel_postgres" {
  name             = "${var.environment}-otel-postgres"
  database_version = "POSTGRES_16"
  region           = var.region

  settings {
    tier              = var.db_tier
    availability_type = "REGIONAL"  # HA con failover automatico

    disk_autoresize = true
    disk_size       = 20
    disk_type       = "PD_SSD"

    # Acceso solo via IP privada (sin IP publica)
    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = google_compute_network.otel_vpc.id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = "03:00"
      point_in_time_recovery_enabled = true
      transaction_log_retention_days = 7
    }

    maintenance_window {
      day          = 7  # Domingo
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      query_string_length     = 1024
      record_application_tags = true
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "500"  # Loguear queries > 500ms
    }
  }

  deletion_protection = false  # true en produccion real

  depends_on = [google_service_networking_connection.private_vpc_connection]
}

# ── Base de datos y usuario ────────────────────────────────────────────────────
resource "google_sql_database" "labdb" {
  name     = "labdb"
  instance = google_sql_database_instance.otel_postgres.name
  charset  = "UTF8"
}

resource "google_sql_user" "postgres_user" {
  name     = var.db_user
  instance = google_sql_database_instance.otel_postgres.name
  password = var.db_password
}

# ── Secret en Google Secret Manager (para DATABASE_URL) ──────────────────────
resource "google_secret_manager_secret" "db_url" {
  secret_id = "${var.environment}-otel-db-url"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required_apis]
}

resource "google_secret_manager_secret_version" "db_url_version" {
  secret      = google_secret_manager_secret.db_url.id
  secret_data = "postgresql://${var.db_user}:${var.db_password}@${google_sql_database_instance.otel_postgres.private_ip_address}:5432/labdb"
}

