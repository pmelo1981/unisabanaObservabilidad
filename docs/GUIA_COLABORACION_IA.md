# 🤖 Guía de Colaboración con IA y Despliegue — Pipeline de Observabilidad OTel Lab

Esta guía contiene los requisitos previos, la secuencia completa de despliegue desde cero y los **prompts exactos** (listos para copiar y pegar) para que cualquier miembro del equipo pueda interactuar con un asistente de IA y realizar tareas de:
- Despliegue completo y actualización de infraestructura en **Google Cloud Platform (GCP)** con **Terraform**.
- Compilación y publicación de imágenes de microservicios con **Google Cloud Build** hacia **Artifact Registry**.
- Despliegue y actualización de aplicaciones y observabilidad con **Helm** en **GKE**.
- Inyección de experimentos de **Chaos Engineering** y validación de resiliencia / SLOs.
- Ejecución de iniciativas del **Roadmap de Madurez del Observability Blueprint (8 Dominios)**.

---

## 📋 1. Requisitos Previos del Entorno

Antes de solicitar tareas a la IA, el desarrollador debe asegurarse de autenticarse en su terminal local:

1. **Autenticación en Google Cloud:**
   ```powershell
   gcloud auth login
   gcloud config set project project-546ee9f1-20e7-4368-919
   gcloud auth application-default login
   ```
2. **Conexión al clúster de Kubernetes (GKE):**
   ```powershell
   gcloud container clusters get-credentials dev-otel-cluster --region us-central1 --project project-546ee9f1-20e7-4368-919
   ```
3. **Verificar que `kubectl` y `helm` estén comunicándose con el clúster:**
   ```powershell
   kubectl get nodes
   helm list -A
   ```

---

## 🌐 2. Puntos de Entrada y Endpoints Activos de Producción

| Componente | Tipo | URL Pública / Endpoint | Propósito |
|---|:---:|---|---|
| **Service A (API Gateway)** | `LoadBalancer` | `http://35.193.118.242:8000/docs` | Swagger UI interactivo / Endpoints REST |
| **Grafana Server** | `LoadBalancer` | `http://35.253.127.244` *(admin/admin)* | Dashboards RED, métricas y SLIs |
| **Jaeger UI** | `LoadBalancer` | `http://34.134.141.14:16686` | Trazas distribuidas end-to-end |
| **Cloud SQL PostgreSQL** | `Private IP` | `10.40.0.2:5432/labdb` | Base de datos relacional de catálogo y órdenes |

---

## 🚀 3. Flujo Paso a Paso de Despliegue desde Cero (GCP End-to-End)

Si se desea replicar o desplegar la arquitectura completa en un nuevo proyecto de GCP:

```text
[1. Terraform IaC] ──► [2. Cloud Build] ──► [3. Secrets & Mesh] ──► [4. Helm Releases] ──► [5. Validación]
 VPC, GKE, SQL          Imágenes Docker      mTLS & Namespaces       Stack & Services        Traces & Metrics
```

1. **Paso 1: Infraestructura Base con Terraform**
   ```powershell
   cd infrastructure/gcp
   terraform init
   terraform apply -auto-approve
   cd ../..
   ```
2. **Paso 2: Conectar `kubectl` al nuevo clúster**
   ```powershell
   gcloud container clusters get-credentials dev-otel-cluster --region us-central1 --project project-546ee9f1-20e7-4368-919
   ```
3. **Paso 3: Compilar y Subir Imágenes con Cloud Build**
   ```powershell
   gcloud builds submit --tag us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/service-a:latest ./services/service-a
   gcloud builds submit --tag us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/service-b:latest ./services/service-b
   gcloud builds submit --tag us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/data-service:latest ./services/data-service
   ```
4. **Paso 4: Crear Namespaces y Secretos de Kubernetes**
   ```powershell
   kubectl create namespace services --dry-run=client -o yaml | kubectl apply -f -
   kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

   kubectl create secret generic service-a-db-secret -n services --from-literal=database-url="postgresql://postgres:OtelLab2024!@10.40.0.2:5432/labdb" --dry-run=client -o yaml | kubectl apply -f -
   kubectl create secret generic service-b-db-secret -n services --from-literal=database-url="postgresql://postgres:OtelLab2024!@10.40.0.2:5432/labdb" --dry-run=client -o yaml | kubectl apply -f -
   kubectl create secret generic data-service-db-credentials -n services --from-literal=cloud_sql_dsn="postgresql://postgres:OtelLab2024!@10.40.0.2:5432/labdb" --from-literal=aws_rds_dsn="postgresql://postgres:OtelLab2024!@rds-sim.services.svc.cluster.local:5432/rds_sim_db" --dry-run=client -o yaml | kubectl apply -f -
   ```
5. **Paso 5: Desplegar Observabilidad y Microservicios con Helm**
   ```powershell
   helm upgrade --install otel-stack ./helm/otel-stack -n observability
   helm upgrade --install service-a ./helm/service-a -n services --set image.repository=us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/service-a --set image.tag=latest
   helm upgrade --install service-b ./helm/service-b -n services --set image.repository=us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/service-b --set image.tag=latest
   helm upgrade --install data-service ./helm/data-service -n services --set image.repository=us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/data-service --set image.tag=latest --set db.cloudSqlDsn="postgresql://postgres:OtelLab2024!@10.40.0.2:5432/labdb"
   ```

---

## 🎯 4. Prompts Listos para Usar con la IA

### 🅰️ Escenario: Modificar o Actualizar la Infraestructura (Terraform)
> **Prompt para la IA:**
> ```text
> "Necesito actualizar la infraestructura en GCP con Terraform. Por favor:
> 1. Modifica los archivos en infrastructure/gcp/ para [ESCRIBE TU CAMBIO AQUÍ, ej: aumentar el node pool de GKE a e2-standard-4 / agregar un nuevo bucket de storage / modificar parámetros de Cloud SQL].
> 2. Ejecuta `terraform plan` dentro de infrastructure/gcp/ para validar los cambios.
> 3. Si no hay errores destructivos, aplica con `terraform apply -auto-approve` y actualiza la documentación."
> ```

---

### 🅱️ Escenario: Compilar y Desplegar Cambios en un Microservicio Existente
> **Prompt para la IA:**
> ```text
> "He realizado cambios en el código de [service-a / service-b / data-service]. Por favor:
> 1. Compila y sube la nueva imagen a Artifact Registry usando Cloud Build:
>    `gcloud builds submit --tag us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/<NOMBRE_SERVICIO>:latest ./services/<NOMBRE_SERVICIO>`
> 2. Actualiza el despliegue en Kubernetes ejecutando:
>    `helm upgrade --install <NOMBRE_SERVICIO> ./helm/<NOMBRE_SERVICIO> -n services --set image.repository=us-central1-docker.pkg.dev/project-546ee9f1-20e7-4368-919/otel-lab/<NOMBRE_SERVICIO> --set image.tag=latest`
> 3. Verifica que los pods queden en estado 1/1 Running con `kubectl get pods -n services`."
> ```

---

### 🅲 Escenario: Crear un Nuevo Microservicio en el Ecosistema
> **Prompt para la IA:**
> ```text
> "Quiero crear un nuevo microservicio llamado '<nuevo-servicio>' en FastAPI. Por favor:
> 1. Crea la carpeta en services/<nuevo-servicio>/ con su Dockerfile, requirements.txt y main.py.
> 2. Instrumenta completamente los 3 pilares de OpenTelemetry (Trazas OTLP gRPC hacia otel-collector:4317, Métricas con MeterProvider, y Logs estructurados en JSON con correlación W3C trace_id/span_id).
> 3. Si usa base de datos PostgreSQL, aplica OpenTelemetry DB Semantic Conventions usando AsyncPGInstrumentor o SQLAlchemyInstrumentor.
> 4. Crea su Chart de Helm en helm/<nuevo-servicio>/ respetando el namespace 'services'.
> 5. Añade la configuración de Service Mesh (Istio sidecar injection).
> 6. Compila la imagen con Cloud Build y despliégala con Helm."
> ```

---

### 🅳 Escenario: Ejecutar Experimentos de Chaos Engineering (Módulo D)
> **Prompt para la IA:**
> ```text
> "Necesito ejecutar una prueba de Chaos Engineering en el sandbox dedicado (kind-otel-chaos) para validar resiliencia y MTTD de alertas. Por favor:
> 1. Configura el experimento [D1: inyección de 200ms de latencia en service-b / D2: 10% de errores HTTP 500 en data-service].
> 2. Inicia la carga con k6 usando los scripts en chaos/load/.
> 3. Verifica la activación de la alerta en Prometheus/Grafana y mide el tiempo de detección (MTTD objetivo < 2 min).
> 4. Ejecuta el rollback del experimento y valida que el estado vuelva a normalidad."
> ```

---

### 🅴 Escenario: Modificar Dashboards de Grafana o Reglas de Alerta
> **Prompt para la IA:**
> ```text
> "Necesito agregar una nueva métrica RED / regla de alerta en Grafana o Prometheus para [ESCRIBE TU MÉTRICA AQUÍ, ej: alerta de saturación de conexiones Cloud SQL]. Por favor:
> 1. Modifica la configuración en grafana/dashboards/ o chaos/observability/prometheus-rules.yaml.
> 2. Actualiza el Chart de Helm en helm/otel-stack/.
> 3. Aplica la actualización con `helm upgrade --install otel-stack ./helm/otel-stack -n observability`.
> 4. Verifica el estado en Grafana (http://35.253.127.244)."
> ```

---

### 🅵 Escenario: Ejecutar Pruebas de Carga y Benchmark Comparativo (k6)
> **Prompt para la IA:**
> ```text
> "Necesito ejecutar una prueba de carga comparativa con k6 (Baseline vs Instrumented). Por favor:
> 1. Ejecuta el benchmark apuntando a la IP pública de service-a: http://35.193.118.242:8000.
> 2. Compara throughput (RPS), latencias (p50, p90, p95, p99) y tasa de error.
> 3. Genera la tabla comparativa de overhead para documentar el costo de la observabilidad."
> ```

---

### 🅶 Escenario: Ejecutar Tareas del Roadmap de Madurez (Hacia Nivel 5)
> **Prompt para la IA:**
> ```text
> "Necesito implementar la siguiente iniciativa del Roadmap de Madurez de Observabilidad a 3 Meses (docs/ROADMAP_MEJORA_OBSERVABILIDAD_3_MESES.md):
> [ESCRIBE TU TAREA AQUÍ, ej: Habilitar Exemplars en Prometheus / Instalar Kiali para Service Map / Configurar Canary Rollout con Flagger].
> Por favor:
> 1. Revisa los requerimientos técnicos en docs/ROADMAP_MEJORA_OBSERVABILIDAD_3_MESES.md.
> 2. Aplica los cambios en los manifiestos de Helm o en el código fuente.
> 3. Valida el funcionamiento y actualiza la matriz de madurez en docs/AUTOEVALUACION_OBSERVABILITY_BLUEPRINT.md."
> ```

---

## 🛡️ 5. Reglas de Oro del Proyecto (Architecture & Security Guidelines)

Al solicitar cambios a la IA, asegúrate de que respete estas directrices estructurales:

| Dimensión | Regla Obligatoria |
|---|---|
| **Estructura de Carpetas** | Microservicios en `services/`, Manifiestos Helm en `helm/`, Terraform en `infrastructure/gcp/`, Pruebas de Caos en `chaos/`. |
| **Namespaces Kubernetes** | Lógica de negocio en `services`, infraestructura de observabilidad en `observability`. |
| **Correlación OTel** | Todos los logs de aplicación deben emitirse en JSON inyectando `trace_id` y `span_id` (estándar W3C TraceContext). |
| **Proveedor Cloud** | El entorno productivo se ejecuta exclusivamente en **Google Cloud Platform (GCP)** (GKE + Cloud SQL + Artifact Registry). |
| **Seguridad de Credenciales** | Ninguna contraseña o string de conexión en texto plano en Git; usar Kubernetes Secrets o GCP Secret Manager. |
| **Service Mesh** | Comunicación interna cifrada con mTLS STRICT vía Envoy sidecars de Istio. |
| **Aislamiento de Caos** | Experimentos de caos ejecutados exclusivamente en el sandbox local `kind-otel-chaos`, nunca en GKE compartido. |
