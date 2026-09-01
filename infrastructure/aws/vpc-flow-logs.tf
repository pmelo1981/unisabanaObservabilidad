# ==============================================================================
# Terraform — AWS: VPC + Flow Logs + metricas derivadas
# ==============================================================================

# ── Red minima sobre la que observar ──────────────────────────────────────────
resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.environment}-otel-vpc" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, 0)
  availability_zone = "${var.region}a"

  tags = { Name = "${var.environment}-otel-private" }
}

# ==============================================================================
# VPC FLOW LOGS
# ==============================================================================
# Doble destino, por dos motivos distintos:
#
#   CloudWatch Logs — destino "caliente". Permite metric filters y alarmas en
#     tiempo casi real. Es el equivalente funcional de Cloud Logging + metricas
#     basadas en logs en GCP.
#
#   S3 — destino "frio". Retencion barata a largo plazo en Parquet para
#     analisis forense con Athena. En GCP este papel lo cumpliria un sink de
#     Cloud Logging hacia BigQuery.
#
# El formato de registro se declara explicitamente en vez de usar el de por
# defecto: los campos pkt-srcaddr / pkt-dstaddr son los que permiten ver la IP
# real del pod detras de un NAT o un balanceador, igual que src_gke_details
# hace en GCP. Sin ellos, todo el trafico este-oeste de EKS pareceria venir de
# la ENI del nodo.
resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.environment}-flow-logs"
  retention_in_days = var.flow_logs_retention_days
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.environment}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.environment}-vpc-flow-logs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
    }]
  })
}

locals {
  # Formato de registro extendido. El orden importa: los metric filters de mas
  # abajo posicionan los campos por indice.
  flow_log_format = join(" ", [
    "$${version}", "$${account-id}", "$${interface-id}",
    "$${srcaddr}", "$${dstaddr}", "$${srcport}", "$${dstport}",
    "$${protocol}", "$${packets}", "$${bytes}",
    "$${start}", "$${end}", "$${action}", "$${log-status}",
    "$${vpc-id}", "$${subnet-id}", "$${instance-id}", "$${tcp-flags}",
    "$${type}", "$${pkt-srcaddr}", "$${pkt-dstaddr}",
    "$${flow-direction}", "$${traffic-path}",
  ])
}

resource "aws_flow_log" "to_cloudwatch" {
  vpc_id                   = aws_vpc.lab.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  log_format               = local.flow_log_format
  max_aggregation_interval = var.flow_logs_max_aggregation_interval

  tags = { Name = "${var.environment}-flow-logs-cw" }
}

resource "aws_s3_bucket" "flow_logs_archive" {
  bucket        = "${var.environment}-otel-flow-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "flow_logs_archive" {
  bucket = aws_s3_bucket.flow_logs_archive.id

  rule {
    id     = "expira-flujos-antiguos"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_flow_log" "to_s3" {
  vpc_id               = aws_vpc.lab.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = aws_s3_bucket.flow_logs_archive.arn

  destination_options {
    file_format                = "parquet"
    hive_compatible_partitions = true
    per_hour_partition         = true
  }

  tags = { Name = "${var.environment}-flow-logs-s3" }
}

# ==============================================================================
# METRIC FILTERS — las mismas senales que en GCP, expresadas en sintaxis CWL
# ==============================================================================
# Los indices de los campos siguen local.flow_log_format:
#   1 version, 2 account, 3 eni, 4 srcaddr, 5 dstaddr, 6 srcport, 7 dstport,
#   8 protocol, 9 packets, 10 bytes, 11 start, 12 end, 13 action, 14 status,
#   ... 22 flow-direction

# ── Conexiones rechazadas (equivalente a security/firewall_denied) ────────────
resource "aws_cloudwatch_log_metric_filter" "rejected_connections" {
  name           = "${var.environment}-rejected-connections"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  pattern = "[version, account, eni, srcaddr, dstaddr, srcport, dstport, protocol, packets, bytes, start, end, action=REJECT, status, ...]"

  metric_transformation {
    name      = "RejectedConnections"
    namespace = "OTelLab/Security"
    value     = "1"
    unit      = "Count"
  }
}

# ── Trafico este-oeste (equivalente a security/flow_east_west) ────────────────
# Ambos extremos dentro del CIDR de la VPC.
resource "aws_cloudwatch_log_metric_filter" "east_west_bytes" {
  name           = "${var.environment}-east-west-bytes"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  pattern = "[version, account, eni, srcaddr=10.100.*, dstaddr=10.100.*, srcport, dstport, protocol, packets, bytes, start, end, action=ACCEPT, status, ...]"

  metric_transformation {
    name      = "EastWestBytes"
    namespace = "OTelLab/Security"
    value     = "$bytes"
    unit      = "Bytes"
  }
}

# ── Trafico norte-sur saliente (equivalente a security/flow_egress_internet) ──
resource "aws_cloudwatch_log_metric_filter" "north_south_egress_bytes" {
  name           = "${var.environment}-north-south-egress-bytes"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  pattern = "[version, account, eni, srcaddr=10.100.*, dstaddr!=10.100.*, srcport, dstport, protocol, packets, bytes, start, end, action=ACCEPT, status, ...]"

  metric_transformation {
    name      = "NorthSouthEgressBytes"
    namespace = "OTelLab/Security"
    value     = "$bytes"
    unit      = "Bytes"
  }
}

# ── Trafico norte-sur entrante ───────────────────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "north_south_ingress_bytes" {
  name           = "${var.environment}-north-south-ingress-bytes"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  pattern = "[version, account, eni, srcaddr!=10.100.*, dstaddr=10.100.*, srcport, dstport, protocol, packets, bytes, start, end, action=ACCEPT, status, ...]"

  metric_transformation {
    name      = "NorthSouthIngressBytes"
    namespace = "OTelLab/Security"
    value     = "$bytes"
    unit      = "Bytes"
  }
}

# ── Trafico E-W hacia puertos fuera de la matriz autorizada ──────────────────
# Equivalente a security/flow_unexpected_pair. En CWL no hay una sintaxis de
# "NOT IN (lista)", asi que se expresa como conjuncion de desigualdades.
resource "aws_cloudwatch_log_metric_filter" "unexpected_east_west" {
  name           = "${var.environment}-unexpected-east-west"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  pattern = "[version, account, eni, srcaddr=10.100.*, dstaddr=10.100.*, srcport, dstport!=8080 && dstport!=5432 && dstport!=4317 && dstport!=4318 && dstport!=53, protocol, packets, bytes, start, end, action=ACCEPT, status, ...]"

  metric_transformation {
    name      = "UnexpectedEastWestFlows"
    namespace = "OTelLab/Security"
    value     = "1"
    unit      = "Count"
  }
}
