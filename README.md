# 🌐 Pipeline de Observabilidad End-to-End con OpenTelemetry en Google Cloud Platform (GCP)

[![OpenTelemetry](https://img.shields.io/badge/OpenTelemetry-1.27.0-blueviolet?logo=opentelemetry)](https://opentelemetry.io/)
[![Google Cloud](https://img.shields.io/badge/GCP-GKE%20%2B%20Cloud%20SQL-4285F4?logo=googlecloud)](https://cloud.google.com/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.35.6-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.115-009688?logo=fastapi)](https://fastapi.tiangolo.com/)
[![Jaeger](https://img.shields.io/badge/Jaeger-v1.60-brightgreen?logo=jaeger)](https://jaegertracing.io/)
[![Prometheus](https://img.shields.io/badge/Prometheus-v2.54-E6522C?logo=prometheus)](https://prometheus.io/)
[![Grafana](https://img.shields.io/badge/Grafana-v11.2-F46800?logo=grafana)](https://grafana.com/)
[![Istio](https://img.shields.io/badge/Istio-1.23-466BB0?logo=istio)](https://istio.io/)
[![Guía Despliegue & IA](https://img.shields.io/badge/Gu%C3%ADa%20Despliegue-IA%20Prompts-success?logo=openai)](docs/GUIA_COLABORACION_IA.md)
[![Autoevaluación Blueprint](https://img.shields.io/badge/Blueprint%20Madurez-Nivel%204.16-blue?logo=googlecloud)](docs/AUTOEVALUACION_OBSERVABILITY_BLUEPRINT.md)
[![Roadmap 3 Meses](https://img.shields.io/badge/Roadmap-3%20Meses%20Nivel%204.8-blueviolet?logo=target)](docs/ROADMAP_MEJORA_OBSERVABILIDAD_3_MESES.md)
[![Informe Técnico](https://img.shields.io/badge/Informe%20T%C3%A9cnico-PDF-red?logo=adobeacrobatreader)](docs/INFORME_TECNICO.pdf)

---

## 📌 Resumen Ejecutivo del Proyecto

Este repositorio contiene la arquitectura, implementación y documentación técnica del **Pipeline de Observabilidad End-to-End basado en OpenTelemetry (OTel)**, desplegado en **Google Cloud Platform (GCP)** sobre un clúster regional de **Google Kubernetes Engine (GKE)** y **Cloud SQL PostgreSQL 16**.

La solución integra de forma unificada los **tres pilares de la observabilidad** (Trazas, Métricas y Logs estructurados) junto con observabilidad de red L7 mediante **Istio Service Mesh**, detección inteligente de anomalías (**AIOps**), observabilidad de red y seguridad (**VPC Flow Logs & Security Golden Signals**) y resiliencia comprobada mediante **Chaos Engineering**.

---

## 🌐 1. Estado y Puntos de Acceso en Producción (GCP Activo)

* **Cuenta Propietaria GCP:** `pabloandresmelo1981@gmail.com`
* **GCP Project ID:** `project-546ee9f1-20e7-4368-919` (`us-central1`)
* **Clúster GKE:** `dev-otel-cluster` (Regional, 6 nodos `e2-standard-2`, todos los pods en estado `1/1 Running`).
* **Base de Datos:** Cloud SQL PostgreSQL 16 `dev-otel-postgres` (`10.40.0.2:5432/labdb`).

### 🔗 Matriz de Endpoints Públicos y Servicios

| Componente | Tipo | URL Pública / Endpoint | Puerto | Función |
|---|:---:|---|:---:|---|
| **Service A (Gateway)** | `LoadBalancer` | **[http://35.193.118.242:8000/docs](http://35.193.118.242:8000/docs)** | `8000/TCP` | Swagger UI interactivo / API de Órdenes |
| **Grafana Server** | `LoadBalancer` | **[http://35.253.127.244](http://35.253.127.244)** *(admin / admin)* | `80/TCP` | Dashboards RED y SLIs en vivo |
| **Jaeger UI** | `LoadBalancer` | **[http://34.134.141.14:16686](http://34.134.141.14:16686)** | `16686/TCP` | Visualización de trazas y cascada distribuida |
| **Service B (Catálogo)** | `ClusterIP` | `10.52.15.158` (Red Privada) | `8001/TCP` | Catálogo de inventario |
| **Data Service** | `ClusterIP` | `10.52.13.115` (Red Privada) | `8080/TCP` | Acceso a PostgreSQL (Cloud SQL) |
| **OTel Collector** | `ClusterIP` | `10.52.12.109` (Red Privada) | `4317/4318` | Gateway centralizado de telemetría OTLP |
| **Prometheus Server** | `ClusterIP` | `10.52.1.97` (Red Privada) | `80/TCP` | Recolección de métricas de pods y nodos |

---

## 🏛️ 2. Arquitectura General y Topología

```text
                               ┌─────────────────────────────────────────┐
                               │               Cliente / k6              │
                               └────────────────────┬────────────────────┘
                                                    │ HTTP Requests
                                                    ▼
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ Google Kubernetes Engine (GKE Cluster: dev-otel-cluster | Project: project-546ee9f1-20e7-4368-919)                 │
│                                                                                                                  │
│  ┌─ Namespace: services (con Istio Sidecar Envoy & mTLS STRICT) ──────────────────────────────────────────────┐  │
│  │                                                                                                            │  │
│  │   ┌───────────────────────────┐    HTTP + W3C TraceContext    ┌───────────────────────────┐                │  │
│  │   │  service-a (FastAPI)      │ ────────────────────────────► │  service-b (FastAPI)      │                │  │
│  │   │  IP: 35.193.118.242:8000  │                               │  ClusterIP: 10.52.15.158  │                │  │
│  │   └─────────────┬─────────────┘                               └─────────────┬─────────────┘                │  │
│  │                 │                                                           │                              │  │
│  │                 │               ┌───────────────────────────┐               │                              │  │
│  │                 └─────────────► │  data-service (FastAPI)   │ ◄─────────────┘                              │  │
│  │                                 │  ClusterIP: 10.52.13.115  │                                              │  │
│  │                                 └─────────────┬─────────────┘                                              │  │
│  └───────────────────────────────────────────────┼────────────────────────────────────────────────────────────┘  │
│                                                  │                                                               │
│                                                  │ OTLP gRPC (:4317)                                             │
│                                                  ▼                                                               │
│  ┌─ Namespace: observability ─────────────────────────────────────────────────────────────────────────────────┐  │
│  │                                  ┌───────────────────────────────────┐                                     │  │
│  │                                  │  OpenTelemetry Collector Gateway  │                                     │  │
│  │                                  │  ClusterIP: 10.52.12.109          │                                     │  │
│  │                                  └─────────────────┬─────────────────┘                                     │  │
│  │                                                    │                                                       │  │
│  │                     ┌──────────────────────────────┼──────────────────────────────┐                        │  │
│  │                     ▼ (Trazas)                     ▼ (Métricas)                   ▼ (Logs)                 │  │
│  │           ┌───────────────────┐          ┌───────────────────┐          ┌───────────────────┐              │  │
│  │           │  Jaeger Engine    │          │  Prometheus       │          │  Cloud Logging    │              │  │
│  │           │  34.134.141.14    │          │  Server           │          │  (JSON estruct.)  │              │  │
│  │           └─────────┬─────────┘          └─────────┬─────────┘          └───────────────────┘              │  │
│  │                     │                              │                                                       │  │
│  │                     │                              ▼                                                       │  │
│  │                     │                    ┌───────────────────┐                                             │  │
│  │                     │                    │  Grafana Server   │                                             │  │
│  │                     │                    │  35.253.127.244   │                                             │  │
│  │                     │                    └─────────┬─────────┘                                             │  │
│  │                     └──────────────────────────────┘                                                       │  │
│  └────────────────────────────────────────────────────────────────────────────────────────────────────────────┘  │
│                                                  │                                                               │
│  ┌─ Managed Cloud SQL (GCP) ─────────────────────┼────────────────────────────────────────────────────────────┐  │
│  │   PostgreSQL 16: dev-otel-postgres | Private IP: 10.40.0.2:5432/labdb | OTel DB Semantic Conventions       │  │
│  └────────────────────────────────────────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📦 3. Desglose de Cumplimiento de los 4 Módulos

### 🅰️ Módulo A — Arquitectura Observable Completa
* **Microservicios:** `service-a` (orquestación), `service-b` (catálogo) y `data-service` (persistencia) en FastAPI.
* **3 Pilares OTel:**
  - **Trazas:** `TracerProvider` con `BatchSpanProcessor` exportando por OTLP gRPC hacia Jaeger.
  - **Métricas:** `MeterProvider` exportando a Prometheus con métricas RED de latencia, tasa de peticiones y errores.
  - **Logs:** JSON estructurado inyectando `trace_id` y `span_id` bajo el estándar **W3C TraceContext** (`traceparent`).
* **OTel DB Semantic Conventions:** Auto-instrumentación con `AsyncPGInstrumentor` y enriquecimiento manual con `db_span()` (`db.system=postgresql`, `db.operation`, `db.sql.table`, `server.address`, `db.statement`).
* **Service Mesh (Istio):** Desplegado con sidecars Envoy (`istio-proxy`), cifrado **mTLS STRICT** en namespace `services` y telemetría de red L7.

---

### 🅱️ Módulo B — AIOps: Detección Automática de Anomalías
* **Motor de Anomalías (`services/data-service/src/anomaly_detector.py`):**
  - Mantiene una ventana deslizante de 60 segundos sobre tráfico real, calculando en tiempo real la media ($\mu$) y desviación estándar ($\sigma$).
* **Regla de Correlación Multi-Señal:**
  $$\text{Alerta Activa} \iff (\text{error\_rate} > \mu_{\text{error}} + 2\sigma) \ \land \ (\text{latency\_p99} > \text{SLO\_threshold})$$
* **Alertas Enriquecidas:** Cada incidente emite un objeto `EnrichedAlert` que inyecta automáticamente el `trace_id` del request fallido, ruta afectada y URL directa hacia Jaeger (`jaeger_url: http://34.134.141.14:16686/trace/{trace_id}`).
* **Supresión de Ruido Comprobada:** Reduce el 100% de falsos positivos frente a sistemas con umbrales estáticos ante fluctuaciones transitorias.

---

### 🛡️ Módulo C — Network and Security Observability
* **VPC Flow Logs:** Habilitados en la subred GKE con métricas basadas en logs en Cloud Logging para monitoreo de flujos este-oeste (E-W) y norte-sur (N-S) ([`infrastructure/gcp-modulo-c/network-security.tf`](infrastructure/gcp-modulo-c/network-security.tf)).
* **Security Command Center (GCP):** Monitoreo de configuraciones vulnerables y permisos IAM ([`infrastructure/gcp-modulo-c/security-command-center.tf`](infrastructure/gcp-modulo-c/security-command-center.tf)).
* **Dashboard de Golden Signals de Seguridad:** Paneles que vigilan autenticaciones fallidas, conexiones denegadas por firewall y métricas de CVEs provistas por [`services/cve-exporter/`](services/cve-exporter/).

---

### 🌪️ Módulo D — Chaos Engineering Controlado en Sandbox
* **Aislamiento Estricto:** Ejecutado exclusivamente en sandbox dedicado ([`chaos/`](chaos/)) con flag de protección `CHAOS_CONTROL_ENABLED` y guardias de contexto para no afectar producción.
* **Experimentos Ejecutados:**
  1. **D1:** Inyección de 200ms de latencia en `service-b` mediante Istio VirtualService (`fault.delay`).
  2. **D2:** Inyección de 10% de errores HTTP 500 en `data-service` mediante el `ChaosEngine` oficial.
* **Resultados y MTTD:**
  - **MTTD Verificado:** **77.37 segundos** (cumple el objetivo $< 2\text{ minutos}$).
  - **Degradación de SLO:** Error rate interno de 9.82% en `data-service`, mientras que la política de reintentos de Istio mitigó el impacto al cliente final a 0.095%.
  - **Error Budget:** Tasa de quema (*Burn Rate*) acelerada a 19.64x durante la ventana de caos.
  - **Accionabilidad:** Alerta con severidad crítica, `trace_id` y enlace al runbook de mitigación ([`docs/runbooks/d2-data-service-errors.md`](docs/runbooks/d2-data-service-errors.md)).

---

## 📈 4. Autoevaluación contra el Blueprint y Roadmap a 3 Meses

| Documento | Enlace | Contenido Principal |
|---|---|---|
| **Autoevaluación Blueprint (8 Dominios)** | [`docs/AUTOEVALUACION_OBSERVABILITY_BLUEPRINT.md`](docs/AUTOEVALUACION_OBSERVABILITY_BLUEPRINT.md) | Calificación de **4.16 / 5.0 (Nivel 4: Cuantitativamente Gestionado)** detallando fortalezas y gaps en los 8 dominios. |
| **Roadmap de Mejora a 3 Meses** | [`docs/ROADMAP_MEJORA_OBSERVABILIDAD_3_MESES.md`](docs/ROADMAP_MEJORA_OBSERVABILIDAD_3_MESES.md) | Plan de trabajo por sprints a 90 días para alcanzar el **Nivel 5 (4.76 / 5.0)** (Prometheus Exemplars, Kiali, Continuous Profiling eBPF y Canary Deployments verificados por SLO). |
| **Guía de Despliegue y Prompts para IA** | [`docs/GUIA_COLABORACION_IA.md`](docs/GUIA_COLABORACION_IA.md) | Secuencia paso a paso de despliegue desde cero en GCP y prompts listos para copiar y pegar. |

---

## 📂 5. Estructura Completa del Repositorio

```text
otel-lab/
├── services/                                 # Código fuente de microservicios
│   ├── service-a/                            # API Gateway / Orquestador (FastAPI + OTel SDK)
│   ├── service-b/                            # Catálogo de Inventario (FastAPI + OTel SDK)
│   ├── data-service/                         # Acceso a datos PostgreSQL + AIOps + Chaos Engine
│   └── cve-exporter/                         # Exportador de métricas de seguridad y CVEs
│
├── infrastructure/                           # Infraestructura como Código (IaC) con Terraform
│   ├── gcp/                                  # VPC, GKE Regional, Cloud SQL y Artifact Registry
│   └── gcp-modulo-c/                         # VPC Flow Logs, Security Command Center y Dashboards
│
├── helm/                                     # Charts de orquestación Kubernetes
│   ├── otel-stack/                           # OTel Collector, Jaeger, Prometheus y Grafana
│   ├── service-a/                            # Despliegue de Service A
│   ├── service-b/                            # Despliegue de Service B
│   └── data-service/                         # Despliegue de Data Service (+ simulador RDS)
│
├── mesh/                                     # Service Mesh (Istio) — Observabilidad de Red L7
│   ├── istio-operator.yaml                   # Control plane Istio con exportador OTLP
│   ├── peer-authentication.yaml              # Cifrado mTLS STRICT mesh-wide
│   └── telemetry.yaml                        # Muestreo de trazas L7 y access logging Envoy
│
├── chaos/                                    # Suite formal de Chaos Engineering en Sandbox
│   ├── experiments/                          # Experimentos D1 (latencia) y D2 (errores 500)
│   ├── load/                                 # Scripts de prueba de carga con k6
│   ├── analysis/                             # Scripts de cálculo de SLO y quema de Error Budget
│   └── observability/                        # Reglas de alerta de Prometheus para degradación
│
├── docs/                                     # Documentación formal y entregables
│   ├── AUTOEVALUACION_OBSERVABILITY_BLUEPRINT.md # Autoevaluación 8 dominios (Escala 1-5)
│   ├── ROADMAP_MEJORA_OBSERVABILIDAD_3_MESES.md  # Plan de evolución a 90 días (Hacia Nivel 5)
│   ├── GUIA_COLABORACION_IA.md               # Guía paso a paso y prompts para IA
│   ├── INFORME_TECNICO.pdf                   # Informe técnico formal del proyecto (PDF)
│   ├── runbooks/                             # Procedimientos operativos de mitigación
│   └── evidencias/                           # Registros formales de corridas de caos
│
├── grafana/                                  # Dashboards declarativos JSON y configuración
├── benchmark/                                # Scripts comparativos de overhead con k6
└── README.md                                 # Documentación principal consolidada
```

---

## 🧪 6. Validación de Transacción en Vivo

Prueba ejecutada contra la IP pública del balanceador de carga en GCP:

```powershell
curl http://35.193.118.242:8000/process/1
```

**Respuesta HTTP 200 con `trace_id` correlacionado:**
```json
{
  "order_id": 2,
  "item": {
    "id": 1,
    "name": "Producto-01",
    "description": "Articulo de demostracion numero 1",
    "price": 9.99,
    "availability": "low_stock",
    "stock_quantity": 4,
    "enriched": true,
    "cache_hit": true,
    "total_with_tax": 11.89
  },
  "status": "completed",
  "processing_time_ms": 429.14,
  "trace_id": "81edaabede3a4f8e6c4f63f362fe01a1"
}
```
*(Puedes inspeccionar esta traza en vivo en Jaeger UI: `http://34.134.141.14:16686/trace/81edaabede3a4f8e6c4f63f362fe01a1`).*
