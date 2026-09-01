# 🤖 Guía de Colaboración con IA — Pipeline de Observabilidad OTel Lab

Esta guía contiene las instrucciones, flujos de trabajo y **prompts exactos** para que cualquier miembro del equipo pueda interactuar con el asistente de IA para actualizar la infraestructura en Google Cloud Platform (GCP) o publicar nuevos componentes sin romper la arquitectura establecida.

---

## 📋 1. Requisitos Previos del Entorno

Antes de solicitar cambios a la IA, el desarrollador debe asegurarse de:

1. **Estar autenticado en Google Cloud:**
   ```powershell
   gcloud auth login
   gcloud config set project project-546ee9f1-20e7-4368-919
   gcloud auth application-default login
   ```
2. **Obtener las credenciales del clúster GKE:**
   ```powershell
   gcloud container clusters get-credentials dev-otel-cluster --region us-central1 --project project-546ee9f1-20e7-4368-919
   ```

---

## 🎯 2. Prompts Listos para Usar con la IA

### 🅰️ Escenario: Modificar o Actualizar la Infraestructura (Terraform)
> **Prompt para la IA:**
> ```text
> "Necesito actualizar la infraestructura en GCP con Terraform. Por favor:
> 1. Modifica los archivos en infrastructure/gcp/ para [ESCRIBE TU CAMBIO AQUÍ, ej: aumentar el node pool de GKE a e2-standard-4 / agregar una nueva base de datos en Cloud SQL].
> 2. Ejecuta `terraform plan` para validar los cambios.
> 3. Si no hay errores destructivos, aplica con `terraform apply -auto-approve` y actualiza la documentación."
> ```

---

### 🅱️ Escenario: Publicar o Actualizar un Microservicio Existente
> **Prompt para la IA:**
> ```text
> "He realizado cambios en el código de [service-a / service-b / data-service]. Por favor:
> 1. Compila y sube la nueva imagen a Artifact Registry usando Cloud Build:
>    `gcloud builds submit --tag us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/<NOMBRE_SERVICIO>:latest ./services/<NOMBRE_SERVICIO>`
> 2. Actualiza el despliegue en Kubernetes ejecutando:
>    `helm upgrade --install <NOMBRE_SERVICIO> ./helm/<NOMBRE_SERVICIO> -n services`
> 3. Verifica que los pods queden en estado Running con `kubectl get pods -n services`."
> ```

---

### 🅲 Escenario: Crear un Nuevo Microservicio en el Ecosistema
> **Prompt para la IA:**
> ```text
> "Quiero crear un nuevo microservicio llamado '<nuevo-servicio>' en FastAPI. Por favor:
> 1. Crea la carpeta en services/<nuevo-servicio>/ con su Dockerfile, requirements.txt y main.py.
> 2. Instrumenta completamente los 3 pilares de OpenTelemetry (Trazas OTLP gRPC hacia otel-collector:4317, Métricas con MeterProvider, y Logs estructurados en JSON con correlación W3C trace_id/span_id).
> 3. Si usa base de datos, aplica OpenTelemetry DB Semantic Conventions.
> 4. Crea su Chart de Helm en helm/<nuevo-servicio>/ respetando el namespace 'services'.
> 5. Si aplica Service Mesh, añade las anotaciones de Istio para observabilidad de red L7.
> 6. Compila la imagen, súbela a Artifact Registry y haz el despliegue con Helm."
> ```

---

### 🅳 Escenario: Modificar Dashboards de Grafana o Métricas de Prometheus
> **Prompt para la IA:**
> ```text
> "Necesito agregar una nueva métrica RED / panel en Grafana para [ESCRIBE TU MÉTRICA AQUÍ, ej: tasa de error 5xx de data-service]. Por favor:
> 1. Modifica la configuración en grafana/dashboards/sli-dashboard.json.
> 2. Actualiza el ConfigMap/Chart de Helm en helm/otel-stack/.
> 3. Aplica la actualización con `helm upgrade --install otel-stack ./helm/otel-stack -n observability`.
> 4. Verifica el estado en el servicio de Grafana."
> ```

---

### 🅴 Escenario: Ejecutar Pruebas de Carga y Benchmark (k6)
> **Prompt para la IA:**
> ```text
> "Necesito ejecutar una prueba de carga comparativa con k6 (Baseline vs Instrumented). Por favor:
> 1. Obtén la IP pública actual del LoadBalancer de service-a (`kubectl get svc service-a -n services`).
> 2. Ejecuta el benchmark usando el script benchmark/run-benchmark.sh apuntando a dicha IP.
> 3. Compara throughput (RPS), latencias (p50, p90, p95, p99) y tasa de error.
> 4. Genera la tabla comparativa de overhead para el informe."
> ```

---

## 🛡️ 3. Reglas de Oro del Proyecto (Architecture & Design Principles)

Al pedirle modificaciones a la IA, recuérdale siempre respetar estos principios:

| Aspecto | Regla Obligatoria |
|---|---|
| **Estructura** | Microservicios en `services/`, Manifiestos Helm en `helm/`, Infraestructura en `infrastructure/gcp/`. |
| **Namespaces** | Aplicaciones en `services`, herramientas de observabilidad en `observability`. |
| **Correlación OTel** | Todos los logs deben emitirse en formato JSON inyectando `trace_id` y `span_id` (W3C standard). |
| **Proveedores Cloud** | El despliegue de producción se realiza exclusivamente en **GCP** (GKE + Cloud SQL + Artifact Registry). |
| **Gestión de Secretos** | Credenciales de base de datos nunca en plano; usar Kubernetes Secrets o GCP Secret Manager. |
