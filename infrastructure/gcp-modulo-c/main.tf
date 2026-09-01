# ==============================================================================
# Terraform — Modulo C: Network & Security Observability (root module aparte)
# ==============================================================================
# POR QUE ESTE MODULO VIVE EN SU PROPIO DIRECTORIO Y SU PROPIO STATE
#
# La infraestructura de los Modulos A/B (VPC, GKE, Cloud SQL, Artifact Registry)
# ya esta desplegada en el proyecto 'observabilidad'. Se creo con el Terraform
# de infrastructure/gcp/, pero ese directorio tiene el backend remoto COMENTADO
# (main.tf, lineas 28-32), asi que el state quedo en la maquina de quien aplico.
# En el repositorio no hay ningun .tfstate.
#
# Consecuencia: ejecutar 'terraform apply' desde infrastructure/gcp/ con un
# clon limpio del repo NO modificaria la infraestructura existente — intentaria
# CREARLA otra vez, y fallaria con "already exists" a mitad de camino, dejando
# un state parcial. Es la forma mas rapida de romper el trabajo de los
# companeros.
#
# Este directorio evita ese problema por completo:
#
#   - Tiene su PROPIO state, que solo conoce los recursos del Modulo C.
#   - Lee la infraestructura existente con DATA SOURCES, nunca con 'resource'.
#     Terraform no puede modificar ni destruir lo que solo lee.
#   - 'terraform destroy' aqui borra unicamente el Modulo C.
#
# La unica pieza que no se puede resolver asi son los VPC Flow Logs: GCP solo
# permite habilitarlos DENTRO del recurso de la subred, que pertenece al state
# de los Modulos A/B. Ver PARCHE-modulo-a.md para las dos formas de activarlos.
#
# ------------------------------------------------------------------------------
# USO
#
#   cd infrastructure/gcp-modulo-c
#   terraform init
#   terraform apply \
#     -var="project_id=project-546ee9f1-20e7-4368-919" \
#     -var="environment=dev" \
#     -var="region=us-central1"
#
# Valores verificados en la consola del proyecto (2026-09-01):
#   VPC       dev-otel-vpc
#   Subred    dev-gke-subnet   us-central1   10.0.0.0/20
#             secundarios: gke-pods 10.48.0.0/14, gke-services 10.52.0.0/20
#   Cluster   dev-otel-cluster  regional us-central1, 6 nodos
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.40"
    }
  }

  # Descomenta para compartir el state del Modulo C con el equipo.
  # Es lo que evitaria, para este modulo, el problema descrito arriba.
  # backend "gcs" {
  #   bucket = "otel-lab-tf-state"
  #   prefix = "modulo-c"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ==============================================================================
# APIs que necesita el Modulo C
# ==============================================================================
# 'disable_on_destroy = false' es deliberado: un 'terraform destroy' de este
# modulo no debe apagar APIs que otros modulos puedan estar usando.
resource "google_project_service" "modulo_c_apis" {
  for_each = toset(concat([
    "containeranalysis.googleapis.com", # Artifact Analysis: metadatos de CVEs
    "securitycenter.googleapis.com",    # SCC (solo util si hay organizacion)
    "cloudasset.googleapis.com",        # Inventario de activos
    "pubsub.googleapis.com",            # Transporte de hallazgos de SCC
    ],
    # El escaneo on-push factura por imagen analizada, asi que se puede omitir.
    var.enable_container_scanning ? ["containerscanning.googleapis.com"] : [],
  ))

  service            = each.value
  disable_on_destroy = false
}

# ==============================================================================
# LECTURA de la infraestructura existente — nunca escritura
# ==============================================================================

data "google_compute_network" "otel_vpc" {
  name = "${var.environment}-otel-vpc"
}

data "google_compute_subnetwork" "gke_subnet" {
  name   = "${var.environment}-gke-subnet"
  region = var.region
}

data "google_container_cluster" "otel_cluster" {
  name     = "${var.environment}-otel-cluster"
  location = var.region
}

# ==============================================================================
# NOTA sobre la comprobacion de los flow logs
# ==============================================================================
# Seria util que este modulo fallara en el 'plan' cuando los VPC Flow Logs no
# estan habilitados, porque sin ellos se aplica sin errores pero todos los
# paneles de trafico N-S/E-W quedan vacios: un fallo silencioso.
#
# No es posible: el data source google_compute_subnetwork no exporta
# log_config, asi que Terraform no puede leer ese estado. La comprobacion se
# hace en scripts/modulo-c-validacion.sh, que la consulta con gcloud y aborta
# con un mensaje explicito si estan apagados. Ejecutalo despues del apply.
