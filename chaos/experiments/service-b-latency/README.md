# D1 — Latencia en `service-b`

Hipótesis: al añadir 200 ms al 100 % del tráfico de `/items`, la latencia
extremo a extremo observada desde `service-a` aumenta aproximadamente 200 ms y
la regla de degradación entra en `firing` antes de 120 segundos.

La hipótesis no presupone que el SLO p99 `< 2000 ms` se incumpla. Eso se calcula
con la medición posterior.

```powershell
./run.ps1 -ExpectedContext kind-otel-chaos -Action Validate
./run.ps1 -ExpectedContext kind-otel-chaos -Action Apply -Confirmation MODULO-D-SANDBOX
./run.ps1 -ExpectedContext kind-otel-chaos -Action Rollback -Confirmation MODULO-D-SANDBOX
```

La corrida formal completa (un minuto de baseline, cinco de caos y uno de
recuperación) está documentada en `../../README.md`.

Abortar si se pierde telemetría, se afectan health checks, el error rate aumenta
inesperadamente o aparece impacto fuera de `services`.
