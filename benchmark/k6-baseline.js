/**
 * k6 — Benchmark SIN instrumentacion OTel (escenario "baseline")
 *
 * Para usar este script, primero levantar los servicios con OTel deshabilitado:
 *
 *   docker compose stop service-a service-b
 *   OTEL_SDK_DISABLED=true docker compose up -d service-a service-b
 *
 * O usar el perfil baseline:
 *   docker compose --profile baseline up -d
 *
 * Luego ejecutar:
 *   k6 run benchmark/k6-baseline.js
 *
 * Comparar resultados contra k6-instrumented.js para medir overhead de OTel.
 */

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Rate, Trend, Counter } from 'k6/metrics';

const errorRate      = new Rate('custom_error_rate');
const processingTime = new Trend('custom_processing_time_ms', true);
const requestsOk     = new Counter('custom_requests_ok');

export const options = {
  // Exactamente la misma configuracion que k6-instrumented.js
  stages: [
    { duration: '30s', target: 10  },
    { duration: '60s', target: 50  },
    { duration: '3m',  target: 100 },
    { duration: '30s', target: 0   },
  ],
  thresholds: {
    'http_req_duration':          ['p(99)<2000', 'p(95)<1000', 'p(50)<300'],
    'http_req_failed':            ['rate<0.05'],
    'custom_error_rate':          ['rate<0.05'],
    'custom_processing_time_ms':  ['p(99)<2500'],
  },
};

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8000';

export default function () {
  const itemId = Math.floor(Math.random() * 10) + 1;

  group('process_item_flow_baseline', function () {
    const res = http.get(`${BASE_URL}/process/${itemId}`, {
      tags: { scenario: 'baseline', endpoint: 'process' },
      headers: {
        'Accept': 'application/json',
        'X-Load-Test': 'k6-baseline',
      },
    });

    const success = check(res, {
      'status es 200':      (r) => r.status === 200,
      'tiene order_id':     (r) => {
        try { return JSON.parse(r.body).order_id !== undefined; }
        catch { return false; }
      },
      'latencia < 2000ms':  (r) => r.timings.duration < 2000,
    });

    errorRate.add(!success);
    processingTime.add(res.timings.duration);
    if (success) requestsOk.add(1);
  });

  if (Math.random() < 0.2) {
    group('list_orders_flow_baseline', function () {
      const listRes = http.get(`${BASE_URL}/orders?limit=10`, {
        tags: { scenario: 'baseline', endpoint: 'list_orders' },
      });
      check(listRes, {
        'orders status 200': (r) => r.status === 200,
      });
    });
  }

  sleep(0.5 + Math.random() * 0.5);
}

export function handleSummary(data) {
  return {
    'benchmark/results/baseline-results.json': JSON.stringify(data, null, 2),
    stdout: formatSummary(data, 'SIN OTel (baseline)'),
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
