.DEFAULT_GOAL := help
.PHONY: help lint test test-scripts smoke secrets tls up down ps logs backup drill

help: ## List the targets
	@awk -F':.*## ' '/^[a-z-]+:.*## / { printf "  %-13s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

lint: ## ruff check and format check (pip install -r service/requirements-dev.txt first)
	ruff check service
	ruff format --check service

test: ## Python tests; set TEST_DATABASE_URL to include the Postgres integration tests
	cd service && pytest -q

test-scripts: ## Deploy and rollback logic against a fake docker compose (no Docker needed)
	bash scripts/tests/test-deploy-flow.sh

smoke: ## Build and exercise the whole stack in a throwaway copy (needs Docker)
	./scripts/smoke-test.sh

secrets: ## Generate secrets/db_password and secrets/grafana_admin_password
	./scripts/gen-secrets.sh

tls: ## Placeholder TLS certificate so Nginx can start
	./scripts/init-tls.sh selfsigned

up: ## Build and deploy the stack locally (needs .env, secrets and a certificate)
	DEPLOY_BUILD=1 ./scripts/deploy.sh local-$$(date +%Y%m%d%H%M%S)

down: ## Stop the stack; data volumes are kept
	docker compose down

ps: ## Container status
	docker compose ps

logs: ## Follow logs, for one service with: make logs s=api
	docker compose logs -f --tail 100 $(s)

backup: ## Take a database backup now
	./scripts/backup.sh

drill: ## Restore the newest backup into a scratch database and check it
	./scripts/restore-drill.sh
