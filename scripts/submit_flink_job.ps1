<#
.SYNOPSIS
  Build the Flink job, upload it to GCS and run it on the Dataproc cluster (Flink on YARN).
  Prerequisites: dataproc_enabled=true applied in infra/terraform/01-foundation; Kafka running on GKE.
.EXAMPLE
  .\scripts\submit_flink_job.ps1 -ProjectId s19-disaster-123456
#>
param(
  [Parameter(Mandatory = $true)][string]$ProjectId,
  [string]$Region = "us-central1",
  [string]$Cluster = "s19-flink",
  [string]$KafkaBootstrap = "10.10.0.100:9094"
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$bucket = "$ProjectId-s19-data"
$jar = Join-Path $root "flink/situation-analytics-flink/target/situation-analytics-flink-1.0.0.jar"

& (Join-Path $PSScriptRoot "build_flink_jar.ps1")
gcloud storage cp $jar "gs://$bucket/dataproc/jobs/situation-analytics-flink.jar" --project $ProjectId
if ($LASTEXITCODE -ne 0) { throw "upload failed" }

# Stop a previous run so only one copy consumes the topics
$active = gcloud dataproc jobs list --project $ProjectId --region $Region --cluster $Cluster --state-filter active --format "value(reference.jobId)"
foreach ($id in ($active -split "`n" | Where-Object { $_ })) {
  Write-Host "killing previous job $id"; gcloud dataproc jobs kill $id --project $ProjectId --region $Region --quiet
}

gcloud dataproc jobs submit flink --project $ProjectId --region $Region --cluster $Cluster `
  --jar "gs://$bucket/dataproc/jobs/situation-analytics-flink.jar" `
  --labels "app=s19,component=situation-analytics" --async `
  '--' --bootstrap $KafkaBootstrap --input-topics "incident-events,dispatch-events,consistency-events" `
     --output-topic incident-aggregates --window-seconds 60 `
     --checkpoint-dir "hdfs:///flink/checkpoints/situation-analytics"
if ($LASTEXITCODE -ne 0) { throw "job submission failed" }
Write-Host "Submitted. Check: gcloud dataproc jobs list --region $Region --cluster $Cluster" -ForegroundColor Green
Write-Host "Flink UI: Console > Dataproc > Clusters > $Cluster > Web Interfaces > Flink" -ForegroundColor Green
