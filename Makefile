# Convenience targets. Set PROJECT_ID once:  export PROJECT_ID=s19-disaster-123456
PROJECT_ID ?= $(shell gcloud config get-value project 2>/dev/null)
REGION     ?= us-central1
ZONE       ?= us-central1-a
TF1 = infra/terraform/01-foundation
TF2 = infra/terraform/02-platform
TFSTATE = $(PROJECT_ID)-s19-tfstate

.PHONY: proto test e2e local-up local-down flink-reporter-jar bootstrap foundation platform images \
        kubeconfig flink-job ip seed consistency load smoke evidence pause resume down-all

# Linux/macOS convenience targets. On Windows use the PowerShell commands in README.md instead.
proto:            ## generate gRPC stubs
	python3 scripts/gen_proto.py
test: proto       ## unit + integration tests of the Dynamo layer
	python3 -m pytest -q tests/
e2e:              ## end-to-end check through the local gateway (after make local-up)
	BASE_URL=http://localhost:8080 python3 scripts/e2e_check.py

local-up:         ## whole system on your laptop (free)
	docker compose up --build -d
local-down:
	docker compose down -v

flink-reporter-jar: ## Flink 1.17 Prometheus reporter (uploaded to GCS by Terraform for Dataproc)
	mkdir -p flink/lib && curl -fL -o flink/lib/flink-metrics-prometheus-1.17.0.jar \
	  https://repo1.maven.org/maven2/org/apache/flink/flink-metrics-prometheus/1.17.0/flink-metrics-prometheus-1.17.0.jar

bootstrap:        ## state bucket (once)
	cd infra/terraform/00-bootstrap && terraform init && terraform apply -var project_id=$(PROJECT_ID)
foundation:       ## network, GKE, Cloud SQL, Firestore, GCS, Pub/Sub, AR, IAM, function, (Dataproc)
	cd $(TF1) && terraform init -backend-config="bucket=$(TFSTATE)" && terraform apply
platform: kubeconfig ## namespaces, config, secrets, Argo CD + root app
	cd $(TF2) && terraform init -backend-config="bucket=$(TFSTATE)" && terraform apply
kubeconfig:
	gcloud container clusters get-credentials s19-gke --zone $(ZONE) --project $(PROJECT_ID)
images:           ## build + push all images and pin the tag in the GitOps overlay
	bash scripts/build_push.sh $(PROJECT_ID)
flink-job:        ## build + submit the Flink job to Dataproc
	bash scripts/submit_flink_job.sh $(PROJECT_ID) $(REGION)

ip:
	@cd $(TF1) && terraform output -raw ingress_ip
seed:             ## demo volunteers (resources are seeded by the registry migration)
	curl -s -X POST "http://$$(cd $(TF1) && terraform output -raw ingress_ip)/api/volunteers/_seed?perRegion=8"; echo
consistency:      ## Dynamo consistency test-suite against the public URL
	BASE_URL=http://$$(cd $(TF1) && terraform output -raw ingress_ip) \
	ADMIN_TOKEN=$$(cd $(TF2) && terraform output -raw admin_token) python3 scripts/consistency_test.py \
	| tee docs/evidence/consistency-test-gke.txt
smoke:
	k6 run -e BASE_URL=http://$$(cd $(TF1) && terraform output -raw ingress_ip) loadtest/k6/smoke.js
load:             ## sustained load -> HPA scale-out (run `make evidence` in another terminal)
	mkdir -p loadtest/results && k6 run -e BASE_URL=http://$$(cd $(TF1) && terraform output -raw ingress_ip) \
	  --summary-export loadtest/results/summary.json loadtest/k6/hpa-load.js | tee docs/evidence/k6-hpa-run.txt
evidence:         ## record HPA + pod scaling while the load test runs
	bash scripts/record_hpa.sh

pause:            ## stop paying for compute between work sessions (keeps data + images)
	bash scripts/teardown_k8s.sh $(PROJECT_ID)
	cd $(TF2) && terraform destroy -auto-approve
	cd $(TF1) && terraform apply -auto-approve -var gke_enabled=false -var cloudsql_running=false -var dataproc_enabled=false
resume:
	cd $(TF1) && terraform apply -auto-approve -var gke_enabled=true -var cloudsql_running=true
	$(MAKE) platform
down-all:         ## FINAL cleanup after grading: delete everything
	-bash scripts/teardown_k8s.sh $(PROJECT_ID)
	-cd $(TF2) && terraform destroy -auto-approve
	cd $(TF1) && terraform destroy -auto-approve
