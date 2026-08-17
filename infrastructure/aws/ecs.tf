# ==============================================================================
# Terraform — AWS: ECS Fargate Cluster + Services
# ==============================================================================

# ── ECS Cluster ───────────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "otel" {
  name = "${var.environment}-otel-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "otel" {
  cluster_name       = aws_ecs_cluster.otel.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

# ── IAM Role para tareas ECS ──────────────────────────────────────────────────
resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.environment}-otel-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "${var.environment}-otel-ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# Permisos para el OTel Collector (X-Ray + CloudWatch)
resource "aws_iam_role_policy" "otel_collector_permissions" {
  name = "otel-collector-permissions"
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "cloudwatch:PutMetricData",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams",
        ]
        Resource = "*"
      }
    ]
  })
}

# ── CloudWatch Log Groups ──────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "service_a" {
  name              = "/ecs/${var.environment}/service-a"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "service_b" {
  name              = "/ecs/${var.environment}/service-b"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "otel_collector" {
  name              = "/ecs/${var.environment}/otel-collector"
  retention_in_days = 7
}

# ── Security Groups ───────────────────────────────────────────────────────────
resource "aws_security_group" "ecs_services" {
  name        = "${var.environment}-ecs-services-sg"
  description = "Security group para servicios ECS"
  vpc_id      = aws_vpc.otel_vpc.id

  ingress {
    from_port   = 8000
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "HTTP services"
  }

  ingress {
    from_port   = 4317
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "OTLP gRPC + HTTP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── Task Definition: service-b ─────────────────────────────────────────────────
resource "aws_ecs_task_definition" "service_b" {
  family                   = "${var.environment}-service-b"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.ecs_task_cpu
  memory                   = var.ecs_task_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "service-b"
      image     = var.service_b_image != "" ? var.service_b_image : "${aws_ecr_repository.service_b.repository_url}:latest"
      essential = true
      portMappings = [{ containerPort = 8001, protocol = "tcp" }]
      environment = [
        { name = "OTEL_SERVICE_NAME",              value = "service-b" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT",   value = "http://localhost:4317" },
        { name = "DEPLOYMENT_ENV",                  value = var.environment },
        { name = "CLOUD_PROVIDER",                  value = "aws" },
      ]
      secrets = [
        { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.db_url.arn }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service_b.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    },
    {
      name      = "otel-collector"
      image     = "otel/opentelemetry-collector-contrib:0.108.0"
      essential = false
      command   = ["--config=/etc/otel/config.yaml"]
      portMappings = [
        { containerPort = 4317, protocol = "tcp" },
        { containerPort = 4318, protocol = "tcp" },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.otel_collector.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ecs"
        }
      }
      environment = [
        { name = "AWS_REGION", value = var.aws_region }
      ]
    }
  ])
}

# ── ECS Service: service-b ─────────────────────────────────────────────────────
resource "aws_ecs_service" "service_b" {
  name            = "${var.environment}-service-b"
  cluster         = aws_ecs_cluster.otel.id
  task_definition = aws_ecs_task_definition.service_b.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_services.id]
    assign_public_ip = false
  }

  depends_on = [aws_iam_role_policy_attachment.ecs_task_execution_policy]
}

# ── AWS Secrets Manager para DATABASE_URL ──────────────────────────────────────
resource "aws_secretsmanager_secret" "db_url" {
  name                    = "${var.environment}/otel-lab/db-url"
  recovery_window_in_days = 0  # Para entornos de lab (no esperar)
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id     = aws_secretsmanager_secret.db_url.id
  secret_string = "postgresql://${var.db_username}:${var.db_password}@${aws_db_instance.postgres.address}:5432/labdb"
}
