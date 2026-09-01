# Runbook D1 — Latencia en `service-b`

1. Confirmar alerta, entorno, servicio y hora UTC.
2. Revisar p50/p95/p99 de `order_processing_duration_milliseconds`.
3. Buscar el `trace_id` de una respuesta k6 y abrirla en Jaeger.
4. Confirmar que el incremento aparece en el salto `service-a → service-b`.
5. Verificar `VirtualService/chaos-d1-service-b-latency` en `services`.
6. Ejecutar rollback con el script del experimento.
7. Confirmar que el recurso desapareció y que el p99 regresó al baseline.

Abortar sin esperar la ventana completa si aparecen 5xx, pérdida de telemetría o
impacto fuera del namespace `services`.
