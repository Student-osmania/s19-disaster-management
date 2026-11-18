<#
.SYNOPSIS
  Build (and optionally test) the Flink job jar inside the official Maven Docker image - no Java/Maven on Windows needed.
.EXAMPLE
  .\scripts\build_flink_jar.ps1            # package -> flink/situation-analytics-flink/target/situation-analytics-flink-1.0.0.jar
  .\scripts\build_flink_jar.ps1 -RunTests  # also runs the MiniCluster pipeline test (mvn test)
#>
param([switch]$RunTests)
$ErrorActionPreference = 'Stop'
$job = Join-Path (Split-Path -Parent $PSScriptRoot) "flink/situation-analytics-flink"
$goal = if ($RunTests) { "package" } else { "-DskipTests package" }
docker volume create s19-m2-cache | Out-Null
docker run --rm -v "${job}:/w" -v "s19-m2-cache:/root/.m2" -w /w maven:3.9.9-eclipse-temurin-11 sh -c "mvn -q -B $goal"
if ($LASTEXITCODE -ne 0) { throw "maven build failed" }
Get-Item (Join-Path $job "target/situation-analytics-flink-1.0.0.jar") | Select-Object -Property @('Name', 'Length', 'LastWriteTime')
