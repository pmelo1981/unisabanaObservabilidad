# ==============================================================================
# Terraform — GCP: GKE Cluster (Standard Mode)
# ==============================================================================

# ── GKE Cluster ───────────────────────────────────────────────────────────────
resource "google_container_cluster" "otel_cluster" {
  name     = "${var.environment}-otel-cluster"
  location = var.region   # regional cluster (multi-zone, HA)

  # Requiere un node pool separado (buena practica)
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.otel_vpc.name
  subnetwork = google_compute_subnetwork.gke_subnet.name

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  # Habilitar Workload Identity para acceso a Cloud APIs desde pods
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Logging y monitoring integrado con Cloud Operations
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS"]
  }

  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }

  addons_config {
    horizontal_pod_autoscaling {
      disabled = false
    }
    http_load_balancing {
      disabled = false
    }
  }

  depends_on = [google_project_service.required_apis]
}

# ── Node Pool principal ────────────────────────────────────────────────────────
resource "google_container_node_pool" "otel_nodes" {
  name       = "${var.environment}-otel-node-pool"
  location   = var.region
  cluster    = google_container_cluster.otel_cluster.name
  node_count = var.gke_node_count

  autoscaling {
    min_node_count = 2
    max_node_count = 5
  }

  node_config {
    machine_type = var.gke_machine_type
    disk_size_gb = 50
    disk_type    = "pd-ssd"

    # Cuenta de servicio minima de privilegios
    service_account = google_service_account.gke_nodes.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# ── Service Account para nodos GKE ─────────────────────────────────────────────
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.environment}-gke-nodes-sa"
  display_name = "GKE Nodes Service Account — OTel Lab"
}

resource "google_project_iam_member" "gke_nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_nodes_artifact_registry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# ── Namespace Kubernetes para OTel ────────────────────────────────────────────
resource "kubernetes_namespace" "observability" {
  metadata {
    name = "observability"
    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }
  }
}

resource "kubernetes_namespace" "services" {
  metadata {
    name = "services"
    labels = {
      environment = var.environment
      managed-by  = "terraform"
    }
  }
}

# Provider kubernetes configurado con las credenciales del cluster
provider "kubernetes" {
  host                   = "https://${google_container_cluster.otel_cluster.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.otel_cluster.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.otel_cluster.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.otel_cluster.master_auth[0].cluster_ca_certificate)
  }
}

data "google_client_config" "default" {}
