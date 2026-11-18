#!/usr/bin/env bash
# Dataproc initialization action: make sure Flink's Prometheus metric reporter plugin is installed.
# The jar is uploaded to gs://<bucket>/dataproc/lib/ by Terraform (no internet needed: internal-IP VM).
set -euo pipefail
FLINK_HOME=/usr/lib/flink
PLUGIN_DIR="$FLINK_HOME/plugins/metrics-prometheus"
METADATA="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
BUCKET=$(curl -s -H "Metadata-Flavor: Google" "$METADATA/dataproc-bucket")

if ls "$PLUGIN_DIR"/flink-metrics-prometheus-*.jar >/dev/null 2>&1; then
  echo "Prometheus reporter already present"
elif ls "$FLINK_HOME"/opt/flink-metrics-prometheus-*.jar >/dev/null 2>&1; then
  mkdir -p "$PLUGIN_DIR" && cp "$FLINK_HOME"/opt/flink-metrics-prometheus-*.jar "$PLUGIN_DIR"/
  echo "Prometheus reporter copied from opt/"
else
  mkdir -p "$PLUGIN_DIR"
  gsutil cp "gs://${BUCKET}/dataproc/lib/flink-metrics-prometheus-1.17.0.jar" "$PLUGIN_DIR"/ \
    && echo "Prometheus reporter installed from GCS" \
    || echo "WARNING: reporter jar not found in GCS - Flink metrics will be missing from Prometheus"
fi
