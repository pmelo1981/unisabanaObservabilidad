#!/usr/bin/env bash
# ==============================================================================
# run-benchmark.sh — Ejecuta los benchmarks baseline e instrumented
# y genera la tabla comparativa de overhead de OTel.
#
# Uso: bash benchmark/run-benchmark.sh
# Prerequisitos: k6 instalado, stack Docker Compose corriendo
# ==============================================================================

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8000}"
RESULTS_DIR="benchmark/results"
mkdir -p "$RESULTS_DIR"

echo "============================================================"
echo " OTel Lab — Benchmark de Overhead"
echo " Base URL: $BASE_URL"
echo "============================================================"

# ── 1. Verificar que el stack este corriendo ──────────────────────────────────
echo ""
echo ">> Verificando conectividad con $BASE_URL/health..."
if ! curl -sf "$BASE_URL/health" > /dev/null; then
    echo "ERROR: Service A no responde en $BASE_URL/health"
    echo "Asegurate de que el stack este corriendo: docker compose up -d"
    exit 1
fi
echo "   OK — Service A disponible"

# ── 2. Benchmark CON OTel (instrumented) ──────────────────────────────────────
echo ""
echo ">> [1/2] Ejecutando benchmark INSTRUMENTED (con OTel SDK)..."
echo "   Duracion: ~5 minutos, 50-100 VUs concurrentes"
echo ""
k6 run \
    --env BASE_URL="$BASE_URL" \
    --out json="$RESULTS_DIR/instrumented-raw.json" \
    benchmark/k6-instrumented.js

echo ""
echo "   Resultados guardados en: $RESULTS_DIR/instrumented-results.json"

# ── 3. Cambiar a modo baseline (deshabilitar OTel) ────────────────────────────
echo ""
echo ">> Deshabilitando OTel SDK para modo baseline..."
echo "   Reiniciando service-a y service-b con OTEL_SDK_DISABLED=true..."
docker compose stop service-a service-b > /dev/null 2>&1 || true
OTEL_SDK_DISABLED=true docker compose up -d service-a service-b > /dev/null 2>&1 || \
    docker compose run -d \
        -e OTEL_SDK_DISABLED=true \
        -p 8000:8000 service-a > /dev/null 2>&1 || true

echo "   Esperando 15s para que los servicios esten listos..."
sleep 15

# ── 4. Benchmark SIN OTel (baseline) ─────────────────────────────────────────
echo ""
echo ">> [2/2] Ejecutando benchmark BASELINE (sin OTel SDK)..."
echo "   Duracion: ~5 minutos, 50-100 VUs concurrentes"
echo ""
k6 run \
    --env BASE_URL="$BASE_URL" \
    --out json="$RESULTS_DIR/baseline-raw.json" \
    benchmark/k6-baseline.js

echo ""
echo "   Resultados guardados en: $RESULTS_DIR/baseline-results.json"

# ── 5. Restaurar modo instrumented ────────────────────────────────────────────
echo ""
echo ">> Restaurando modo instrumented (con OTel SDK)..."
docker compose stop service-a service-b > /dev/null 2>&1 || true
docker compose up -d service-a service-b > /dev/null 2>&1 || true

# ── 6. Generar tabla comparativa ──────────────────────────────────────────────
echo ""
echo "============================================================"
echo " TABLA COMPARATIVA DE OVERHEAD — OTel SDK"
echo "============================================================"
echo ""
echo " Revisar archivos de resultados:"
echo "   - $RESULTS_DIR/baseline-results.json"
echo "   - $RESULTS_DIR/instrumented-results.json"
echo ""
echo " Metricas clave a comparar:"
echo "   - http_req_duration: p50, p95, p99, max"
echo "   - http_req_failed: rate"
echo "   - Overhead = (instrumented - baseline) / baseline * 100%"
echo ""
echo "============================================================"
echo " NOTA: El benchmark tarda ~10 minutos en total."
echo " Para el reporte, completar la tabla con los valores reales"
echo " de los archivos JSON generados en benchmark/results/"
echo "============================================================"
