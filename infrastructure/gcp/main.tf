# ==============================================================================
# Terraform — GCP: Provider + APIs
# Proyecto: OTel Lab
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }

  # Descomenta para usar backend remoto (GCS)
  # backend "gcs" {
  #   bucket = "otel-lab-tf-state"
  #   prefix = "gcp"
  # }
}

# ── Provider principal ────────────────────────────────────────────────────────
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ── APIs de GCP requeridas ────────────────────────────────────────────────────
resource "google_project_service" "required_apis" {
  for_each = toset([
    "container.googleapis.com",          # GKE
    "sqladmin.googleapis.com",           # Cloud SQL
    "artifactregistry.googleapis.com",   # Artifact Registry (Docker images)
    "compute.googleapis.com",            # VPC, IPs
    "logging.googleapis.com",            # Cloud Logging
    "monitoring.googleapis.com",         # Cloud Monitoring
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",  # VPC peering para Cloud SQL
    "secretmanager.googleapis.com",      # Secret Manager
  ])

  service            = each.value
  disable_on_destroy = false
}

# ── VPC ────────────────────────────────────────────────────────────────────────
resource "google_compute_network" "otel_vpc" {
  name                    = "${var.environment}-otel-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.required_apis]
}

resource "google_compute_subnetwork" "gke_subnet" {
  name          = "${var.environment}-gke-subnet"
  ip_cidr_range = "10.0.0.0/20"
  network       = google_compute_network.otel_vpc.id
  region        = var.region

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.48.0.0/14"
  }
  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.52.0.0/20"
  }
}

# ── Artifact Registry ──────────────────────────────────────────────────────────
resource "google_artifact_registry_repository" "otel_images" {
  location      = var.region
  repository_id = "otel-lab"
  description   = "OTel Lab Docker images"
  format        = "DOCKER"
  depends_on    = [google_project_service.required_apis]
}
