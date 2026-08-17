# ==============================================================================
# Terraform — AWS: RDS PostgreSQL
# ==============================================================================

# ── Subnet Group para RDS ──────────────────────────────────────────────────────
resource "aws_db_subnet_group" "otel" {
  name       = "${var.environment}-otel-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = { Name = "${var.environment}-otel-db-subnet-group" }
}

# ── Security Group para RDS ────────────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "${var.environment}-otel-rds-sg"
  description = "Security group para RDS PostgreSQL"
  vpc_id      = aws_vpc.otel_vpc.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_services.id]
    description     = "PostgreSQL desde ECS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── RDS Instance ───────────────────────────────────────────────────────────────
resource "aws_db_instance" "postgres" {
  identifier     = "${var.environment}-otel-postgres"
  engine         = "postgres"
  engine_version = "16.3"
  instance_class = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = "labdb"
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.otel.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Alta disponibilidad (Multi-AZ)
  multi_az               = false  # true en produccion real
  publicly_accessible    = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Performance Insights
  performance_insights_enabled          = true
  performance_insights_retention_period = 7

  # Logs a CloudWatch
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  deletion_protection = false  # true en produccion real
  skip_final_snapshot = true   # false en produccion real

  tags = { Name = "${var.environment}-otel-postgres" }
}
