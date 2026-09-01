# ==============================================================================
# Terraform — Modulo C: variables
# ==============================================================================

variable "project_id" {
  description = "ID del proyecto de GCP. Verificado: project-546ee9f1-20e7-4368-919"
  type        = string
}

variable "region" {
  description = "Region de los recursos. Verificado: us-central1"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = <<-EOT
    Prefijo de los recursos de los Modulos A/B que este modulo LEE.
    Verificado en consola: el cluster se llama 'dev-otel-cluster', la VPC
    'dev-otel-vpc' y la subred 'dev-gke-subnet', asi que el valor correcto
    para este proyecto es 'dev'.

    Si se pone mal, los data sources de main.tf fallan en el 'plan' con
    "not found": el modulo no puede aplicarse contra recursos equivocados.
  EOT
  type        = string
  default     = "dev"
}

# ── VPC Flow Logs ─────────────────────────────────────────────────────────────
# IMPORTANTE: este modulo NO gestiona la subred — la lee con un data source.
# Estas tres variables son los valores de referencia del modulo: se usan en el
# mensaje del 'check' de main.tf y en PARCHE-modulo-a.md, que es donde se
# aplican de verdad. Cambiarlas aqui no cambia la configuracion de la subred.


variable "flow_logs_aggregation_interval" {
  description = <<-EOT
    Intervalo de agregacion de VPC Flow Logs. Valores validos:
    INTERVAL_5_SEC, INTERVAL_30_SEC, INTERVAL_1_MIN, INTERVAL_5_MIN,
    INTERVAL_10_MIN, INTERVAL_15_MIN.

    Trade-off: 5s da la maxima granularidad temporal (mejor MTTD) pero
    multiplica el volumen de logs ingerido (y por tanto el costo de Cloud
    Logging). 30s es el punto de equilibrio para este laboratorio: mantiene
    el MTTD objetivo del Modulo D (< 2 min) con ~1/6 del volumen.
  EOT
  type        = string
  default     = "INTERVAL_30_SEC"

  validation {
    condition = contains([
      "INTERVAL_5_SEC", "INTERVAL_30_SEC", "INTERVAL_1_MIN",
      "INTERVAL_5_MIN", "INTERVAL_10_MIN", "INTERVAL_15_MIN",
    ], var.flow_logs_aggregation_interval)
    error_message = "Intervalo de agregacion no valido."
  }
}

variable "flow_logs_sampling" {
  description = <<-EOT
    Tasa de muestreo secundario de VPC Flow Logs (0.0 a 1.0).

    Para observabilidad de SEGURIDAD se usa 1.0 (sin muestreo): un flujo
    malicioso suele ser un unico flujo de pocos bytes, y con muestreo 0.5
    la probabilidad de perderlo es del 50%. El control de costo se hace por
    'filter_expr' (excluyendo ruido conocido), no por muestreo.
  EOT
  type        = number
  default     = 1.0

  validation {
    condition     = var.flow_logs_sampling >= 0.0 && var.flow_logs_sampling <= 1.0
    error_message = "flow_logs_sampling debe estar entre 0.0 y 1.0."
  }
}

variable "flow_logs_filter_expr" {
  description = <<-EOT
    Expresion CEL que decide que flujos se registran. Por defecto excluye el
    trafico de los health checkers de Google Cloud (35.191.0.0/16 y
    130.211.0.0/22), que es constante, no representa riesgo y en un cluster
    GKE puede ser >40% de los registros.
  EOT
  type        = string
  default     = "!(inIpRange(connection.src_ip, '35.191.0.0/16') || inIpRange(connection.src_ip, '130.211.0.0/22'))"
}

# ── Alertas ───────────────────────────────────────────────────────────────────

variable "security_alert_email" {
  description = <<-EOT
    Correo destino de las alertas de seguridad. Si se deja vacio, las alert
    policies se crean SIN canal de notificacion (siguen visibles en la consola
    y en el dashboard, pero no notifican). Util para un 'terraform apply'
    de laboratorio sin spam.
  EOT
  type        = string
  default     = ""
}

variable "app_namespace" {
  description = <<-EOT
    Namespace donde viven los workloads de la aplicacion (service-a, service-b,
    data-service). Verificado en el cluster: los tres estan en 'services'; NO
    hay un namespace 'data-service'.

    Acota el alcance de la metrica security/flow_unexpected_pair al DESTINO de
    los flujos. Sin esta restriccion la metrica tambien contabiliza el trafico
    interno de la plataforma —kubelet 10250, pushgateway 9091, node-local-dns
    10054— que es legitimo y no pertenece a la matriz de la aplicacion. Ese
    fue uno de los dos origenes de la tormenta de falsos positivos del
    2026-09-01 (el detalle completo esta en network-security.tf).
  EOT
  type        = string
  default     = "services"
}

variable "ew_allowed_ports" {
  description = <<-EOT
    Puertos legitimos del trafico este-oeste del mesh. Todo flujo pod->pod
    hacia un puerto FUERA de esta lista se contabiliza como 'par inesperado'
    y dispara la alerta deterministica de trafico anomalo (SEC-2).

    Solo se evaluan los puertos de SERVIDOR (dest_port<32768). VPC Flow Logs
    registra tambien la direccion de respuesta de cada conexion, cuyo destino
    es el puerto efimero del cliente; incluirla hacia que toda conversacion
    legitima se denunciara a si misma. Ver network-security.tf.

    ⚠️  Esta lista se verifico contra los charts reales de helm/, NO contra
    supuestos. Los puertos de los servicios NO son todos 8080:

      8000         service-a    (helm/service-a/values.yaml: service.port)
      8001         service-b    (helm/service-b/values.yaml: service.port)
      8080         data-service (helm/data-service/values.yaml: service.port)
      5432         PostgreSQL   (Cloud SQL privado y rds-sim)
      4317 / 4318  OTLP gRPC / HTTP hacia el Collector
      8888 / 8889  scrape de Prometheus sobre el Collector
      9090         Prometheus
      3000         Grafana
      14250/14268/14269/16685/16686/9411  Jaeger (colector, query, admin, zipkin)
      53           DNS (kube-dns)
      15006/15008/15012/15020/15021/15090  plano de datos y control de Istio

    Si se anade un servicio nuevo al sistema, su puerto va aqui Y en
    security/opcional-istio/authorization-policy.yaml. Los dos artefactos declaran la misma
    matriz de comunicacion y se revisan juntos: olvidar este produce una
    alerta SEC-2 permanente, y la reaccion natural del operador ante una
    alerta permanente es silenciarla.
  EOT
  type        = list(number)
  default = [
    53, 3000, 4317, 4318, 5432, 8000, 8001, 8080, 8888, 8889, 9090, 9411,
    14250, 14268, 14269, 15006, 15008, 15012, 15020, 15021, 15090, 16685, 16686,
  ]
}

variable "ew_traffic_baseline_deviation_percent" {
  description = <<-EOT
    Desviacion porcentual sobre el periodo anterior a partir de la cual el
    volumen este-oeste se considera anomalo (ALIGN_PERCENT_CHANGE).
    300 = el trafico se cuadruplico respecto de la ventana previa.

    Se usa un baseline movil en vez de un umbral estatico por la misma razon
    documentada en el ADR-002: el 35% de los falsos positivos del sistema
    actual provienen de estacionalidad que ningun umbral fijo cubre.
  EOT
  type        = number
  default     = 300
}

variable "denied_connections_threshold" {
  description = "Conexiones denegadas por el firewall en 5 min que disparan alerta de escaneo."
  type        = number
  default     = 10
}

variable "failed_auth_threshold" {
  description = "Intentos de autenticacion/autorizacion fallidos en 5 min que disparan alerta."
  type        = number
  default     = 5
}

# ── Security Command Center ───────────────────────────────────────────────────

variable "scc_organization_id" {
  description = <<-EOT
    ID numerico de la organizacion de GCP (sin el prefijo 'organizations/').

    Si se deja vacio, TODOS los recursos de Security Command Center se omiten
    (count = 0) y el modulo cae al plan B documentado en
    docs/MODULO-C-NETWORK-SECURITY.md: GKE Security Posture + Artifact
    Analysis + Cloud Audit Logs, que no requieren organizacion.

    SCC no es activable en un proyecto que no pertenece a una organizacion:
    es una limitacion del producto, no de este codigo.
  EOT
  type        = string
  default     = ""
}

variable "scc_notification_filter" {
  description = "Filtro de hallazgos de SCC que se exportan a Pub/Sub -> Cloud Logging."
  type        = string
  default     = "state=\"ACTIVE\" AND severity=\"HIGH\" OR severity=\"CRITICAL\""
}

# ── Cloud Audit Logs ──────────────────────────────────────────────────────────

variable "data_access_audit_services" {
  description = <<-EOT
    Servicios para los que se habilitan Data Access audit logs (DATA_READ /
    DATA_WRITE). Los Admin Activity logs son gratuitos y siempre estan
    activos; los Data Access NO lo son, y su volumen puede ser alto.

    Se habilita solo Secret Manager por defecto: es donde vive la DSN de la
    base de datos, y un PERMISSION_DENIED contra ese secreto es exactamente
    la senal de 'intento de autenticacion fallido' con mas valor forense y
    menos ruido del proyecto.
  EOT
  type        = list(string)
  default     = ["secretmanager.googleapis.com"]
}

# ── Artifact Analysis (CVEs) ──────────────────────────────────────────────────

variable "enable_container_scanning" {
  description = <<-EOT
    Habilita Artifact Analysis (escaneo automatico on-push de las imagenes
    subidas a Artifact Registry). Es la fuente de la senal 'CVEs activos'
    del dashboard: el escaneo de vulnerabilidades de workloads de GKE quedo
    deprecado, y Artifact Analysis es el camino soportado.
  EOT
  type        = bool
  default     = true
}


variable "enable_cve_alert" {
  description = <<-EOT
    Crea la alerta SEC-6 (CVE critico activo).

    Por defecto FALSE, y no por comodidad: el tramo Collector -> Cloud
    Monitoring del pipeline de metricas esta roto en el proyecto, asi que la
    metrica custom.googleapis.com/otel/security.cves.active no existe y crear
    la politica falla con un 404 en cada 'terraform apply'.

    El diagnostico completo esta en security-alerts.tf (bloque SEC-6) y el
    arreglo, que pertenece al Modulo A, en PARCHE-modulo-a.md seccion 5.
    Resumen: el Deployment 'otel-collector' usa la KSA 'default' sin anotacion
    de Workload Identity, asi que corre sin identidad de GCP.

    Poner a true DESPUES de aplicar ese parche y de comprobar que la metrica
    aparece:

      gcloud logging read ... # no: se comprueba en Monitoring, no en Logging
      curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token)" \
        --data-urlencode 'filter=metric.type=has_substring("security.cves")' \
        "https://monitoring.googleapis.com/v3/projects/$PROJECT/metricDescriptors"
  EOT
  type        = bool
  default     = false
}
