output "ecs_cluster_name" {
  description = "Nombre del cluster ECS"
  value       = aws_ecs_cluster.otel.name
}

output "ecr_service_a_url" {
  description = "URL del repositorio ECR para service-a"
  value       = aws_ecr_repository.service_a.repository_url
}

output "ecr_service_b_url" {
  description = "URL del repositorio ECR para service-b"
  value       = aws_ecr_repository.service_b.repository_url
}

output "rds_endpoint" {
  description = "Endpoint de RDS PostgreSQL"
  value       = aws_db_instance.postgres.address
  sensitive   = true
}

output "db_secret_arn" {
  description = "ARN del secret con DATABASE_URL en Secrets Manager"
  value       = aws_secretsmanager_secret.db_url.arn
}

output "aws_deploy_commands" {
  description = "Comandos para build y push de imagenes a ECR"
  value = <<-EOT
    # 1. Autenticar Docker con ECR
    aws ecr get-login-password --region ${var.aws_region} | \
      docker login --username AWS --password-stdin ${aws_ecr_repository.service_a.repository_url}

    # 2. Build y push service-a
    docker build -t ${aws_ecr_repository.service_a.repository_url}:latest ./services/service-a
    docker push ${aws_ecr_repository.service_a.repository_url}:latest

    # 3. Build y push service-b
    docker build -t ${aws_ecr_repository.service_b.repository_url}:latest ./services/service-b
    docker push ${aws_ecr_repository.service_b.repository_url}:latest

    # 4. Forzar nuevo despliegue en ECS
    aws ecs update-service --cluster ${aws_ecs_cluster.otel.name} \
      --service ${aws_ecs_service.service_b.name} --force-new-deployment
  EOT
}
