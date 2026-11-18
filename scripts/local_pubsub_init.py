"""Local only: keep the `alert-requests` topic and the push subscription to the local Alert Service
present in the Pub/Sub emulator (on GCP the equivalent is the Eventarc trigger created by Terraform).

The emulator keeps topics and subscriptions in memory only: whenever the emulator container restarts
(Docker Desktop restart, `docker compose up` recreating it, a crash) they are gone, and every publish
from Incident Intake / Dispatch fails with NotFound. A one-shot init cannot cover that, so this script
runs as a small reconciler:

  * every 15 s it checks that the topic and the subscription exist (and that the push endpoint is right)
    and re-creates whatever is missing;
  * while both exist it keeps the marker file /tmp/pubsub-ready, which is the container's healthcheck;
    the marker is removed as soon as the emulator is unreachable or a re-create fails;
  * `--once` performs a single reconciliation and exits 0 on success, 1 on failure (no silent success).

SIGTERM (docker compose stop/down) exits immediately with status 0.
"""
import os
import pathlib
import signal
import sys
import time

from google.api_core import exceptions as gexc
from google.cloud import pubsub_v1

PROJECT = os.getenv("GCP_PROJECT_ID", "s19-local")
TOPIC = os.getenv("ALERT_TOPIC", "alert-requests")
SUBSCRIPTION = os.getenv("ALERT_SUBSCRIPTION", "alert-service-push")
PUSH_ENDPOINT = os.getenv("PUSH_ENDPOINT", "http://alert-service:8080/")
READY = pathlib.Path(os.getenv("READY_FILE", "/tmp/pubsub-ready"))
INTERVAL_S = float(os.getenv("RECONCILE_INTERVAL_S", "15"))
RPC_TIMEOUT_S = 10.0   # per call; retry=None: this script retries itself, the library must not block for 60 s

signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))   # PID 1 in the container: exit promptly on stop

pub, sub = pubsub_v1.PublisherClient(), pubsub_v1.SubscriberClient()
topic_path = pub.topic_path(PROJECT, TOPIC)
sub_path = sub.subscription_path(PROJECT, SUBSCRIPTION)


def ensure() -> list:
    """Create the topic / subscription if missing. Returns what had to be (re)created."""
    changed = []
    try:
        pub.get_topic(request={"topic": topic_path}, timeout=RPC_TIMEOUT_S, retry=None)
    except gexc.NotFound:
        try:
            pub.create_topic(request={"name": topic_path}, timeout=RPC_TIMEOUT_S, retry=None)
        except gexc.AlreadyExists:
            pass
        changed.append("topic")
    try:
        s = sub.get_subscription(request={"subscription": sub_path}, timeout=RPC_TIMEOUT_S, retry=None)
        if s.push_config.push_endpoint != PUSH_ENDPOINT:
            sub.modify_push_config(request={"subscription": sub_path,
                                            "push_config": {"push_endpoint": PUSH_ENDPOINT}},
                                   timeout=RPC_TIMEOUT_S, retry=None)
            changed.append("push-endpoint")
    except gexc.NotFound:
        try:
            sub.create_subscription(request={"name": sub_path, "topic": topic_path,
                                             "push_config": {"push_endpoint": PUSH_ENDPOINT}},
                                    timeout=RPC_TIMEOUT_S, retry=None)
        except gexc.AlreadyExists:
            pass
        changed.append("subscription")
    return changed


def main() -> int:
    once = "--once" in sys.argv
    deadline = time.time() + 180          # --once: give a cold emulator up to 3 minutes
    READY.unlink(missing_ok=True)
    while True:
        try:
            changed = ensure()
            if changed or not READY.exists():
                print(f"pubsub emulator initialised: {topic_path} -> {sub_path} -> {PUSH_ENDPOINT}"
                      + (f" (created: {', '.join(changed)})" if changed else " (already present)"), flush=True)
            READY.touch()
            if once:
                return 0
        except Exception as exc:  # noqa: BLE001 - emulator down/starting: report, mark unhealthy, retry
            if READY.exists():
                print(f"pubsub emulator lost ({type(exc).__name__}): marking unhealthy and retrying", flush=True)
            else:
                print(f"waiting for pubsub emulator: {type(exc).__name__}: {str(exc)[:160]}", flush=True)
            READY.unlink(missing_ok=True)
            if once and time.time() > deadline:
                print("pubsub emulator could not be initialised", file=sys.stderr, flush=True)
                return 1
        time.sleep(INTERVAL_S if READY.exists() else 2)


if __name__ == "__main__":
    sys.exit(main())
