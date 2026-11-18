"""Alert Service - asynchronous, event-driven serverless function (Cloud Run functions, gen2).

Trigger : Pub/Sub topic `alert-requests` (Eventarc), published by Incident Intake (CRITICAL
          incidents) and Dispatch (assignment notices).
Work    : 1. idempotency check on the Pub/Sub message id (redeliveries are ignored)
          2. resolve recipients: explicitly listed volunteers, or available volunteers in the region
          3. deliver the update on every channel that applies to the alert's severity
          4. persist the alert + the real per-delivery outcome in Firestore `alerts/{messageId}`

Delivery channels (all real writes / calls - nothing is faked):
  inbox     -> Firestore document notifications/{volunteerId}/inbox/{messageId}
               (read by volunteers through GET /api/volunteers/{id}/notifications)
  broadcast -> Firestore document broadcasts/{region}/messages/{messageId}
               (regional emergency bulletin, GET /api/volunteers/broadcasts/{region})
  webhook   -> HTTPS POST of the alert JSON to ALERT_WEBHOOK_URL (optional; e.g. a Slack/Discord
               incoming webhook or an ntfy.sh topic). Only used when the variable is set.
A delivery is recorded as DELIVERED only when the write/POST actually succeeded, otherwise FAILED
with the error text.

Retries : Firestore errors propagate, so Pub/Sub redelivers the message (retry policy set in Terraform).
          The idempotency record is written last, so a redelivery re-runs only unfinished work.
"""
import base64
import json
import logging
import os
import time
import urllib.error
import urllib.request

import functions_framework
from google.cloud import firestore

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("alert-service")

PROJECT_ID = os.getenv("GCP_PROJECT_ID") or None
DATABASE = os.getenv("FIRESTORE_DATABASE", "(default)")
MAX_RECIPIENTS = int(os.getenv("MAX_RECIPIENTS", "25"))
WEBHOOK_URL = os.getenv("ALERT_WEBHOOK_URL", "").strip()
WEBHOOK_TIMEOUT_S = float(os.getenv("ALERT_WEBHOOK_TIMEOUT_S", "5"))
CHANNELS_BY_SEVERITY = {"CRITICAL": ["inbox", "broadcast", "webhook"], "HIGH": ["inbox", "webhook"],
                        "MEDIUM": ["inbox"], "LOW": ["inbox"]}

_db = None


def db():
    global _db
    if _db is None:
        _db = firestore.Client(project=PROJECT_ID, database=DATABASE)
    return _db


def jlog(severity: str, message: str, **fields):
    # Cloud Run functions forward stdout JSON to Cloud Logging as jsonPayload.
    print(json.dumps({"severity": severity, "message": message, "service": "alert-service", **fields}), flush=True)


def channels_for(severity: str) -> list:
    chans = CHANNELS_BY_SEVERITY.get(severity, ["inbox"])
    return [c for c in chans if c != "webhook" or WEBHOOK_URL]


def resolve_recipients(alert: dict) -> list:
    ids = alert.get("volunteerIds") or []
    if ids:
        return ids[:MAX_RECIPIENTS]
    q = (db().collection("volunteers")
         .where(filter=firestore.FieldFilter("region", "==", alert.get("region", "")))
         .where(filter=firestore.FieldFilter("available", "==", True))
         .limit(MAX_RECIPIENTS))
    return [d.id for d in q.stream()]


def _record(target: str, channel: str, ok: bool, error: str = "") -> dict:
    rec = {"target": target, "channel": channel, "status": "DELIVERED" if ok else "FAILED",
           "ts": int(time.time() * 1000)}
    if error:
        rec["error"] = error[:300]
    return rec


def deliver_inbox(volunteer_id: str, message_id: str, alert: dict) -> dict:
    """Write the notification into the volunteer's inbox (idempotent: document id = message id)."""
    db().collection("notifications").document(volunteer_id).collection("inbox").document(message_id).set({
        "alertId": message_id, "alertType": alert.get("alertType"), "incidentId": alert.get("incidentId"),
        "region": alert.get("region"), "severity": alert.get("severity"), "message": alert.get("message", ""),
        "read": False, "createdAt": int(time.time() * 1000)})
    return _record(volunteer_id, "inbox", True)


def deliver_broadcast(region: str, message_id: str, alert: dict) -> dict:
    db().collection("broadcasts").document(region).collection("messages").document(message_id).set({
        "alertId": message_id, "alertType": alert.get("alertType"), "incidentId": alert.get("incidentId"),
        "severity": alert.get("severity"), "message": alert.get("message", ""),
        "createdAt": int(time.time() * 1000)})
    return _record(f"region:{region}", "broadcast", True)


def deliver_webhook(message_id: str, alert: dict) -> dict:
    payload = {"text": f"[{alert.get('severity')}] {alert.get('message', '')}",
               "content": f"[{alert.get('severity')}] {alert.get('message', '')}",
               "alertId": message_id, **{k: alert.get(k) for k in ("alertType", "incidentId", "region", "severity")}}
    req = urllib.request.Request(WEBHOOK_URL, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "User-Agent": "s19-alert-service"})
    try:
        with urllib.request.urlopen(req, timeout=WEBHOOK_TIMEOUT_S) as resp:
            ok = 200 <= resp.status < 300
            return _record("webhook", "webhook", ok, "" if ok else f"HTTP {resp.status}")
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return _record("webhook", "webhook", False, str(exc))


def process_alert(message_id: str, alert: dict) -> dict:
    """Core logic (also called directly by the integration test). Returns the stored alert record."""
    ref = db().collection("alerts").document(message_id)
    existing = ref.get()
    if existing.exists:
        jlog("INFO", "duplicate delivery ignored", messageId=message_id)
        return existing.to_dict()

    severity = alert.get("severity", "LOW")
    region = alert.get("region") or "unknown"
    channels = channels_for(severity)
    started = time.time()
    deliveries = []
    recipients = resolve_recipients(alert) if "inbox" in channels else []
    for vid in recipients:
        deliveries.append(deliver_inbox(vid, message_id, alert))
    if "broadcast" in channels:
        deliveries.append(deliver_broadcast(region, message_id, alert))
    if "webhook" in channels:
        deliveries.append(deliver_webhook(message_id, alert))
    for d in deliveries:
        jlog("NOTICE" if d["status"] == "DELIVERED" else "WARNING", "notification " + d["status"].lower(),
             channel=d["channel"], target=d["target"], incidentId=alert.get("incidentId"),
             alertType=alert.get("alertType"), messageId=message_id, error=d.get("error"))

    record = {
        "alertId": message_id, "alertType": alert.get("alertType"), "incidentId": alert.get("incidentId"),
        "region": region, "severity": severity, "message": alert.get("message", ""),
        "channels": channels, "recipientCount": len(recipients),
        "delivered": sum(1 for d in deliveries if d["status"] == "DELIVERED"),
        "failed": sum(1 for d in deliveries if d["status"] == "FAILED"),
        "deliveries": deliveries[:100], "createdAt": int(time.time() * 1000),
        "processingMs": int((time.time() - started) * 1000),
    }
    ref.set(record)
    jlog("INFO", "alert processed", messageId=message_id, incidentId=alert.get("incidentId"),
         delivered=record["delivered"], failed=record["failed"], severity=severity)
    return record


@functions_framework.cloud_event
def handle_alert(cloud_event):
    message = cloud_event.data.get("message", {})
    message_id = message.get("messageId") or message.get("message_id") or cloud_event["id"]
    try:
        alert = json.loads(base64.b64decode(message.get("data", "")).decode() or "{}")
    except (ValueError, TypeError):
        jlog("ERROR", "malformed alert payload - acknowledged and dropped", messageId=message_id)
        return  # returning normally acks the message: retrying a malformed payload cannot succeed
    process_alert(str(message_id), alert)
