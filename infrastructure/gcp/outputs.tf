output "gke_cluster_name" {
  description = "Nombre del cluster GKE"
  value       = google_container_cluster.otel_cluster.name
}

output "gke_cluster_endpoint" {
  description = "Endpoint del API server de GKE"
  value       = google_container_cluster.otel_cluster.endpoint
  sensitive   = true
}

output "gke_get_credentials_command" {
  description = "Comando para obtener credenciales de kubectl"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.otel_cluster.name} --region ${var.region} --project ${var.project_id}"
}

output "artifact_registry_url" {
  description = "URL del Artifact Registry para push de imagenes"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.otel_images.repository_id}"
}

output "postgres_private_ip" {
  description = "IP privada de Cloud SQL PostgreSQL"
  value       = google_sql_database_instance.otel_postgres.private_ip_address
  sensitive   = true
}

output "postgres_connection_name" {
  description = "Connection name para Cloud SQL Proxy"
  value       = google_sql_database_instance.otel_postgres.connection_name
}

output "db_secret_name" {
  description = "Nombre del secret en Secret Manager con DATABASE_URL"
  value       = google_secret_manager_secret.db_url.secret_id
}

output "helm_deploy_commands" {
  description = "Comandos para desplegar con Helm despues de terraform apply"
  value = <<-EOT
    # 1. Obtener credenciales de kubectl
    gcloud container clusters get-credentials ${google_container_cluster.otel_cluster.name} --region ${var.region} --project ${var.project_id}

    # 2. Construir y subir imagenes
    docker build -t ${var.region}-docker.pkg.dev/${var.project_id}/otel-lab/service-a:latest ./services/service-a
    docker push ${var.region}-docker.pkg.dev/${var.project_id}/otel-lab/service-a:latest
    docker build -t ${var.region}-docker.pkg.dev/${var.project_id}/otel-lab/service-b:latest ./services/service-b
    docker push ${var.region}-docker.pkg.dev/${var.project_id}/otel-lab/service-b:latest

    # 3. Desplegar OTel stack (Collector + Jaeger + Prometheus + Grafana)
    helm upgrade --install otel-stack ./helm/otel-stack -n observability --create-namespace

    # 4. Desplegar servicios
    helm upgrade --install service-b ./helm/service-b -n services --create-namespace
    helm upgrade --install service-a ./helm/service-a -n services
  EOT
}
