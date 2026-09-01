# ==============================================================================
# Terraform — AWS: Security Hub CSPM + GuardDuty + Inspector + CloudTrail
# ==============================================================================
# Correspondencia con la pila de GCP:
#
#   Security Hub CSPM   <->  Security Command Center (agregacion de hallazgos)
#   Security Standards  <->  Security Health Analytics
#   GuardDuty           <->  Event Threat Detection
#   Inspector (ECR)     <->  Artifact Analysis / Vulnerability Assessment
#   CloudTrail          <->  Cloud Audit Logs
#
# Diferencia de fondo, y es la razon por la que el laboratorio permite elegir
# uno de los dos: Security Hub se habilita POR CUENTA, sin necesidad de una
# organizacion. SCC exige organizacion. En una cuenta AWS individual la ruta
# esta disponible; en un proyecto GCP sin organizacion, no.
# ==============================================================================

# ── Security Hub CSPM ─────────────────────────────────────────────────────────
resource "aws_securityhub_account" "main" {
  enable_default_standards  = false # se declaran explicitamente mas abajo
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

# AWS Foundational Security Best Practices: el catalogo de controles propio de
# AWS, el mas cercano en alcance a Security Health Analytics de GCP.
resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# CIS AWS Foundations Benchmark: marco reconocido, util para el informe de
# madurez del Modulo E (da un porcentaje de cumplimiento auditable).
resource "aws_securityhub_standards_subscription" "cis" {
  standards_arn = "arn:aws:securityhub:${data.aws_region.current.name}::standards/cis-aws-foundations-benchmark/v/1.4.0"
  depends_on    = [aws_securityhub_account.main]
}

# ── GuardDuty ─────────────────────────────────────────────────────────────────
resource "aws_guardduty_detector" "main" {
  count  = var.enable_guardduty ? 1 : 0
  enable = true

  datasources {
    s3_logs {
      enable = true
    }
    kubernetes {
      audit_logs {
        enable = true
      }
    }
    malware_protection {
      scan_ec2_instance_with_findings {
        ebs_volumes {
          enable = true
        }
      }
    }
  }

  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# Los hallazgos de GuardDuty se enrutan a Security Hub: un unico panel de
# cristal, igual que SCC agrega los de Event Threat Detection en GCP.
resource "aws_securityhub_product_subscription" "guardduty" {
  count       = var.enable_guardduty ? 1 : 0
  product_arn = "arn:aws:securityhub:${data.aws_region.current.name}::product/aws/guardduty"
  depends_on  = [aws_securityhub_account.main]
}

# ── Inspector: CVEs de imagenes de contenedor en ECR ─────────────────────────
resource "aws_inspector2_enabler" "main" {
  count          = var.enable_inspector ? 1 : 0
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2"]
}

resource "aws_securityhub_product_subscription" "inspector" {
  count       = var.enable_inspector ? 1 : 0
  product_arn = "arn:aws:securityhub:${data.aws_region.current.name}::product/aws/inspector-v2"
  depends_on  = [aws_securityhub_account.main]
}

# ==============================================================================
# CLOUDTRAIL — fuente de la senal "autenticacion fallida"
# ==============================================================================
resource "aws_s3_bucket" "cloudtrail" {
  bucket        = "${var.environment}-otel-cloudtrail-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    resources = [aws_s3_bucket.cloudtrail.arn]
  }

  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.environment}-otel-lab"
  retention_in_days = 14
}

resource "aws_iam_role" "cloudtrail_to_cwl" {
  name = "${var.environment}-cloudtrail-to-cwl"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_to_cwl" {
  name = "${var.environment}-cloudtrail-to-cwl"
  role = aws_iam_role.cloudtrail_to_cwl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

resource "aws_cloudtrail" "main" {
  name                          = "${var.environment}-otel-lab-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cwl.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ── Metric filter de autorizacion denegada ───────────────────────────────────
# Equivale a filtrar protoPayload.status.code=7|16 en Cloud Audit Logs.
# Es tambien el control CIS 3.1/4.x de "unauthorized API calls".
resource "aws_cloudwatch_log_metric_filter" "unauthorized_api_calls" {
  name           = "${var.environment}-unauthorized-api-calls"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  pattern = "{ ($.errorCode = \"*UnauthorizedOperation\") || ($.errorCode = \"AccessDenied*\") || ($.errorCode = \"*NotAuthorized*\") }"

  metric_transformation {
    name      = "UnauthorizedAPICalls"
    namespace = "OTelLab/Security"
    value     = "1"
    unit      = "Count"
  }
}

# ── Inicios de sesion fallidos en la consola ─────────────────────────────────
resource "aws_cloudwatch_log_metric_filter" "console_login_failures" {
  name           = "${var.environment}-console-login-failures"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name

  pattern = "{ ($.eventName = \"ConsoleLogin\") && ($.errorMessage = \"Failed authentication\") }"

  metric_transformation {
    name      = "ConsoleLoginFailures"
    namespace = "OTelLab/Security"
    value     = "1"
    unit      = "Count"
  }
}
