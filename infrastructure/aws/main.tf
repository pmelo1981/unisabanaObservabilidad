# ==============================================================================
# Terraform — AWS: Modulo C — Network & Security Observability
# ==============================================================================
# ESTADO DE ESTE MODULO: escrito, validado (`terraform validate`) y NO aplicado.
#
# El proyecto no dispone de cuenta AWS activa; es la misma restriccion ya
# documentada en el README §9 para el backend "AWS RDS" de data-service, que
# se resuelve con el Postgres 'rds-sim' dentro de GKE. Aqui no cabe una
# simulacion equivalente: VPC Flow Logs y Security Hub son servicios
# gestionados, no protocolos que se puedan emular en otro sitio.
#
# Lo que si es exigible, y es lo que este modulo entrega, es que la solucion
# este DISENADA y CODIFICADA para los dos proveedores con paridad de senales.
# La tabla de equivalencias esta en docs/MODULO-C-NETWORK-SECURITY.md §7.
#
# Para aplicarlo en una cuenta real:
#   export AWS_PROFILE=...
#   terraform -chdir=infrastructure/aws init
#   terraform -chdir=infrastructure/aws apply -var="alert_email=..."
#
# Coste estimado en la capa gratuita: VPC Flow Logs a CloudWatch factura por
# ingesta (~0.50 USD/GB); Security Hub CSPM ofrece 30 dias de prueba y luego
# ~0.0010 USD por comprobacion; GuardDuty, 30 dias de prueba. Un laboratorio
# de una semana con este volumen se queda por debajo de 5 USD.
# ==============================================================================

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "otel-lab"
      Environment = var.environment
      ManagedBy   = "terraform"
      Modulo      = "C-network-security-observability"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
