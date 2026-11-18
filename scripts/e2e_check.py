#!/usr/bin/env python3
"""End-to-end functional check of all 8 services through ONE base URL.

  local : BASE_URL=http://localhost:8080          (docker compose gateway)
  GCP   : BASE_URL=http://<INGRESS_IP>             (GKE Ingress)

Usage (PowerShell):
  pip install httpx
  . .\\scripts\\env.ps1 -Local      # or without -Local on GCP
  python scripts/e2e_check.py                     # core flow (REST, gRPC, Kafka, Pub/Sub, 3 storage products)
  python scripts/e2e_check.py --flink             # + wait for Flink window results (needs the Flink job running)
  python scripts/e2e_check.py --skip-alerts       # if the Alert Service is not deployed yet

Every check prints PASS/FAIL with the evidence it looked at; exit code 0 only if everything passed.
Nothing is simulated: every value comes from the running services.
"""
import argparse
import json
import os
import sys
import time

import httpx

BASE = os.getenv("BASE_URL", "http://localhost:8080").rstrip("/")
c = httpx.Client(base_url=BASE, timeout=20)
results = []


def check(name, ok, evidence=None):
    results.append((name, bool(ok)))
    line = json.dumps(evidence, default=str)[:350] if evidence is not None else ""
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f"\n       {line}" if line else ""), flush=True)
    return bool(ok)


def j(r):
    try:
        return r.json()
    except ValueError:
        return {"_raw": r.text[:200]}


def poll(fn, timeout_s, every_s=2.0):
    """Call fn() until it returns a truthy value or the timeout expires; returns the last value."""
    deadline = time.time() + timeout_s
    val = None
    while time.time() < deadline:
        val = fn()
        if val:
            return val
        time.sleep(every_s)
    return val


def incident(sev, region, desc):
    return {"reporterId": f"e2e-{int(time.time() * 1000) % 1000000}", "type": "FLOOD", "severity": sev,
            "region": region, "description": desc, "latitude": 19.07, "longitude": 72.88, "peopleAffected": 25}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flink", action="store_true", help="also wait for Flink window results (up to 4 min)")
    ap.add_argument("--skip-alerts", action="store_true", help="do not wait for Alert Service deliveries")
    ap.add_argument("--alert-timeout", type=int, default=60)
    a = ap.parse_args()
    print(f"# e2e check against {BASE}  ({time.strftime('%Y-%m-%dT%H:%M:%S%z')})\n")

    # ---------------------------------------------------------------- 1. every service answers
    for path, name in [("/api/quorum/config", "Quorum Coordinator"), ("/api/incidents/_meta/types", "Incident Intake"),
                       ("/api/resources/stats", "Resource Registry (Cloud SQL)"),
                       ("/api/volunteers/stats", "Volunteer Coordination (Firestore)"),
                       ("/api/dispatch/_meta/consumer", "Dispatch (Kafka consumer)"),
                       ("/api/analytics/summary", "Situation Analytics API")]:
        r = c.get(path)
        check(f"1. {name} reachable: GET {path} -> 200", r.status_code == 200, {"status": r.status_code})
    reps = j(c.get("/api/quorum/replicas")).get("replicas", [])
    check("1b. 3 incident-store replicas reachable over gRPC",
          len(reps) == 3 and all(x.get("reachable") and x.get("faultMode") == "none" for x in reps),
          [{k: x.get(k) for k in ("id", "reachable", "faultMode", "keys")} for x in reps])

    # ---------------------------------------------------------------- 2. seed volunteers
    r = c.post("/api/volunteers/_seed", params={"perRegion": 8})
    check("2. seed 8 volunteers per region (Firestore batch write)", r.status_code == 201, j(r))

    # ---------------------------------------------------------------- 3. incident lifecycle via quorum
    r = c.post("/api/incidents", json=incident("HIGH", "west", "e2e: street flooding near the station"))
    inc = j(r)
    if not check("3. POST /api/incidents (HIGH) -> 201 with W=2 quorum acks",
                 r.status_code == 201 and inc.get("quorum", {}).get("acks", 0) >= 2, inc):
        return finish()
    iid = inc["incidentId"]
    check("3b. INCIDENT_REPORTED event queued to Kafka", inc.get("kafkaEventQueued") is True,
          {"kafkaEventQueued": inc.get("kafkaEventQueued")})
    g = j(c.get(f"/api/incidents/{iid}"))
    check("3c. quorum read (R=2) returns the incident", g.get("value", {}).get("status") == "REPORTED",
          {"responded": g.get("responded"), "context": g.get("context")})
    r = c.patch(f"/api/incidents/{iid}", json={"status": "VERIFIED", "note": "verified by e2e", "author": "field-officer"})
    check("3d. PATCH (read-modify-write with vector-clock context) -> VERIFIED", r.status_code == 200
          and j(r).get("value", {}).get("status") == "VERIFIED", {"context": j(r).get("context")})
    lst = j(c.get("/api/incidents", params={"limit": 200})).get("items", [])
    check("3e. GET /api/incidents lists it", any(x.get("incidentId") == iid for x in lst), {"listed": len(lst)})

    # ---------------------------------------------------------------- 4. GCS attachment
    r = c.post(f"/api/incidents/{iid}/attachments",
               files={"file": ("e2e-photo.txt", b"pretend this is a photo of the flood", "text/plain")})
    check("4. attachment stored in Cloud Storage (object store)", r.status_code == 201
          and j(r).get("uri", "").startswith("gs://"), j(r))

    # ---------------------------------------------------------------- 5. manual dispatch
    before = j(c.get("/api/resources/stats")).get("byRegion", {}).get("west", {})
    r = c.post("/api/dispatch", json={"incidentId": iid})
    d = j(r)
    disp = d.get("dispatch", {})
    check("5. POST /api/dispatch -> 201 (resources reserved in Cloud SQL, volunteers in Firestore)",
          r.status_code == 201 and len(disp.get("resource_ids", [])) == 2 and len(disp.get("volunteer_ids", [])) == 3,
          {"status": r.status_code, "resources": disp.get("resource_ids"), "volunteers": disp.get("volunteer_ids"),
           "alertPublished": d.get("alertPublished"), "error": d.get("error") or d.get("detail")})
    if r.status_code == 201:
        g = j(c.get(f"/api/incidents/{iid}"))
        check("5b. incident is DISPATCHED in the replicated store with the assigned resources",
              g.get("value", {}).get("status") == "DISPATCHED"
              and set(g["value"].get("assignedResources", [])) == set(disp["resource_ids"]),
              {"status": g.get("value", {}).get("status")})
        res0 = j(c.get(f"/api/resources/{disp['resource_ids'][0]}")) if disp.get("resource_ids") else {}
        check("5c. reserved resource is RESERVED in Cloud SQL", res0.get("status") == "RESERVED",
              {k: res0.get(k) for k in ("id", "name", "status", "version")})
        vid = (disp.get("volunteer_ids") or [None])[0]
        vol0 = j(c.get(f"/api/volunteers/{vid}")) if vid else {}
        check("5d. assigned volunteer is unavailable and linked to the incident",
              vol0.get("available") is False and vol0.get("currentIncident") == iid,
              {k: vol0.get(k) for k in ("id", "available", "currentIncident")} if vid else "no volunteer was assigned")
        after = j(c.get("/api/resources/stats")).get("byRegion", {}).get("west", {})
        avail = lambda s: sum(v.get("AVAILABLE", 0) for v in s.values())  # noqa: E731
        check("5e. AVAILABLE resources in 'west' dropped by 2", avail(before) - avail(after) == 2,
              {"before": avail(before), "after": avail(after)})

        # ---------------------------------------------------------------- 6. serverless Alert Service
        if not a.skip_alerts:
            alert = poll(lambda: next((x for x in j(c.get("/api/analytics/alerts", params={"limit": 50})).get("items", [])
                                       if x.get("incidentId") == iid and x.get("alertType") == "DISPATCH_ASSIGNED"),
                                      None), a.alert_timeout)
            check("6. Pub/Sub -> serverless Alert Service processed DISPATCH_ASSIGNED", bool(alert)
                  and alert.get("delivered", 0) >= 3,
                  {k: (alert or {}).get(k) for k in ("alertId", "channels", "delivered", "failed", "processingMs")})
            inbox = j(c.get(f"/api/volunteers/{vid}/notifications")).get("items", []) if vid else []
            check("6b. the assigned volunteer's inbox holds the notification",
                  any(n.get("incidentId") == iid for n in inbox), {"inbox": len(inbox)})

        # ---------------------------------------------------------------- 7. complete dispatch
        r = c.post(f"/api/dispatch/{disp['id']}/complete")
        check("7. complete dispatch -> COMPLETED", r.status_code == 200 and j(r).get("status") == "COMPLETED", j(r))
        g = j(c.get(f"/api/incidents/{iid}"))
        check("7b. incident RESOLVED", g.get("value", {}).get("status") == "RESOLVED",
              {"status": g.get("value", {}).get("status"), "notes": len(g.get("value", {}).get("notes", []))})
        res0 = j(c.get(f"/api/resources/{disp['resource_ids'][0]}")) if disp.get("resource_ids") else {}
        vol0 = j(c.get(f"/api/volunteers/{vid}")) if vid else {}
        check("7c. resource and volunteer released", res0.get("status") == "AVAILABLE" and vol0.get("available") is True,
              {"resource": res0.get("status"), "volunteerAvailable": vol0.get("available")})

    # ---------------------------------------------------------------- 8. CRITICAL -> Pub/Sub alert + Kafka auto-dispatch
    r = c.post("/api/incidents", json=incident("CRITICAL", "north", "e2e: dam breach, villages evacuating"))
    crit = j(r)
    check("8. CRITICAL incident -> 201 and alert published to Pub/Sub", r.status_code == 201
          and crit.get("alertPublished") is True, {k: crit.get(k) for k in ("incidentId", "alertPublished")})
    cid = crit.get("incidentId")
    auto = poll(lambda: next((x for x in j(c.get("/api/dispatch", params={"status": "ACTIVE", "limit": 100})).get("items", [])
                              if x.get("incident_id") == cid), None), 30)
    check("8b. Dispatch auto-dispatched it from the Kafka incident-events topic", bool(auto) and auto.get("mode") == "AUTO",
          {k: (auto or {}).get(k) for k in ("id", "mode", "resource_ids", "volunteer_ids")})
    if not a.skip_alerts and cid:
        alert = poll(lambda: next((x for x in j(c.get("/api/analytics/alerts", params={"limit": 50})).get("items", [])
                                   if x.get("incidentId") == cid and x.get("alertType") == "CRITICAL_INCIDENT"), None),
                     a.alert_timeout)
        check("8c. Alert Service delivered the CRITICAL alert (inbox + regional broadcast)",
              bool(alert) and "broadcast" in alert.get("channels", []) and alert.get("delivered", 0) >= 1,
              {k: (alert or {}).get(k) for k in ("channels", "recipientCount", "delivered", "failed")})
        bc = j(c.get("/api/volunteers/broadcasts/north")).get("items", [])
        check("8d. regional broadcast for 'north' is readable", any(x.get("incidentId") == cid for x in bc),
              {"broadcasts": len(bc)})
    if auto:
        c.post(f"/api/dispatch/{auto['id']}/complete")

    # ---------------------------------------------------------------- 9. analytics
    s = j(c.get("/api/analytics/summary"))
    check("9. analytics summary aggregates Registry + Volunteers + Coordinator over REST",
          "byRegion" in s.get("resourceDemand", {}) and "byRegion" in s.get("volunteers", {})
          and "writes" in s.get("consistency", {}),
          {"coordinatorWrites": s.get("consistency", {}).get("writes"), "pipeline": s.get("pipeline")})
    if a.flink:
        print("   waiting for a closed 1-minute Flink window (up to 4 minutes)...", flush=True)
        w = poll(lambda: j(c.get("/api/analytics/windows", params={"limit": 20})).get("items"), 240, 10)
        check("9b. Flink window results arrived (Kafka incident-aggregates -> Firestore)", bool(w),
              (w or [{}])[0])

    return finish()


def finish():
    passed = sum(ok for _, ok in results)
    print(f"\n{passed}/{len(results)} checks passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
