#!/usr/bin/env bash
# Build the Flink job, upload it to GCS and run it on the Dataproc cluster (Flink on YARN).
# Prerequisites: dataproc_enabled=true applied in infra/terraform/01-foundation, Kafka running on GKE.
# Usage: scripts/submit_flink_job.sh <PROJECT_ID> [REGION]
set -euo pipefail
PROJECT_ID="${1:?project id}"
REGION="${2:-us-central1}"
CLUSTER="s19-flink"
BUCKET="${PROJECT_ID}-s19-data"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JAR="$ROOT/flink/situation-analytics-flink/target/situation-analytics-flink-1.0.0.jar"

if command -v mvn >/dev/null; then
  (cd "$ROOT/flink/situation-analytics-flink" && mvn -q -DskipTests package)
else   # no local Maven: build inside the official Maven image
  docker run --rm -v "$ROOT/flink/situation-analytics-flink:/w" -w /w maven:3.9.9-eclipse-temurin-11 mvn -q -B -DskipTests package
fi
gcloud storage cp "$JAR" "gs://${BUCKET}/dataproc/jobs/situation-analytics-flink.jar"

# Stop a previous run of the job (if any) so only one copy consumes the topics
for id in $(gcloud dataproc jobs list --project "$PROJECT_ID" --region "$REGION" --cluster "$CLUSTER" \
              --state-filter=active --format="value(reference.jobId)"); do
  echo "killing previous job $id"; gcloud dataproc jobs kill "$id" --project "$PROJECT_ID" --region "$REGION" --quiet
done

# Single-node e2-standard-2: 2 YARN vCores with CPU scheduling on; the JobManager takes 1, so the
# TaskManager must ask for 1 (default = slots = 2 can never be granted). Parallelism is 1.
gcloud dataproc jobs submit flink \
  --project "$PROJECT_ID" --region "$REGION" --cluster "$CLUSTER" \
  --jar "gs://${BUCKET}/dataproc/jobs/situation-analytics-flink.jar" \
  --properties "taskmanager.numberOfTaskSlots=1,yarn.containers.vcores=1" \
  --labels app=s19,component=situation-analytics \
  --async \
  -- --bootstrap 10.10.0.100:9094 \
     --input-topics incident-events,dispatch-events,consistency-events \
     --output-topic incident-aggregates \
     --window-seconds 60 \
     --checkpoint-dir hdfs:///flink/checkpoints/situation-analytics

echo "Submitted. Check: gcloud dataproc jobs list --region $REGION --cluster $CLUSTER"
echo "Flink UI: Console > Dataproc > Clusters > $CLUSTER > Web Interfaces > Flink"
