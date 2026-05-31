.PHONY: setup migrate dev-up dev-down dev-logs test build-image setup-hermes hermes-bootstrap hermes-image hermes-reprovision clean lint help bruno-regen

# Variables
DOCKER_COMPOSE = docker compose
SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## One-click developer setup (./setup.sh)
	./setup.sh

migrate: ## Run Fluent migrations against the local database
	swift run App migrate

dev-up: ## Start all services for local development
	$(DOCKER_COMPOSE) up -d postgres hermes jaeger
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

hermes-bootstrap: ## Generate HERMES_API_KEY in .env if missing (HER-254)
	@if [ ! -f .env ]; then \
		echo "no .env file — copy .env.example to .env first"; exit 1; \
	fi
	@if grep -qE '^HERMES_API_KEY=.+' .env; then \
		echo "HERMES_API_KEY already set in .env (skipping)"; \
	else \
		key=$$(openssl rand -hex 32); \
		if grep -qE '^HERMES_API_KEY=$$' .env; then \
			sed -i.bak "s|^HERMES_API_KEY=$$|HERMES_API_KEY=$$key|" .env && rm -f .env.bak; \
		else \
			printf '\n# HER-254 auto-generated\nHERMES_API_KEY=%s\n' "$$key" >> .env; \
		fi; \
		echo "wrote HERMES_API_KEY to .env"; \
	fi

clean: ## Remove build artifacts and data
	rm -rf .build
	rm -rf data/postgres18 data/redis data/hermes

lint:
	swiftformat --lint .

bruno-regen: ## Regenerate the LuminaVaultCollection Bruno collection from Sources/AppAPI/openapi.yaml (HER-229)
	./scripts/generate-bruno.sh

hermes-skills-rebuild: ## Rebuild the Hermes image with the current hermes-skills/ tree baked in (HER-276)
	docker compose build hermes
	docker compose up -d hermes
	@echo "✓ hermes restarted with refreshed bundled skills"
	@echo "  verify with: curl -s http://localhost:8080/v1/skills | jq '.skills[].name'"

hermes-image: ## Build the Mnemosyne-baked Hermes image (tag used by central + per-tenant runs) (HER-XXX)
	docker build -f docker/hermes.Dockerfile -t luminavault-hermes:local .
	@echo "✓ built luminavault-hermes:local (kb-* skills + mnemosyne memory MCP)"
	@echo "  central: docker compose up -d hermes   per-tenant: HERMES_PER_TENANT_IMAGE=luminavault-hermes:local"
	@echo "  upgrade existing tenants: make hermes-reprovision (admin)"

# Bulk-reprovision every per-tenant Hermes container onto the current image
# via POST /v1/system/hermes/reprovision. Gated by BOTH the owner JWT and the
# shared admin secret. Override the connection vars as needed:
#   make hermes-reprovision LV_JWT=<session-jwt> LV_ADMIN_TOKEN=<admin.token> \
#                           LV_BASE_URL=http://localhost:8080
LV_BASE_URL ?= http://localhost:8080
LV_JWT ?=
LV_ADMIN_TOKEN ?=

hermes-reprovision: ## Reprovision all per-tenant Hermes containers onto the current image (admin; needs LV_JWT + LV_ADMIN_TOKEN)
	@if [ -z "$(LV_JWT)" ] || [ -z "$(LV_ADMIN_TOKEN)" ]; then \
		echo "error: set LV_JWT (owner session token) and LV_ADMIN_TOKEN (admin.token)" >&2; \
		echo "  make hermes-reprovision LV_JWT=... LV_ADMIN_TOKEN=... [LV_BASE_URL=...]" >&2; \
		exit 1; \
	fi
	@echo "→ reprovisioning per-tenant Hermes containers via $(LV_BASE_URL)"
	@curl -fsS -X POST "$(LV_BASE_URL)/v1/system/hermes/reprovision" \
		-H "Authorization: Bearer $(LV_JWT)" \
		-H "X-Admin-Token: $(LV_ADMIN_TOKEN)" \
		-H "Content-Type: application/json" \
		&& echo "" \
		&& echo "✓ reprovision complete (see \"reprovisioned\" count above)"
