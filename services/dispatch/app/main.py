"""Dispatch Service - assigns resources and volunteers to incidents.

REST (port 8080, prefix /api/dispatch)
  POST /api/dispatch                     body {"incidentId", "quantity"?, "kind"?, "volunteers"?}
  GET  /api/dispatch?status=ACTIVE&limit=50
  GET  /api/dispatch/{id}
  POST /api/dispatch/{id}/complete       release resources/volunteers, mark incident RESOLVED
Kafka consumer  incident-events  -> auto-dispatch CRITICAL incidents (AUTO_DISPATCH=true)
Kafka producer  dispatch-events  -> DISPATCH_CREATED / DISPATCH_COMPLETED (input of the Flink job)
REST clients    quorum-coordinator (read incident + context, write DISPATCHED/RESOLVED)
                resource-registry  (reserve / release)
                volunteer-coordination (assign / release)
Pub/Sub         alert-requests (DISPATCH_ASSIGNED notifications -> serverless Alert Service)
Storage         Cloud SQL table dispatch_assignments
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import os
import pathlib
import uuid
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse
from psycopg.errors import UniqueViolation
from psycopg.rows import dict_row
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

from s19common.db import migrate, open_pool
from s19common.gcp import PROJECT_ID, PubSubPublisher
from s19common.kafka_util import (TOPIC_DISPATCH_EVENTS, TOPIC_INCIDENT_EVENTS, KafkaConsumerThread,
                                  KafkaPublisher, now_ms)
from s19common.obs import instrument, setup_logging

SERVICE = "dispatch"
log = setup_logging(SERVICE)

COORDINATOR_URL = os.getenv("COORDINATOR_URL", "http://quorum-coordinator:8080")
REGISTRY_URL = os.getenv("REGISTRY_URL", "http://resource-registry:8080")
VOLUNTEER_URL = os.getenv("VOLUNTEER_URL", "http://volunteer-coordination:8080")
KAFKA_BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "")
ALERT_TOPIC = os.getenv("ALERT_TOPIC", "alert-requests")
AUTO_DISPATCH = os.getenv("AUTO_DISPATCH", "true").lower() == "true"
AUTO_DISPATCH_SEVERITIES = set(os.getenv("AUTO_DISPATCH_SEVERITIES", "CRITICAL").split(","))
CLIENT_ID = "dispatch"

RESOURCES_BY_SEVERITY = {"CRITICAL": 3, "HIGH": 2, "MEDIUM": 1, "LOW": 1}
VOLUNTEERS_BY_SEVERITY = {"CRITICAL": 5, "HIGH": 3, "MEDIUM": 1, "LOW": 0}


class DispatchIn(BaseModel):
    incidentId: str = Field(min_length=3, max_length=64)
    quantity: Optional[int] = Field(default=None, ge=1, le=20)
    kind: Optional[str] = Field(default=None, pattern=r"^(VEHICLE|SUPPLY|TEAM)$")
    volunteers: Optional[int] = Field(default=None, ge=0, le=50)


state: dict = {}
COLS = ("id::text AS id, incident_id, region, severity, resource_ids, volunteer_ids, status, mode, "
        "shortfall, created_at, completed_at")


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    pool = await open_pool()
    await migrate(pool, pathlib.Path(__file__).parent / "migrations", "dispatch_schema_migrations")
    state.update(pool=pool, http=httpx.AsyncClient(timeout=5.0), loop=asyncio.get_running_loop(),
                 kafka=KafkaPublisher(KAFKA_BOOTSTRAP, SERVICE), pubsub=PubSubPublisher(PROJECT_ID, ALERT_TOPIC))
    consumer = None
    if AUTO_DISPATCH:
        consumer = KafkaConsumerThread(KAFKA_BOOTSTRAP, "dispatch-auto", [TOPIC_INCIDENT_EVENTS], _on_incident_event)
        consumer.start()
    state["consumer"] = consumer
    yield
    if consumer:
        consumer.stop()
    state["kafka"].flush()
    await state["http"].aclose()
    await pool.close()


app = FastAPI(title="S19 Dispatch Service", version="1.0.0", lifespan=lifespan)
instrument(app, SERVICE)


def _on_incident_event(evt: dict) -> None:
    """Runs on the Kafka consumer thread; hands work to the asyncio loop."""
    if evt.get("eventType") != "INCIDENT_REPORTED" or evt.get("severity") not in AUTO_DISPATCH_SEVERITIES:
        return
    fut = asyncio.run_coroutine_threadsafe(
        dispatch_incident(DispatchIn(incidentId=evt["incidentId"]), mode="AUTO"), state["loop"])
    try:
        fut.result(timeout=30)
    except HTTPException as e:
        log.info("auto-dispatch skipped", extra={"incidentId": evt["incidentId"], "reason": e.detail})
    except Exception:  # noqa: BLE001
        log.exception("auto-dispatch failed", extra={"incidentId": evt.get("incidentId")})


async def _call(method: str, url: str, **kw) -> httpx.Response:
    try:
        return await state["http"].request(method, url, **kw)
    except httpx.HTTPError as exc:
        raise HTTPException(503, f"dependency unreachable: {url} ({exc})")


async def _read_incident(incident_id: str) -> tuple[dict, dict]:
    r = await _call("GET", f"{COORDINATOR_URL}/api/quorum/kv/{incident_id}")
    if r.status_code == 404:
        raise HTTPException(404, "incident not found")
    if r.status_code != 200:
        raise HTTPException(503, f"quorum read failed: {r.text}")
    body = r.json()
    return body["value"], body["context"]


class QuorumWriteFailed(HTTPException):
    """Write quorum not reached. In a leaderless store the version may still have landed on the replicas that
    answered, so `context` (the clock of that version) is kept for a compensating write."""

    def __init__(self, detail: str, context: Optional[dict]):
        super().__init__(503, detail)
        self.context = context


async def _write_incident(incident_id: str, doc: dict, context: dict) -> dict:
    doc["updatedAt"] = now_ms()
    r = await _call("PUT", f"{COORDINATOR_URL}/api/quorum/kv/{incident_id}",
                    json={"value": doc, "context": context, "clientId": CLIENT_ID})
    if r.status_code != 200:
        try:
            ctx = r.json().get("context")
        except ValueError:
            ctx = None
        raise QuorumWriteFailed(f"quorum write failed: {r.text}", ctx)
    return r.json()


async def _db(sql: str, params=(), one=False):
    async with state["pool"].connection() as conn:
        cur = conn.cursor(row_factory=dict_row)
        await cur.execute(sql, params)
        return await (cur.fetchone() if one else cur.fetchall())


@app.post("/api/dispatch", status_code=201)
async def create_dispatch(body: DispatchIn):
    return await dispatch_incident(body, mode="MANUAL")


async def _best_effort(method: str, url: str, what: str, **kw) -> Optional[httpx.Response]:
    """Dependency call that must not abort a dispatch half-way (returns None on failure)."""
    try:
        r = await state["http"].request(method, url, **kw)
    except httpx.HTTPError as exc:
        log.warning(f"{what} unreachable", extra={"url": url, "error": str(exc)})
        return None
    if r.status_code != 200:
        log.warning(f"{what} returned an error", extra={"url": url, "status": r.status_code, "body": r.text[:300]})
        return None
    return r


async def _compensate(incident_id: str, dispatch_id: str, reason: str) -> dict:
    """Undo a half-finished dispatch: give back resources and volunteers, mark the row FAILED."""
    await _best_effort("POST", f"{REGISTRY_URL}/api/resources/release", "resource-registry",
                       json={"incidentId": incident_id})
    await _best_effort("POST", f"{VOLUNTEER_URL}/api/volunteers/release", "volunteer-coordination",
                       json={"incidentId": incident_id})
    row = await _db(f"UPDATE dispatch_assignments SET status='FAILED', completed_at=now() WHERE id::text=%s "
                    f"RETURNING {COLS}", (dispatch_id,), one=True)
    log.warning("dispatch compensated", extra={"incidentId": incident_id, "dispatchId": dispatch_id, "reason": reason})
    return row


async def dispatch_incident(body: DispatchIn, mode: str) -> dict:
    doc, context = await _read_incident(body.incidentId)
    if doc.get("status") in ("DISPATCHED", "RESOLVED") and mode == "AUTO":
        raise HTTPException(409, f"incident already {doc['status']}")
    severity, region = doc.get("severity", "LOW"), doc["region"]
    try:
        row = await _db(f"INSERT INTO dispatch_assignments(incident_id, region, severity, mode) "
                        f"VALUES (%s,%s,%s,%s) RETURNING {COLS}", (body.incidentId, region, severity, mode), one=True)
    except UniqueViolation:
        raise HTTPException(409, "incident already has an active dispatch")

    qty = body.quantity or RESOURCES_BY_SEVERITY.get(severity, 1)
    try:
        # Resources (Cloud SQL) and volunteers (Firestore) are reserved independently: if one of the two
        # services is unavailable the dispatch still goes ahead with what the other one could provide.
        res = await _best_effort("POST", f"{REGISTRY_URL}/api/resources/reserve", "resource-registry",
                                 json={"incidentId": body.incidentId, "region": region, "kind": body.kind,
                                       "quantity": qty})
        reserved = res.json().get("reserved", []) if res is not None else []
        n_vol = body.volunteers if body.volunteers is not None else VOLUNTEERS_BY_SEVERITY.get(severity, 0)
        volunteers = []
        if n_vol:
            vr = await _best_effort("POST", f"{VOLUNTEER_URL}/api/volunteers/assign", "volunteer-coordination",
                                    json={"incidentId": body.incidentId, "region": region, "count": n_vol})
            volunteers = vr.json().get("assigned", []) if vr is not None else []
    except Exception as exc:  # noqa: BLE001 - never leave an ACTIVE row behind
        await _compensate(body.incidentId, row["id"], f"reservation error: {exc}")
        raise HTTPException(503, f"dispatch aborted: {exc}")

    resource_ids = [r["id"] for r in reserved]
    volunteer_ids = [v["id"] for v in volunteers]
    status = "ACTIVE" if (resource_ids or volunteer_ids) else "FAILED"
    row = await _db(f"UPDATE dispatch_assignments SET resource_ids=%s, volunteer_ids=%s, status=%s, shortfall=%s "
                    f"WHERE id::text=%s RETURNING {COLS}",
                    (resource_ids, volunteer_ids, status, qty - len(resource_ids), row["id"]), one=True)
    if status == "FAILED":
        log.warning("dispatch failed: nothing available", extra={"incidentId": body.incidentId, "region": region})
        return JSONResponse(status_code=409, content={"error": "no resources or volunteers available",
                                                      "dispatch": _json(row)})

    original = json.loads(json.dumps(doc))          # state before this dispatch (for a compensating write)
    doc["status"] = "DISPATCHED"
    doc["assignedResources"] = sorted(set(doc.get("assignedResources", [])) | set(resource_ids))
    doc["assignedVolunteers"] = sorted(set(doc.get("assignedVolunteers", [])) | set(volunteer_ids))
    doc.setdefault("notes", []).append({"text": f"{mode} dispatch {row['id']}: {len(resource_ids)} resources, "
                                                f"{len(volunteer_ids)} volunteers", "author": CLIENT_ID,
                                        "ts": now_ms()})
    try:
        quorum = await _write_incident(body.incidentId, doc, context)
    except HTTPException as exc:
        # The incident store could not record DISPATCHED (write quorum lost): release everything so the
        # resources are not stuck as RESERVED for an incident that does not show them.
        failed = await _compensate(body.incidentId, row["id"], f"incident write failed: {exc.detail}")
        if isinstance(exc, QuorumWriteFailed) and exc.context:
            # The DISPATCHED version may exist on a minority of replicas. Write a version that descends from it
            # (same context) and restores the previous state, so read repair / anti-entropy converge on the
            # rollback instead of spreading the aborted dispatch. Best effort: if this also misses the quorum,
            # it still supersedes the aborted version on every replica it reaches.
            original.setdefault("notes", []).append({"text": f"{mode} dispatch {row['id']} rolled back: "
                                                             f"write quorum lost", "author": CLIENT_ID, "ts": now_ms()})
            try:
                await _write_incident(body.incidentId, original, exc.context)
            except HTTPException:
                log.warning("compensating incident write also missed the quorum", extra={"incidentId": body.incidentId})
        return JSONResponse(status_code=503, content={"error": "incident update failed (quorum); dispatch rolled back",
                                                      "detail": exc.detail, "dispatch": _json(failed)})

    state["kafka"].publish(TOPIC_DISPATCH_EVENTS, body.incidentId, {
        "eventId": uuid.uuid4().hex, "eventType": "DISPATCH_CREATED", "incidentId": body.incidentId,
        "dispatchId": row["id"], "region": region, "severity": severity, "resourceCount": len(resource_ids),
        "volunteerCount": len(volunteer_ids), "mode": mode, "ts": now_ms()})
    alert_id = await run_in_threadpool(state["pubsub"].publish, {
        "alertType": "DISPATCH_ASSIGNED", "incidentId": body.incidentId, "region": region, "severity": severity,
        "volunteerIds": volunteer_ids, "resourceIds": resource_ids,
        "message": f"You have been assigned to incident {body.incidentId} in {region} ({severity})"},
        source=SERVICE)
    log.info("dispatch created", extra={"incidentId": body.incidentId, "dispatchId": row["id"], "mode": mode,
                                        "resources": len(resource_ids), "volunteers": len(volunteer_ids)})
    return {"dispatch": _json(row), "incidentQuorum": {"acks": quorum["acks"], "context": quorum["context"]},
            "alertPublished": alert_id is not None, "alertMessageId": alert_id}


def _json(row: dict) -> dict:
    return {k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in row.items()}


@app.get("/api/dispatch")
async def list_dispatches(status: Optional[str] = Query(default=None, pattern=r"^(ACTIVE|COMPLETED|FAILED)$"),
                          limit: int = Query(default=50, ge=1, le=500)):
    if status:
        rows = await _db(f"SELECT {COLS} FROM dispatch_assignments WHERE status=%s ORDER BY created_at DESC LIMIT %s",
                         (status, limit))
    else:
        rows = await _db(f"SELECT {COLS} FROM dispatch_assignments ORDER BY created_at DESC LIMIT %s", (limit,))
    return {"items": [_json(r) for r in rows]}


@app.get("/api/dispatch/{dispatch_id}")
async def get_dispatch(dispatch_id: str):
    row = await _db(f"SELECT {COLS} FROM dispatch_assignments WHERE id::text=%s", (dispatch_id,), one=True)
    if not row:
        raise HTTPException(404, "dispatch not found")
    return _json(row)


@app.post("/api/dispatch/{dispatch_id}/complete")
async def complete_dispatch(dispatch_id: str):
    row = await _db(f"SELECT {COLS} FROM dispatch_assignments WHERE id::text=%s", (dispatch_id,), one=True)
    if not row:
        raise HTTPException(404, "dispatch not found")
    if row["status"] != "ACTIVE":
        raise HTTPException(409, f"dispatch is {row['status']}")
    inc = row["incident_id"]
    # Releases are idempotent (they only touch ACTIVE reservations/assignments), so a completion that fails
    # half-way can simply be retried; one unavailable dependency does not block the others.
    rel_res = await _best_effort("POST", f"{REGISTRY_URL}/api/resources/release", "resource-registry",
                                 json={"incidentId": inc})
    rel_vol = await _best_effort("POST", f"{VOLUNTEER_URL}/api/volunteers/release", "volunteer-coordination",
                                 json={"incidentId": inc})
    doc, context = await _read_incident(inc)
    doc["status"] = "RESOLVED"
    doc.setdefault("notes", []).append({"text": f"dispatch {dispatch_id} completed", "author": CLIENT_ID,
                                        "ts": now_ms()})
    await _write_incident(inc, doc, context)
    row = await _db(f"UPDATE dispatch_assignments SET status='COMPLETED', completed_at=now() WHERE id::text=%s "
                    f"RETURNING {COLS}", (dispatch_id,), one=True)
    state["kafka"].publish(TOPIC_DISPATCH_EVENTS, inc, {
        "eventId": uuid.uuid4().hex, "eventType": "DISPATCH_COMPLETED", "incidentId": inc, "dispatchId": dispatch_id,
        "region": row["region"], "severity": row["severity"], "resourceCount": 0, "ts": now_ms()})
    return {**_json(row), "resourcesReleased": rel_res.json().get("released") if rel_res is not None else None,
            "volunteersReleased": rel_vol.json().get("released") if rel_vol is not None else None}


@app.get("/api/dispatch/_meta/consumer")
async def consumer_status():
    c = state.get("consumer")
    return {"autoDispatch": AUTO_DISPATCH, "processed": c.processed if c else 0,
            "lastError": c.last_error if c else None}
