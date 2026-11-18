"""Local only: create the alert-requests topic and a push subscription to the local alert function."""
import time

from google.api_core.exceptions import AlreadyExists
from google.cloud import pubsub_v1

PROJECT = "s19-local"
pub, sub = pubsub_v1.PublisherClient(), pubsub_v1.SubscriberClient()
topic = pub.topic_path(PROJECT, "alert-requests")
subscription = sub.subscription_path(PROJECT, "alert-service-push")
for attempt in range(30):
    try:
        try:
            pub.create_topic(request={"name": topic})
        except AlreadyExists:
            pass
        try:
            sub.create_subscription(request={
                "name": subscription, "topic": topic,
                "push_config": {"push_endpoint": "http://alert-service:8080/"}})
        except AlreadyExists:
            pass
        print("pubsub emulator initialised:", topic, "->", subscription)
        break
    except Exception as exc:  # emulator still starting
        print("waiting for pubsub emulator:", exc)
        time.sleep(2)
