// Quick end-to-end smoke test of every public API (1 VU, ~30 s).
//   k6 run -e BASE_URL=http://<INGRESS_IP> loadtest/k6/smoke.js
import http from 'k6/http';
import { check, group, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
export const options = { vus: 1, iterations: 5, thresholds: { checks: ['rate>0.95'] } };
const json = { headers: { 'Content-Type': 'application/json' } };

export default function () {
  let id;
  group('intake + quorum', () => {
    const r = http.post(`${BASE}/api/incidents`, JSON.stringify({
      reporterId: 'smoke', type: 'FIRE', severity: 'HIGH', region: 'west',
      description: 'smoke test fire', latitude: 19.07, longitude: 72.88, peopleAffected: 12 }), json);
    check(r, { 'incident created': (x) => x.status === 201 });
    id = r.json('incidentId');
    check(http.get(`${BASE}/api/incidents/${id}`), { 'incident read': (x) => x.status === 200 });
    check(http.get(`${BASE}/api/quorum/replicas`), { 'replicas listed': (x) => x.status === 200 });
  });
  group('registry + volunteers', () => {
    check(http.get(`${BASE}/api/resources?region=west`), { 'resources': (x) => x.status === 200 });
    check(http.get(`${BASE}/api/volunteers?region=west`), { 'volunteers': (x) => x.status === 200 });
  });
  group('dispatch', () => {
    const r = http.post(`${BASE}/api/dispatch`, JSON.stringify({ incidentId: id }), json);
    check(r, { 'dispatch created (201) or nothing available (409)': (x) => x.status === 201 || x.status === 409 });
  });
  group('analytics', () => {
    check(http.get(`${BASE}/api/analytics/summary`), { 'summary': (x) => x.status === 200 });
  });
  sleep(1);
}
