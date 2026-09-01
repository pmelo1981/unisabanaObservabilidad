# Pruebas de humo locales — no constituyen la corrida final

## Entorno confirmado

- Kubernetes: kind `v0.31.0`, nodo Kubernetes `v1.35.0`.
- Istio: `1.30.3`.
- Servicios y bases simuladas con sidecars `2/2`.
- OTel Collector `0.108.0`, Prometheus `2.54.1`, Jaeger `1.60`.
- Carga: k6 `1.7.1` ejecutado dentro del mesh.

## Baseline D1

- Corrida: `smoke-d1-baseline`.
- Solicitudes: 300.
- Errores: 0.
- p95 k6: 59,04 ms.
- p99 Prometheus: 73,58 ms.

## D1 válido para prueba de humo

- Corrida: `final-smoke-d1-mttd`.
- Baseline inmediatamente anterior: p99 72,56 ms, alerta ausente.
- Inyección efectiva: `2026-09-01T00:45:48.9177210Z`.
- Perturbación: 200 ms sobre `/items`, 100 % del tráfico.
- Alerta `firing` observada: `2026-09-01T00:47:04.6753179Z`.
- MTTD observado: **75,758 s**, objetivo `< 120 s` cumplido.
- p99 durante una prueba previa equivalente: aproximadamente 479,50 ms.
- Rollback confirmado: `2026-09-01T00:47:13.7984659Z`.
- SLO provisional p99 `< 2000 ms`: no degradado.
- Error rate: 0 % en la prueba equivalente de 601 solicitudes.
- Interpretación: la alerta es preventiva y detecta degradación antes de consumir
  el error budget del SLO de latencia.

## D2 — hallazgos previos

- Una corrida observó 93 errores de 1.200 solicitudes, 7,75 % global porque el
  caos comenzó 16 segundos después de iniciar la carga.
- Los abortos presentan `response_flags="FI"` y `reporter="source"` en Envoy.
- La regla inicial basada en el reporter de destino era incorrecta y fue
  corregida.
- Estas corridas se consideran de depuración y no se usan para afirmar MTTD.

## D2 histórico — implementación reemplazada

Esta prueba usó una inyección Istio que ya no es la implementación oficial. Se
conserva para trazabilidad, pero no debe utilizarse como evidencia final de D2.
La fuente vigente es el motor de caos de `data-service`.

- Corrida: `final-smoke-d2-mttd-fast-scrape`.
- Carga directa a `data-service`: 10 solicitudes/s durante 3 minutos.
- Baseline previo: alerta ausente y respuestas sin 5xx inyectados.
- Inyección efectiva: `2026-09-01T00:55:09.2326683Z`.
- Perturbación: aborto HTTP 500 probabilístico del 10 % sobre `/records`.
- Alerta `firing` observada: `2026-09-01T00:56:29.5796183Z`.
- MTTD observado: **80,347 s**, objetivo `< 120 s` cumplido.
- Error rate de la ventana de alerta: **9,778 %**.
- Rollback confirmado: `2026-09-01T00:56:48.7758751Z`.
- Resultado global de k6: 103 errores de 1.801 solicitudes, 5,71 %. Este valor
  mezcla baseline, caos y recuperación; no representa por sí solo el porcentaje
  de la ventana perturbada.
- SLO provisional de disponibilidad `99,5 %`: degradado durante la ventana de
  caos. El burn rate instantáneo aproximado fue `9,778 / 0,5 = 19,56x`.
- Interpretación: la alerta identifica servicio, experimento, tasa observada y
  runbook; fue accionable y permitió ejecutar rollback antes de 2 minutos.

### Iteración que no cumplió el objetivo

- Con recolección global predeterminada de Prometheus y ventana de 3 minutos,
  D2 tardó aproximadamente **177,107 s** en llegar a `firing`.
- Se ajustó el perfil local a `scrape_interval: 15s`,
  `evaluation_interval: 15s`, ventana de tasa de 1 minuto y `for: 30s`.
- La repetición redujo el MTTD a 80,347 s. Este ajuste deberá validarse de nuevo
  en GCP; no se asume que su pipeline tenga la misma cadencia.

## Incidentes de preparación registrados

1. El chart generaba el nombre `data-service-data-service`; se corrigió con
   `fullnameOverride: data-service` para coincidir con Istio y la documentación.
2. Grafana requería el `ConfigMap` de dashboards antes del despliegue; el script
   local ahora lo crea previamente.
3. Los scripts nativos continuaban después de errores `kubectl`; ahora usan
   `$PSNativeCommandUseErrorActionPreference = $true`.
4. Las ventanas de 1 minuto no contenían suficientes muestras con el scrape
   predeterminado. Se configuró scrape/evaluación cada 15 segundos y se conservó
   `for: 30s`, permitiendo usar una ventana de 1 minuto.

## Estado

**Confirmado:** despliegue local y prueba de D1. La prueba D2 de esta carpeta
corresponde al mecanismo Istio retirado y solo conserva valor histórico.  
**Por verificar:** corrida formal D2 con el motor oficial de `data-service`,
notificación externa y repetición en GCP. Esta carpeta no debe presentarse como
evidencia final del laboratorio.
