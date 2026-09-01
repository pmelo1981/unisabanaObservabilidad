# Runbook D2 — Errores en `data-service`

1. Confirmar alerta, entorno, servicio y hora UTC.
2. Revisar numerador, denominador y error rate de `istio_requests_total` con
   `reporter="destination"`.
3. Comparar los HTTP 500 generados por `data-service` con
   `d2_observed_error_rate` de k6 y `/chaos/status`.
4. Buscar `X-Chaos-Run-Id`, `traceparent` o `x-request-id` en access logs Envoy.
5. Verificar que `/health` permanece saludable.
6. Ejecutar rollback mediante `/chaos/reset` usando el script del experimento.
7. Confirmar error rate normal y cierre de la alerta.

El error se genera dentro de la aplicación, por lo que debe buscarse una traza y
un log correlacionados. Si faltan, registrar la pérdida de telemetría como fallo
del experimento en lugar de sustituirla por evidencia de otro mecanismo.
