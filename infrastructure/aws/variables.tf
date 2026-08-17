variable "aws_region" {
  description = "Region de AWS"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Nombre del entorno"
  type        = string
  default     = "production"
}

variable "db_password" {
  description = "Contrasena de RDS PostgreSQL"
  type        = string
  sensitive   = true
}

variable "db_username" {
  description = "Usuario de RDS PostgreSQL"
  type        = string
  default     = "postgres"
}

variable "ecs_task_cpu" {
  description = "CPU para tareas ECS Fargate (units: 256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 512
}

variable "ecs_task_memory" {
  description = "Memoria para tareas ECS Fargate (MB)"
  type        = number
  default     = 1024
}

variable "service_a_image" {
  description = "URL de imagen Docker para service-a (ECR)"
  type        = string
  default     = ""
}

variable "service_b_image" {
  description = "URL de imagen Docker para service-b (ECR)"
  type        = string
  default     = ""
}
