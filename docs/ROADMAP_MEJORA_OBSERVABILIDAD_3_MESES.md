# 🗺️ Roadmap de Mejora para Observabilidad a 3 Meses (Hacia Nivel 4.8+)

> **Asignatura:** Observabilidad y Monitoreo de Sistemas Distribuidos  
> **Proyecto:** Pipeline de Observabilidad End-to-End con OpenTelemetry en Google Cloud Platform (GCP)  
> **Objetivo:** Elevar el nivel de madurez del sistema desde **4.16 (Nivel 4: Cuantitativamente Gestionado)** hasta **4.76 (Nivel 5: Optimizado / Autónomo)** en un horizonte de 90 días.  
> **Fecha de Inicio:** Mes 1 (Sprint 1)  

---

## 🎯 1. Visión General del Roadmap (90 Días)

```text
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                   ROADMAP DE MADUREZ (90 DÍAS)                                   │
├──────────────────────────────┬──────────────────────────────────┬────────────────────────────────┤
│      MES 1: AUTOMATIZACIÓN   │       MES 2: AIOps AVANZADO      │     MES 3: AUTORREMEDIACIÓN    │
│    CI/CD & PROFILING BASE    │   & TOPOLOGÍA DINÁMICA (KIALI)   │     & CONTINUOUS RESILIENCE    │
├──────────────────────────────┼──────────────────────────────────┼────────────────────────────────┤
│ • CI/CD con Cloud Build para │ • Despliegue de Istio Kiali para │ • Auto-rollback en Canary con  │
│   pruebas OTel automatizadas │   Service Map dinámico en vivo   │   métricas de Prometheus       │
│ • Exemplars en Prometheus    │ • Modelos de forecasting ARIMA / │ • Pruebas de Chaos continuas   │
│ • Habilitación de Continuous │   Isolation Forest para AIOps    │   en pipeline de staging       │
│   Profiling (eBPF / Parca)   │ • Correlación de trazas L3/L4/L7 │ • Auto-remediación con KEDA    │
└──────────────────────────────┴──────────────────────────────────┴────────────────────────────────┘
```

---

## 📅 2. Plan de Trabajo Detallado Mes a Mes

---

### 🚀 Mes 1: Automatización, CI/CD Quality Gates y Profiling Base
* **Objetivo del Mes:** Eliminar la validación manual de telemetría e introducir observabilidad a nivel de código de bajo nivel sin overhead.
* **Impacto en Madurez:** Sube Dominio 1 (Instrumentación) a 4.5 y Dominio 2 (Correlación) a 4.8.

#### 🔹 Sprint 1 (Días 1 a 15) — Prometheus Exemplars & OTel Validation Pipeline
1. **Prometheus Exemplars en Grafana:**
   - Habilitar soporte nativo de Exemplars en Prometheus Server y OTel Collector.
   - Vincular los picos de latencia en los gráficos RED de Grafana directamente con la traza correspondiente en Jaeger con un solo clic.
2. **Quality Gates de Observabilidad en Google Cloud Build:**
   - Crear un paso automatizado en Cloud Build que valide mediante pruebas unitarias que ningún nuevo endpoint o microservicio se publique sin spans OTel y semantic conventions requeridas.

#### 🔹 Sprint 2 (Días 16 a 30) — Continuous Profiling Inicial con eBPF
1. **Continuous Profiling en GKE:**
   - Desplegar agentes eBPF ligeros (Parca / Pyroscope) como DaemonSet en el clúster GKE para perfilado continuo de CPU y memoria en Python sin modificar el código fuente.
2. **Correlación de Perfiles con Spans:**
   - Documentar la correlación entre líneas de código consumidoras de CPU y spans lentos identificados en Jaeger.

---

### 🧠 Mes 2: AIOps Avanzado y Topología Dinámica en Tiempo Real (Kiali)
* **Objetivo del Mes:** Expandir la inteligencia artificial operativa y la visibilidad de la topología este-oeste del Service Mesh.
* **Impacto en Madurez:** Sube Dominio 5 (AIOps) a 4.6 y Dominio 7 (Visualización) a 4.6.

#### 🔹 Sprint 3 (Días 31 a 45) — Service Map Dinámico con Kiali & Istio
1. **Despliegue de Kiali en GKE:**
   - Instalar el dashboard de Kiali en el namespace `observability` para visualizar en vivo el grafo de dependencias de red L7, el estado de mTLS STRICT y la tasa de tráfico entre microservicios.
2. **Integración Kiali ↔ Jaeger:**
   - Configurar Kiali para consumir directamente las trazas del OTel Collector y resaltar rutas degradadas en tiempo real.

#### 🔹 Sprint 4 (Días 46 a 60) — Detección de Anomalías Estacionales y Multi-Servicio
1. **Modelos de ML para Series Temporales Estacionales:**
   - Extender el motor de AIOps en `data-service` con algoritmos de detección adaptativos (Isolation Forest / EWMA - Medias Móviles Ponderadas Exponencialmente) para tolerar patrones de tráfico diurno/nocturno.
2. **Consolidación de Alertas de Red y Seguridad:**
   - Integrar los eventos de VPC Flow Logs (Cloud Logging) con Prometheus Alertmanager para unificar alertas de red e infraestructura en un solo canal.

---

### 🛡️ Mes 3: Autorremediación y Resiliencia Continua
* **Objetivo del Mes:** Alcanzar la autonomía operativa, auto-rollback y validación continua de resiliencia ante fallas.
* **Impacto en Madurez:** Sube Dominio 6 (SLOs) a 4.9 y Dominio 8 (Gobierno y Caos) a 4.8.

#### 🔹 Sprint 5 (Días 61 a 75) — Canary Deployments Verificados por SLO
1. **Despliegues Progresivos con Flagger / Argo Rollouts:**
   - Implementar Canary Deployments automáticos integrados con Istio y Prometheus.
2. **Auto-Rollback Verificado por Error Budget:**
   - Configurar rollback automático si la versión candidata incrementa la tasa de quema del Error Budget más allá de 2x durante la ventana de prueba de 10 minutos.

#### 🔹 Sprint 6 (Días 76 a 90) — Autorremediación y Continuous Chaos
1. **Webhooks de Autorremediación Dinámica:**
   - Configurar controladores que ejecuten circuit-breakers automáticos en Istio o reinicien conexiones hacia PostgreSQL ante degradación sostenida.
2. **GameDays de Caos Automatizados:**
   - Programar ejecuciones periódicas de experimentos de caos en staging para asegurar que el **MTTD se mantenga siempre $< 30\text{ segundos}$**.

---

## 📊 3. Matriz de Evolución de Madurez (Actual vs. Meta a 3 Meses)

| Dominio del Blueprint | Nivel Inicial | Mes 1 | Mes 2 | Mes 3 (Meta Final) |
|---|:---:|:---:|:---:|:---:|
| **1. Instrumentación y Recolección** | 4.2 | **4.5** | 4.6 | **4.8 / 5.0** |
| **2. Correlación Cross-Signal** | 4.5 | **4.8** | 4.9 | **5.0 / 5.0** |
| **3. Monitoreo de Infraestructura** | 4.0 | 4.2 | 4.4 | **4.6 / 5.0** |
| **4. Observabilidad de Red y Seguridad** | 4.0 | 4.2 | **4.5** | **4.7 / 5.0** |
| **5. AIOps y Detección de Anomalías** | 4.1 | 4.2 | **4.6** | **4.7 / 5.0** |
| **6. Alertas, SLOs y Error Budgets** | 4.3 | 4.4 | 4.6 | **4.9 / 5.0** |
| **7. Visualización y Developer Experience** | 4.0 | 4.2 | **4.6** | **4.6 / 5.0** |
| **8. Gobierno, Resiliencia y Caos** | 4.2 | 4.3 | 4.5 | **4.8 / 5.0** |
| ⭐ **PROMEDIO GLOBAL PONDERADO** | **4.16** | **4.35** | **4.59** | **4.76 / 5.0 (Nivel 5)** |

---

## 🏆 4. Métricas de Éxito e Impacto Operativo (KPIs)

| KPI de Observabilidad | Línea Base Actual | Meta a 90 Días | Beneficio para el Negocio |
|---|:---:|:---:|---|
| **Mean Time to Detect (MTTD)** | 77.37 s | **< 30 s** | Detección casi instantánea con AIOps y Exemplars. |
| **Mean Time to Remediate (MTTR)** | ~10 min (manual) | **< 2 min** | Autorremediación y circuit-breaking automático. |
| **Tasa de Falsos Positivos de Alerta** | < 5% | **< 1%** | Supresión de fatiga de alerta y foco en incidentes reales. |
| **Cobertura de Trazabilidad y Perfilado** | 100% HTTP/DB | **100% + eBPF Profiling** | Cero puntos ciegos entre red, código y kernel. |
| **Nivel de Madurez Blueprint** | **4.16 / 5.0** | **4.76 / 5.0** | Transición a una plataforma de observabilidad autónoma. |
