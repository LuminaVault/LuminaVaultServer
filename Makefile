.PHONY: dev-up dev-down dev-logs test build-image setup-hermes help

# Variables
DOCKER_COMPOSE = docker compose
SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

dev-up: ## Start all services for local development
	$(DOCKER_COMPOSE) up -d postgres redis hermes jaeger
	@echo "Waiting for postgres..."
	@until $(DOCKER_COMPOSE) exec postgres pg_isready -U hermes -d hermes_db > /dev/null 2>&1; do sleep 1; done
	$(DOCKER_COMPOSE) up --build hummingbird

dev-down: ## Stop local services
	$(DOCKER_COMPOSE) down

dev-logs: ## View logs for local services
	$(DOCKER_COMPOSE) logs -f

test: ## Run Swift tests locally using Docker
	$(DOCKER_COMPOSE) run --rm hummingbird swift test --parallel

build-image: ## Build the container image using the Swift Container Plugin
	swift package --swift-sdk x86_64-swift-linux-musl build-container-image --repository ghcr.io/fernando-idwell/obsidian-claudebrain-server --tag latest

setup-hermes: ## Run the Hermes setup wizard (one-time, interactive)
	mkdir -p data/hermes
	docker run -it --rm \
		-v "$$(pwd)/data/hermes:/opt/data" \
		nousresearch/hermes-agent setup

clean: ## Remove build artifacts and data
	rm -rf .build
	rm -rf data/postgres data/redis data/hermes
