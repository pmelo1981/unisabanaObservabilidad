import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Counter } from 'k6/metrics';

const injectedErrorRate = new Rate('d2_observed_error_rate');
const successCount = new Counter('d2_success_total');
const serverErrorCount = new Counter('d2_server_error_total');

const rate = Number.parseInt(__ENV.RATE || '10', 10);
const duration = __ENV.DURATION || '5m';
const preAllocatedVUs = Number.parseInt(__ENV.PRE_ALLOCATED_VUS || '10', 10);

export const options = {
  scenarios: {
    d2_data_service_errors: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs,
      maxVUs: preAllocatedVUs * 3,
    },
  },
};

const baseUrl = __ENV.BASE_URL || 'http://localhost:18080';
const endpoint = __ENV.DATA_ENDPOINT || '/records';
const runId = __ENV.RUN_ID || `local-d2-${Date.now()}`;

function randomHex(length) {
  let value = '';
  for (let i = 0; i < length; i += 1) {
    value += Math.floor(Math.random() * 16).toString(16);
  }
  return value;
}

export default function () {
  const traceId = randomHex(32);
  const parentId = randomHex(16);
  const response = http.get(`${baseUrl}${endpoint}`, {
    headers: {
      Accept: 'application/json',
      'X-Chaos-Run-Id': runId,
      traceparent: `00-${traceId}-${parentId}-01`,
    },
    tags: { experiment: 'd2', target: 'data-service', endpoint },
  });

  const isServerError = response.status >= 500 && response.status <= 599;
  injectedErrorRate.add(isServerError);
  if (isServerError) {
    serverErrorCount.add(1);
  } else if (response.status >= 200 && response.status <= 399) {
    successCount.add(1);
  }

  check(response, {
    'D2 respuesta esperada 2xx o 5xx': (r) =>
      (r.status >= 200 && r.status <= 399) || (r.status >= 500 && r.status <= 599),
  });
  sleep(0.05);
}
