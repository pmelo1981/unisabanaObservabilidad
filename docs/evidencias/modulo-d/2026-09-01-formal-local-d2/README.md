# Corrida formal local D2 — motor oficial de data-service

## Entorno

- Contexto: `kind-otel-chaos`.
- Carga: 10 solicitudes/s durante 7 minutos.
- Diseño: baseline, cinco minutos de caos y recuperación.
- Fuente única de error: `ChaosEngine` de `data-service`.
- Configuración: `transient_errors`, `error_rate=0.10`, HTTP 500.

## Tiempos UTC

- Carga iniciada: `2026-09-01T02:49:17.4782848Z`.
- Caos aplicado: `2026-09-01T02:50:25.1797536Z`.
- Alerta `firing` observada: `2026-09-01T02:51:42.5570094Z`.
- MTTD: **77,377 s**, objetivo `< 120 s` cumplido.
- Rollback confirmado: `2026-09-01T02:55:39.2645904Z`.
- Carga finalizada: `2026-09-01T02:56:26.1015776Z`.

## Resultados

- Error rate de destino antes del rollback: **9,820 %**.
- Resultado k6 extremo a extremo: 4 errores de 4.200, **0,095 %**.
- Checks k6 válidos: 4.200 de 4.200.
- p95 extremo a extremo: 23,32 ms.
- Estado final del motor: `enabled=false`, `scenario=normal`.
- Estado final de la alerta: ausente/resuelta.

## SLO y error budget

Con SLO provisional de disponibilidad 99,5 %, el presupuesto permitido es 0,5 %.

- Límite interno de `data-service`: `9,820 / 0,5 = 19,64x`; el SLO interno se
  degradó y consumió presupuesto rápidamente durante el caos.
- Experiencia extremo a extremo: `0,095 / 0,5 = 0,19x` sobre la corrida global;
  el SLO del cliente no se degradó. Los reintentos del `VirtualService` estable
  recuperaron la mayoría de los HTTP 500.

## Accionabilidad

La alerta identificó `data-service`, experimento D2 y severidad crítica. El
runbook condujo a `/chaos/reset`; el rollback se confirmó en todos los pods. La
alerta fue accionable. La diferencia entre error interno y error cliente es
evidencia de resiliencia, no una segunda implementación de caos.

## Nota de control

Hubo un intento de preparación descartado porque el caos se aplicó antes de
completar el baseline. Se revirtió inmediatamente y no forma parte de estas
mediciones.
