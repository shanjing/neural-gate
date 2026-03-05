.PHONY: local-up local-native gke-deploy smoke-test benchmark clean

MODELS_STORE ?= /Volumes/External/neural-gate-models
MODELS_LINK  ?= $(HOME)/.models

local-up: ## krunkit start + deploy base + local-krunkit overlay
	@test -d $(MODELS_STORE) || { echo "Error: $(MODELS_STORE) not found. Is the external volume mounted?"; exit 1; }
	@test -L $(MODELS_LINK) || ln -sfn $(MODELS_STORE) $(MODELS_LINK)
	minikube start --driver=krunkit --nodes=3 --cpus=max --memory=36g --mount-string $(MODELS_STORE):/mnt/models --profile=inference
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -f k8s/base/device-plugin/
	kubectl apply -k k8s/overlays/local-krunkit/

local-native: ## docker driver + deploy base + native overlay
	@docker info >/dev/null 2>&1 || { echo "Error: Docker is not running. Start Docker Desktop first."; exit 1; }
	minikube start --driver=docker --profile=inference
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -k k8s/overlays/local-native/

gke-deploy: ## deploy base + gke-production overlay
	kubectl apply -f k8s/base/namespace.yaml
	kubectl apply -k k8s/overlays/gke-production/

smoke-test: ## health + completions + model list
	bash scripts/smoke-test.sh

benchmark: ## throughput measurement
	bash scripts/benchmark.sh

clean: ## tear down local cluster
	minikube delete --profile=inference
