// k6 sustained-load test that drives the HPAs of incident-intake and quorum-coordinator.
//   k6 run -e BASE_URL=http://<INGRESS_IP> loadtest/k6/hpa-load.js
//   k6 run -e BASE_URL=http://<INGRESS_IP> -e PEAK_VUS=60 -e HOLD=8m --out json=loadtest/results/run.json loadtest/k6/hpa-load.js
// Mix: 70% report incident (quorum write W=2), 30% read it back (quorum read R=2).
// CRITICAL incidents are kept rare (2%) so Pub/Sub, the Alert function and Firestore stay inside free quotas.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const PEAK = parseInt(__ENV.PEAK_VUS || '40');
const HOLD = __ENV.HOLD || '6m';

export const options = {
  scenarios: {
    sustained: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '1m', target: Math.ceil(PEAK / 2) },
        { duration: '1m', target: PEAK },
        { duration: HOLD, target: PEAK },     // sustained traffic -> HPA scales out
        { duration: '1m', target: 0 },        // cool down -> HPA scales in (after stabilization window)
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    'http_req_duration{op:write}': ['p(95)<2000'],
    'http_req_duration{op:read}': ['p(95)<1500'],
  },
};

const REGIONS = ['north', 'south', 'east', 'west', 'central'];
const TYPES = ['FLOOD', 'FIRE', 'EARTHQUAKE', 'CYCLONE', 'LANDSLIDE', 'MEDICAL', 'OTHER'];
const writes = new Counter('incident_writes');
const quorumAcks = new Trend('quorum_acks');
const created = [];

function severity() {
  const r = Math.random();
  if (r < 0.02) return 'CRITICAL';
  if (r < 0.20) return 'HIGH';
  if (r < 0.60) return 'MEDIUM';
  return 'LOW';
}

export default function () {
  if (created.length === 0 || Math.random() < 0.7) {
    const body = JSON.stringify({
      reporterId: `k6-${__VU}-${Math.floor(Math.random() * 50)}`,
      type: TYPES[Math.floor(Math.random() * TYPES.length)],
      severity: severity(),
      region: REGIONS[Math.floor(Math.random() * REGIONS.length)],
      description: `load test report from VU ${__VU} iteration ${__ITER}`,
      latitude: 8 + Math.random() * 25,
      longitude: 68 + Math.random() * 25,
      peopleAffected: Math.floor(Math.random() * 500),
    });
    const res = http.post(`${BASE}/api/incidents`, body,
      { headers: { 'Content-Type': 'application/json' }, tags: { op: 'write' } });
    const ok = check(res, { 'write 201': (r) => r.status === 201 });
    if (ok) {
      const j = res.json();
      writes.add(1);
      quorumAcks.add(j.quorum.acks);
      if (created.length < 200) created.push(j.incidentId);
    }
  } else {
    const id = created[Math.floor(Math.random() * created.length)];
    const res = http.get(`${BASE}/api/incidents/${id}`, { tags: { op: 'read' } });
    check(res, { 'read 200': (r) => r.status === 200 });
  }
  sleep(0.2 + Math.random() * 0.3);
}
