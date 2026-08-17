/**
 * k6 — Benchmark CON instrumentacion OTel (escenario "instrumented")
 *
 * Objetivo: medir overhead de OTel SDK bajo carga realista.
 * Configuracion: 50→100 usuarios concurrentes, duracion 5 minutos.
 *
 * Uso:
 *   k6 run benchmark/k6-instrumented.js
 *   k6 run --env BASE_URL=http://localhost:8000 benchmark/k6-instrumented.js
 *
 * Comparar resultados contra k6-baseline.js (OTEL_SDK_DISABLED=true)
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

// ── Metricas custom k6 ──────────────────────────────────────────────────────
const errorRate       = new Rate('custom_error_rate');
const processingTime  = new Trend('custom_processing_time_ms', true);
const ordersCreated   = new Counter('custom_orders_created');
const notFoundErrors  = new Counter('custom_404_errors');

// ── Configuracion del test ───────────────────────────────────────────────────
export const options = {
  stages: [
    { duration: '30s', target: 10  },  // Warm-up
    { duration: '60s', target: 50  },  // Ramp up → 50 VUs
    { duration: '3m',  target: 100 },  // Carga sostenida a 100 VUs
    { duration: '30s', target: 0   },  // Ramp down
  ],
  thresholds: {
    // SLOs de referencia
    'http_req_duration':          ['p(99)<2000', 'p(95)<1000', 'p(50)<300'],
    'http_req_failed':            ['rate<0.05'],
    'custom_error_rate':          ['rate<0.05'],
    'custom_processing_time_ms':  ['p(99)<2500'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

// ── Escenario principal ──────────────────────────────────────────────────────
export default function () {
  const itemId = Math.floor(Math.random() * 10) + 1; // items 1–10

  group('process_item_flow', function () {
    // ── Request principal: process item (llama service-b + DB) ───────────────
    const res = http.get(`${BASE_URL}/process/${itemId}`, {
      tags: { scenario: 'instrumented', endpoint: 'process' },
      headers: {
        'Accept': 'application/json',
        'X-Load-Test': 'k6-instrumented',
      },
    });

    const success = check(res, {
      'status es 200':                  (r) => r.status === 200,
      'tiene order_id en respuesta':    (r) => {
        try { return JSON.parse(r.body).order_id !== undefined; }
        catch { return false; }
      },
      'tiene trace_id en respuesta':    (r) => {
        try { return JSON.parse(r.body).trace_id !== ''; }
        catch { return false; }
      },
      'latencia < 2000ms':              (r) => r.timings.duration < 2000,
    });

    errorRate.add(!success);
    processingTime.add(res.timings.duration);

    if (res.status === 200) {
      ordersCreated.add(1);
    } else if (res.status === 404) {
      notFoundErrors.add(1);
    }
  });

  // ── Request secundario: list orders (solo lectura de DB) ──────────────────
  if (Math.random() < 0.2) { // 20% de VUs tambien consultan /orders
    group('list_orders_flow', function () {
      const listRes = http.get(`${BASE_URL}/orders?limit=10`, {
        tags: { scenario: 'instrumented', endpoint: 'list_orders' },
      });
      check(listRes, {
        'orders status 200': (r) => r.status === 200,
        'orders es array':   (r) => {
          try { return Array.isArray(JSON.parse(r.body)); }
          catch { return false; }
        },
      });
    });
  }

  sleep(0.5 + Math.random() * 0.5); // 0.5–1.0s entre requests
}

// ── Resumen al final del test ───────────────────────────────────────────────
export function handleSummary(data) {
  return {
    'benchmark/results/instrumented-results.json': JSON.stringify(data, null, 2),
    stdout: formatSummary(data, 'CON OTel (instrumented)'),
  };
}

function formatSummary(data, label) {
  const metrics = data.metrics;
  const dur = metrics['http_req_duration'];
  return `
========================================
 k6 Benchmark — ${label}
========================================
 Total requests : ${metrics['http_reqs']?.values?.count || 'N/A'}
 Error rate     : ${((metrics['http_req_failed']?.values?.rate || 0) * 100).toFixed(2)}%
 Latencia p50   : ${dur?.values?.['p(50)']?.toFixed(2) || 'N/A'} ms
 Latencia p95   : ${dur?.values?.['p(95)']?.toFixed(2) || 'N/A'} ms
 Latencia p99   : ${dur?.values?.['p(99)']?.toFixed(2) || 'N/A'} ms
 Latencia max   : ${dur?.values?.max?.toFixed(2) || 'N/A'} ms
========================================
`;
}
