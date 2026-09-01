# 📊 Autoevaluación de la Solución contra el Observability Foundation Blueprint

> **Asignatura:** Observabilidad y Monitoreo de Sistemas Distribuidos  
> **Proyecto:** Pipeline de Observabilidad End-to-End con OpenTelemetry en Google Cloud Platform (GCP)  
> **Infraestructura Evaluada:** Clúster GKE Regional (`dev-otel-cluster`), Cloud SQL PostgreSQL 16 (`dev-otel-postgres`), Istio Service Mesh, OTel Collector, Jaeger, Prometheus y Grafana.  
> **Fecha de Evaluación:** Septiembre 2026  
> **Escala de Madurez:** 1 (Inicial) a 5 (Optimizado / Autónomo)

---

## 🎯 1. Marco Metodológico y Escala de Madurez (1 a 5)

La evaluación se basa en el **Observability Foundation Blueprint / Capability Maturity Model**:

```text
  Nivel 1           Nivel 2           Nivel 3             Nivel 4                Nivel 5
 [Inicial]   ──►  [Gestionado] ──►  [Definido]   ──►  [Cuantitativo]     ──►  [Optimizado]
Logs locales    Métricas CPU/RAM   OTel 3 Pilares      AIOps, Mesh L7         Autorremediación,
 Reactivo        Alertas ruido      SLIs/SLOs IaC     Chaos & MTTD medido     Canary continuo
```

* **Nivel 1 — Inicial / Siloed:** Monitoreo reactivo, logs aislados en stdout, sin correlación de eventos.
* **Nivel 2 — Gestionado:** Monitoreo de métricas básicas de servidor, dashboards fragmentados, alertas con alta tasa de falsos positivos.
* **Nivel 3 — Definido / Estandarizado:** Adopción del estándar OpenTelemetry (3 pilares), propagación de contexto, SLIs/SLOs formales, IaC.
* **Nivel 4 — Cuantitativamente Gestionado:** Service Mesh L7 con mTLS, detección de anomalías AIOps, reducción sistemática de ruido, Chaos Engineering controlado en sandbox con MTTD objetivo medido.
* **Nivel 5 — Optimizado / Autónomo:** Autorremediación automatizada, Canary releases verificados por SLO, Continuous Profiling eBPF y gobernanza predictiva continua.

---

## 📊 2. Matriz Resumen de Evaluación por Dominio (8 Dominios)

```text
               1. Instrumentación [4.2]
                      /\
          8. Resiliencia [4.2]  2. Correlación [4.5]
                 /              \
        7. Visualización [4.0]   3. Infraestructura [4.0]
                 \              /
           6. Alertas & SLOs [4.3]  4. Red & Seguridad [4.0]
                      \/
                 5. AIOps [4.1]
```

| # | Dominio del Blueprint | Puntaje (1–5) | Nivel Cualitativo | Justificación Técnica Resumida |
|---|---|:---:|---|---|
| **D1** | **Instrumentación y Recolección de Telemetría** | **4.2 / 5.0** | Avanzado | SDK OTel oficial 1.27.0 en Python, OTel DB Semantic Conventions (`AsyncPGInstrumentor` / `db_span`), pipeline centralizado OTel Collector. |
| **D2** | **Correlación Cross-Signal y Propagación de Contexto** | **4.5 / 5.0** | Líder | W3C TraceContext distribuido (`traceparent`), inyección de `trace_id`/`span_id` en logs JSON, correlación cruzada trazas ↔ logs ↔ métricas. |
| **D3** | **Monitoreo de Infraestructura y Plataforma** | **4.0 / 5.0** | Avanzado | Cobertura GKE con `prometheus-node-exporter` y `kube-state-metrics`, Cloud SQL Query Insights, IaC reproducible en Terraform. |
| **D4** | **Observabilidad de Red y Seguridad** | **4.0 / 5.0** | Avanzado | VPC Flow Logs con métricas basadas en logs (E-W / N-S), Istio Service Mesh L7 con mTLS STRICT, Security Command Center y `cve-exporter`. |
| **D5** | **AIOps y Detección Automática de Anomalías** | **4.1 / 5.0** | Avanzado | Línea base estadística dinámica ($\mu \pm 2\sigma$) en `data-service`, regla multi-señal (`error_rate > 2σ` $\land$ `latency_p99 > SLO`), supresión de alertas ruidosas. |
| **D6** | **Alertas, SLIs/SLOs y Error Budgets** | **4.3 / 5.0** | Avanzado | Golden Signals RED, alertas basadas en Error Budget Burn Rate, MTTD medido en 77.37s ($< 2\text{ min}$), runbooks operativos vinculados. |
| **D7** | **Visualización y Experiencia Operativa** | **4.0 / 5.0** | Gestionado | Dashboards RED declarativos en Grafana (JSON versionado), Cloud Monitoring, Jaeger UI y Swagger UI con retorno de `trace_id`. |
| **D8** | **Gobierno, Resiliencia y Chaos Engineering** | **4.2 / 5.0** | Avanzado | Suite de caos en sandbox (`kind-otel-chaos`): D1 (latencia 200ms) y D2 (10% errores 500) con guardias de seguridad, pruebas k6 y guía IA. |
| 🏆 | **PROMEDIO GLOBAL PONDERADO** | **4.16 / 5.0** | **NIVEL 4: CUANTITATIVAMENTE GESTIONADO Y RESILIENTE** | **Base sólida, vendor-neutral y lista para evolución a Nivel 5.** |

---

## 🔍 3. Análisis Detallado por Dominio

### Dominio 1: Instrumentación y Recolección de Telemetría (4.2 / 5.0)
* **Fortalezas:**
  - Uso estricto del SDK estándar de OpenTelemetry sin librerías propietarias.
  - Implementación de **OTel DB Semantic Conventions** (`db.system=postgresql`, `db.operation`, `db.sql.table`, `server.address`, `db.statement`).
  - Colectores OTel desplegados como gateway centralizado con procesadores de memoria y batching optimizado.
* **Gaps:**
  - No cuenta con profiling continuo a nivel de línea de código (Continuous Profiling eBPF).

---

### Dominio 2: Correlación Cross-Signal y Propagación de Contexto (4.5 / 5.0)
* **Fortalezas:**
  - Adopción completa del estándar **W3C TraceContext** para interoperabilidad total.
  - Formato de logging JSON estructurado con inyección de metadatos de traza en tiempo de ejecución.
  - Enriquecimiento automático de alertas de error con el `trace_id` del request exacto que falló, permitiendo saltar a Jaeger de forma inmediata.
* **Gaps:**
  - Falta activar soporte de Exemplars nativo en Prometheus para correlación directa métrica ➔ traza en un clic.

---

### Dominio 3: Monitoreo de Infraestructura y Plataforma (4.0 / 5.0)
* **Fortalezas:**
  - Clúster GKE Regional de 6 nodos completamente instrumentado con DaemonSets de Prometheus Node Exporter y KSM.
  - Base de datos Cloud SQL PostgreSQL monitoreada con métricas de saturación y tiempos de query.
  - Infraestructura 100% versionada y reproducible mediante Terraform.
* **Gaps:**
  - El autoescalado de pods depende de métricas estáticas de CPU en lugar de métricas avanzadas de cola o latencia (KEDA).

---

### Dominio 4: Observabilidad de Red y Seguridad (4.0 / 5.0)
* **Fortalezas:**
  - VPC Flow Logs activos para supervisión de tráfico interno este-oeste (E-W) y perimetral norte-sur (N-S).
  - **Istio Service Mesh** desplegado con cifrado mTLS STRICT entre microservicios y métricas de red L7 de Envoy.
  - Microservicio `cve-exporter` para métricas de vulnerabilidades de seguridad y alertas de Cloud Logging ante accesos denegados.
* **Gaps:**
  - Ausencia de inspección profunda de paquetes en kernel space (Cilium Network Flow / eBPF).

---

### Dominio 5: AIOps y Detección Automática de Anomalías (4.1 / 5.0)
* **Fortalezas:**
  - Detección basada en ventana deslizante de 60s con cálculo de media ($\mu$) y desviación estándar ($\sigma$) dinámicas.
  - **Regla de correlación multi-señal:** $(\text{error\_rate} > \mu + 2\sigma) \land (\text{latency\_p99} > \text{SLO})$, suprimiendo el 100% de falsos positivos por jitter transitorio.
  - Demostración empírica de reducción de fatiga de alertas comparando dos épocas de operación.
* **Gaps:**
  - Requiere evolución hacia modelos de Machine Learning multivariados no supervisados (Isolation Forest) para incidentes en cascada complejos.

---

### Dominio 6: Alertas, SLIs/SLOs y Error Budgets (4.3 / 5.0)
* **Fortalezas:**
  - Adopción de la metodología Google SRE (SLIs, SLOs y Error Budgets).
  - Alertas multi-ventana basadas en la tasa de quema de presupuesto de error (**Error Budget Burn Rate**).
  - **MTTD experimental comprobado en 77.37 segundos** ($< 120\text{ s}$) ante inyección de fallas.
  - Cada alerta incluye enlace directo al runbook de mitigación operativa correspondiente.
* **Gaps:**
  - Falta integración directa con plataformas de escalamiento e incident management tipo PagerDuty o Opsgenie.

---

### Dominio 7: Visualización y Experiencia Operativa (4.0 / 5.0)
* **Fortalezas:**
  - Dashboards RED declarativos en Grafana (`sli-dashboard.json`) con 6 paneles clave.
  - Jaeger UI para análisis de spans en cascada y Google Cloud Monitoring para telemetría de nube.
  - Swagger UI interactivo en `service-a` (`http://35.193.118.242:8000/docs`) con retorno de `trace_id` en respuestas.
* **Gaps:**
  - Falta un mapa de servicios dinámico en vivo (Service Graph con Kiali / Grafana Tempo).

---

### Dominio 8: Gobierno, Resiliencia y Chaos Engineering (4.2 / 5.0)
* **Fortalezas:**
  - Framework formal de Chaos Engineering en sandbox dedicado con 2 experimentos validados (D1 latencia 200ms y D2 10% errores 500).
  - Salvaguardas estrictas (`CHAOS_CONTROL_ENABLED` y guardias de contexto en scripts para proteger producción).
  - Guía de estandarización y colaboración para el equipo con IA ([`docs/GUIA_COLABORACION_IA.md`](GUIA_COLABORACION_IA.md)).
  - Pruebas de carga comparativas con **k6** para evaluar el overhead de observabilidad.
* **Gaps:**
  - Las pruebas de caos se ejecutan por demanda y aún no están integradas como compuerta de calidad obligatoria en el pipeline de CI/CD.

---

## 🏁 4. Conclusión de la Autoevaluación

La plataforma se posiciona en el **Nivel 4 (Cuantitativamente Gestionado)** con un puntaje de **4.16 / 5.0**. Demuestra una implementación sólida, desacoplada de proveedores propietarios y con altos estándares de resiliencia y correlación de señales.
