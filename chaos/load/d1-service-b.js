import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const businessErrors = new Rate('d1_business_error_rate');
const endToEndDuration = new Trend('d1_end_to_end_duration_ms', true);

const rate = Number.parseInt(__ENV.RATE || '5', 10);
const duration = __ENV.DURATION || '5m';
const preAllocatedVUs = Number.parseInt(__ENV.PRE_ALLOCATED_VUS || '10', 10);

export const options = {
  scenarios: {
    d1_service_b_latency: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      maxVUs: preAllocatedVUs * 3,
    },
  },
  thresholds: {
    d1_business_error_rate: ['rate<0.01'],
  },
};

const baseUrl = __ENV.BASE_URL || 'http://localhost:8000';
const runId = __ENV.RUN_ID || `local-d1-${Date.now()}`;

function randomHex(length) {
  let value = '';
  for (let i = 0; i < length; i += 1) {
    value += Math.floor(Math.random() * 16).toString(16);
  }
  return value;
}

export default function () {
  const itemId = Math.floor(Math.random() * 10) + 1;
  const traceId = randomHex(32);
  const parentId = randomHex(16);
  const response = http.get(`${baseUrl}/process/${itemId}`, {
    headers: {
      Accept: 'application/json',
      'X-Chaos-Run-Id': runId,
      traceparent: `00-${traceId}-${parentId}-01`,
    },
    tags: { experiment: 'd1', target: 'service-b', endpoint: 'process' },
  });

  const ok = check(response, {
    'D1 status 200': (r) => r.status === 200,
    'D1 retorna trace_id': (r) => {
      try {
        return Boolean(JSON.parse(r.body).trace_id);
      } catch (_) {
        return false;
      }
    },
  });
  businessErrors.add(!ok);
  endToEndDuration.add(response.timings.duration);
  sleep(0.05);
}
