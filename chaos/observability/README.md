# Detección y alertas

`prometheus-rules.yaml` contiene reglas portables para la validación local.

## D1

El baseline local de humo fue 73,58 ms de p99. La alerta local usa 200 ms, valor
superior a ese baseline y menor que el incremento esperado de 200 ms. No
equivale a incumplimiento del SLO p99 `< 2000 ms`.

En GCP se debe medir un baseline nuevo y reemplazar este umbral antes de ejecutar;
no se debe copiar 200 ms si la latencia normal del entorno es distinta.

## D2

Usa `istio_requests_total` con `reporter="destination"`, porque el error HTTP 500
se origina en el motor oficial de `data-service` y atraviesa su proxy Envoy. Esto
evita contar fallas de un inyector de red alternativo. El scrape de métricas
Istio debe verificarse en el preflight.

El perfil local fija scrape y evaluación cada 15 segundos. Esto permite usar una
ventana de 1 minuto con varias muestras y exige 30 segundos de persistencia antes
de `firing`. Con la cadencia predeterminada más lenta se observó un MTTD superior
a 2 minutos, por lo que estos intervalos son parte del requisito y no un detalle
operativo.

Para GCP, estas expresiones se migrarán a políticas PromQL de Cloud Monitoring.
El MTTD se calcula hasta `firing`; la notificación se mide por separado.
