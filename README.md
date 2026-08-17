# OTel Lab — Pipeline OpenTelemetry End-to-End

[![OTel](https://img.shields.io/badge/OpenTelemetry-1.27-blueviolet)](https://opentelemetry.io/)
[![Python](https://img.shields.io/badge/Python-3.12-blue)](https://python.org)
[![Jaeger](https://img.shields.io/badge/Jaeger-1.60-brightgreen)](https://jaegertracing.io)
[![Grafana](https://img.shields.io/badge/Grafana-11.2-orange)](https://grafana.com)

Pipeline de observabilidad end-to-end con OpenTelemetry capturando los **tres pilares** (metricas, logs, trazas) desde microservicios desplegados en **GCP GKE** y **AWS ECS Fargate**.

## Arquitectura

```
Cliente / k6
    │
    ▼ HTTP
┌─────────────┐     HTTP + W3C TraceContext     ┌─────────────┐
│  service-a  │ ──────────────────────────────► │  service-b  │
│  :8000      │                                  │  :8001      │
│  FastAPI    │                                  │  FastAPI    │
│  OTel SDK   │                                  │  OTel SDK   │
└──────┬──────┘                                  └──────┬──────┘
       │                                                │
       └──────────────────┬─────────────────────────────┘
                          │ OTLP gRPC (:4317)
                 ┌────────▼────────┐
                 │  OTel Collector │
                 │  contrib:0.108  │
                 └────────┬────────┘
          ┌───────────────┼──────────────────┐
          ▼               ▼                  ▼
       Jaeger         Prometheus      Cloud Logging /
      (trazas)        (metricas)      CloudWatch (logs)
          │               │
     ┌────▼────┐    ┌──────▼──────┐
     │Jaeger UI│    │   Grafana   │
     │ :16686  │    │   :3000     │
     └─────────┘    └─────────────┘
```

## Stack tecnologico

| Componente | Tecnologia |
|---|---|
| Lenguaje | Python 3.12 + FastAPI |
| Instrumentacion | OpenTelemetry SDK 1.27 |
| Collector | OTel Collector Contrib 0.108 |
| Trazas | Jaeger 1.60 |
| Metricas | Prometheus 2.54 + Grafana 11.2 |
| DB | PostgreSQL 16 |
| IaC | Terraform 1.6+ |
| K8s | Helm 3 |
| Benchmark | k6 |
| GCP | GKE + Cloud SQL + Cloud Logging |
| AWS | ECS Fargate + RDS + CloudWatch |

---

## Inicio rapido (Local con Docker Compose)

### Prerequisitos

- Docker Desktop instalado y corriendo
- Docker Compose v2
- k6 (para benchmark): https://k6.io/docs/get-started/installation/

### 1. Levantar el stack

```bash
# Clonar el repositorio
git clone <repo-url>
cd otel-lab

# Levantar todos los servicios
docker compose up -d --build

# Verificar que todo este corriendo
docker compose ps
```

### 2. Verificar servicios

| Servicio | URL | Credenciales |
|---|---|---|
| Service A (API) | http://localhost:8000/docs | — |
| Service B (API) | http://localhost:8001/docs | — |
| Jaeger UI | http://localhost:16686 | — |
| Prometheus | http://localhost:9090 | — |
| Grafana | http://localhost:3000 | admin / admin |

### 3. Generar trazas

```bash
# Enviar requests al endpoint principal (genera trazas end-to-end)
for i in {1..20}; do
  curl -s http://localhost:8000/process/$((RANDOM % 10 + 1)) | python -m json.tool
done
```

### 4. Ver trazas en Jaeger

Ir a http://localhost:16686 → Seleccionar `service-a` → **Find Traces**

Cada traza debe mostrar:
- `service-a` → `validate_item_request`
- `service-a` → `call_service_b` → `service-b` (propagacion W3C)
- `service-b` → `check_item_cache` → `fetch_item_from_db` → `enrich_item_data`
- `service-a` → `enrich_order_data` → `persist_order`

### 5. Ver metricas en Grafana

Ir a http://localhost:3000 → Dashboards → **OTel Lab** → **OTel Lab — SLIs & Observabilidad**

Paneles disponibles:
1. 📊 Request Rate (req/s) por servicio
2. 🚨 Error Rate (%) — SLO: < 1%
3. ⏱️ Latencia p50/p95/p99 — SLO: p99 < 500ms
4. 🔄 Active Requests (saturacion)
5. 🗄️ CPU/RAM del OTel Collector
6. ⚠️ Errores y drops del Collector

### 6. Correlacion logs ↔ trazas

En Grafana → Explore → Datasource: Jaeger → Buscar una traza → Click en **Logs for this span** para ver los logs correlacionados por `trace_id`.

---

## Benchmark de Overhead

### Configuracion

```bash
# 1. Instalar k6
# Windows: winget install k6 --source winget
# Mac: brew install k6
# Linux: https://k6.io/docs/get-started/installation/

# 2. Asegurarse que el stack este corriendo
docker compose ps
```

### Ejecutar benchmark CON OTel (instrumented)

```bash
# Stack normal con OTel habilitado
docker compose up -d --build

# Esperar 30s para que los servicios esten listos
sleep 30

# Ejecutar benchmark instrumented
k6 run benchmark/k6-instrumented.js

# Resultados guardados en: benchmark/results/instrumented-results.json
```

### Ejecutar benchmark SIN OTel (baseline)

```bash
# Deshabilitar OTel en los servicios
docker compose stop service-a service-b
OTEL_SDK_DISABLED=true docker compose up -d service-a service-b

# Esperar 15s
sleep 15

# Ejecutar benchmark baseline
k6 run benchmark/k6-baseline.js

# Resultados guardados en: benchmark/results/baseline-results.json
```

### Tabla comparativa (rellenar con resultados reales)

| Metrica | Sin OTel (baseline) | Con OTel | Overhead |
|---|---|---|---|
| Latencia p50 (ms) | — | — | — |
| Latencia p95 (ms) | — | — | — |
| Latencia p99 (ms) | — | — | — |
| CPU promedio (%) | — | — | — |
| Memoria (MB) | — | — | — |
| Error rate (%) | — | — | — |

---

## Despliegue en GCP (GKE)

### Prerequisitos

```bash
# Instalar herramientas
gcloud auth login
gcloud config set project TU_PROJECT_ID
terraform --version  # >= 1.6
helm version         # >= 3.14
```

### 1. Terraform

```bash
cd infrastructure/gcp

# Configurar variables
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con project_id, db_password, etc.

# Inicializar y aplicar
terraform init
terraform plan
terraform apply

# Ver outputs (incluye comandos de kubectl y helm)
terraform output
```

### 2. Build y push de imagenes

```bash
# El output de Terraform incluye los comandos exactos
terraform output helm_deploy_commands
```

### 3. Deploy con Helm

```bash
# Obtener credenciales de GKE
gcloud container clusters get-credentials <cluster-name> --region us-central1

# Instalar OTel stack (Collector + Jaeger + Prometheus + Grafana)
helm dependency update ./helm/otel-stack
helm upgrade --install otel-stack ./helm/otel-stack \
  -n observability --create-namespace \
  --set collector.env.GCP_PROJECT_ID=TU_PROJECT_ID

# Instalar servicios
kubectl create secret generic service-b-db-secret \
  -n services --create-namespace \
  --from-literal=DATABASE_URL="postgresql://..."

kubectl create secret generic service-a-db-secret \
  -n services \
  --from-literal=DATABASE_URL="postgresql://..."

helm upgrade --install service-b ./helm/service-b \
  -n services \
  --set image.repository=us-central1-docker.pkg.dev/TU_PROJECT/otel-lab/service-b

helm upgrade --install service-a ./helm/service-a \
  -n services \
  --set image.repository=us-central1-docker.pkg.dev/TU_PROJECT/otel-lab/service-a
```

---

## Despliegue en AWS (ECS Fargate)

```bash
cd infrastructure/aws

terraform init
terraform apply \
  -var="db_password=TuPasswordSegura" \
  -var="aws_region=us-east-1"

# Ver comandos de build/push
terraform output aws_deploy_commands
```

---

## Estructura del Repositorio

```
otel-lab/
├── services/
│   ├── service-a/          # Microservicio A: orquestador de ordenes
│   │   ├── main.py         # FastAPI + OTel auto + custom instrumentation
│   │   ├── database.py     # SQLAlchemy + PostgreSQL
│   │   ├── otel_setup.py   # Configuracion SDK OTel (3 pilares)
│   │   ├── requirements.txt
│   │   └── Dockerfile
│   └── service-b/          # Microservicio B: catalogo de items
│       ├── main.py
│       ├── database.py
│       ├── otel_setup.py
│       ├── requirements.txt
│       └── Dockerfile
├── otel-collector/
│   ├── config-local.yaml   # Para Docker Compose (debug exporter)
│   ├── config-gcp.yaml     # Para GKE (googlecloud exporter)
│   └── config-aws.yaml     # Para ECS (awsxray + cloudwatch exporters)
├── infrastructure/
│   ├── gcp/                # Terraform GCP (GKE + Cloud SQL + Artifact Registry)
│   └── aws/                # Terraform AWS (ECS + RDS + ECR)
├── helm/
│   ├── service-a/          # Helm chart para GKE
│   ├── service-b/          # Helm chart para GKE
│   └── otel-stack/         # Collector + Jaeger + Prometheus + Grafana
├── grafana/
│   ├── prometheus.yml      # Config de Prometheus
│   ├── provisioning/       # Auto-provisioning de datasources y dashboards
│   └── dashboards/
│       └── sli-dashboard.json  # Dashboard con 6 paneles SLI
├── benchmark/
│   ├── k6-instrumented.js  # Benchmark CON OTel
│   ├── k6-baseline.js      # Benchmark SIN OTel (linea base)
│   └── results/            # JSONs con resultados (generados al correr k6)
├── docker-compose.yml      # Stack local completo
└── README.md
```

---

## Propagacion de Contexto W3C TraceContext

El flujo de propagacion es automatico via `opentelemetry-instrumentation-httpx`:

```
service-a → HTTP Request → service-b
Headers inyectados automaticamente:
  traceparent: 00-{trace_id}-{span_id}-01
  tracestate: (vacio en este caso)
```

Verificar en Jaeger: una traza de `service-a` debe mostrar spans de `service-b` **anidados** bajo el mismo `trace_id`.

---

## Verificacion de los Tres Pilares

### Trazas
```bash
# Ver en Jaeger UI: http://localhost:16686
# Buscar: Service = service-a, Operation = GET /process/{item_id}
```

### Metricas
```bash
# Ver en Prometheus: http://localhost:9090
# Query: http_server_request_duration_milliseconds_count{job="otel-services"}
```

### Logs
```bash
# Ver logs con trace_id inyectado
docker compose logs service-a | python -m json.tool | grep trace_id
```

---

## Licencia

MIT — Proyecto academico para Lab de Observabilidad con OpenTelemetry.
