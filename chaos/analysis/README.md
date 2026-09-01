# Análisis de resultados

`calculate-slo.ps1` calcula MTTD, disponibilidad, cumplimiento del SLO y burn
rate a partir de resultados observados.

```powershell
./calculate-slo.ps1 `
  -Experiment d2 `
  -InjectionEffectiveUtc '2026-08-31T20:00:00Z' `
  -AlertFiringUtc '2026-08-31T20:01:05Z' `
  -TotalEvents 3000 `
  -BadEvents 297 `
  -AvailabilitySlo 0.995
```

El script no inventa el consumo absoluto del budget. Para ese cálculo se debe
conocer la ventana completa del SLO y sus eventos elegibles. El burn rate sí
muestra cuántas veces más rápido se consumió el presupuesto durante la corrida.
