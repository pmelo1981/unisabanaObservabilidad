# D2 — Error rate en `data-service`

Hipótesis: al generar HTTP 500 en el 10 % del tráfico de `/records`, el error
rate en el límite de `data-service` converge alrededor de 10 % y la alerta entra
en `firing` antes de 120 segundos. El error percibido por el cliente se mide por
separado porque los reintentos estables del mesh pueden recuperar solicitudes.

El motor de `data-service` es la fuente única de D2. El script configura todas
las réplicas activas con `transient_errors`, `error_rate=0.10` y HTTP 500. El
rollback invoca `/chaos/reset` en cada pod y comprueba que todos queden en
estado normal.

```powershell
./run.ps1 -ExpectedContext kind-otel-chaos -Action Validate
./run.ps1 -ExpectedContext kind-otel-chaos -Action Apply -Confirmation MODULO-D-SANDBOX
./run.ps1 -ExpectedContext kind-otel-chaos -Action Rollback -Confirmation MODULO-D-SANDBOX
```

La corrida formal completa está documentada en `../../README.md`.
