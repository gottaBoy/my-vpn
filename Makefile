# my-vpn — VPN domain: NetBird self-hosted + WireGuard fleet mesh
# Prerequisite: my-infra PKI platform (cert-manager + Vault) for TLS certificates.
SHELL := /bin/bash
.DEFAULT_GOAL := help

NETBIRD_DIR := netbird
COMPOSE_FILES_DEV  := -f $(NETBIRD_DIR)/docker-compose.yaml
COMPOSE_FILES_PROD := -f $(NETBIRD_DIR)/docker-compose.yaml -f $(NETBIRD_DIR)/docker-compose.prod.yaml

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: cert-export
cert-export: ## Export netbird TLS cert from K8s Secret → netbird/certs/
	bash $(NETBIRD_DIR)/cert-export.sh

.PHONY: cert-verify
cert-verify: ## Verify the exported TLS cert
	@echo "==> Certificate subject/issuer/dates:"
	@openssl x509 -in $(NETBIRD_DIR)/certs/tls.crt -noout -subject -issuer -dates 2>/dev/null || \
		{ echo "ERROR: cert not found. Run 'make cert-export' first."; exit 1; }
	@echo ""
	@echo "==> SANs:"
	@openssl x509 -in $(NETBIRD_DIR)/certs/tls.crt -noout -ext subjectAltName 2>/dev/null

.PHONY: netbird-up
netbird-up: cert-export ## Start NetBird (dev mode, local PostgreSQL)
	docker compose $(COMPOSE_FILES_DEV) up -d
	@echo "==> Waiting for services..."
	@sleep 10
	docker compose $(COMPOSE_FILES_DEV) ps

.PHONY: netbird-down
netbird-down: ## Stop NetBird (dev)
	docker compose $(COMPOSE_FILES_DEV) down

.PHONY: netbird-logs
netbird-logs: ## Tail NetBird logs
	docker compose $(COMPOSE_FILES_DEV) logs -f

.PHONY: netbird-status
netbird-status: ## Check NetBird API health
	@curl -sk https://netbird.internal/api/status 2>/dev/null || \
		curl -sk https://localhost/api/status 2>/dev/null || \
		echo "NetBird not reachable. Is it running? (make netbird-up)"

.PHONY: setup-key-create
setup-key-create: ## Create a reusable Setup Key for vehicle registration
	@echo "Creating reusable setup key (valid 30 days, 1000 uses)..."
	@echo "Run this after logging into Dashboard at http://localhost"
	@echo ""
	@echo "Via API (requires admin token):"
	@echo '  curl -X POST https://netbird.internal/api/setup-keys \'
	@echo '    -H "Authorization: Token $$NETBIRD_TOKEN" \'
	@echo '    -H "Content-Type: application/json" \'
	@echo '    -d '"'"'{"name":"factory-fleet","type":"reusable","usage_limit":1000,"expires_in":2592000}'"'"

.PHONY: clean
clean: netbird-down ## Stop NetBird and remove local certs
	rm -rf $(NETBIRD_DIR)/certs

## ---------- production targets ----------

.PHONY: netbird-up-prod
netbird-up-prod: cert-export ## Start NetBird in production mode (with prod overlay)
	docker compose $(COMPOSE_FILES_PROD) up -d
	@echo "==> Waiting for services..."
	@sleep 15
	docker compose $(COMPOSE_FILES_PROD) ps

.PHONY: netbird-down-prod
netbird-down-prod: ## Stop NetBird (production)
	docker compose $(COMPOSE_FILES_PROD) down

.PHONY: cert-renew-test
cert-renew-test: ## Dry-run cert renewal (does not restart services)
	@echo "==> Testing cert renewal flow..."
	@bash $(NETBIRD_DIR)/cert-renew-cron.sh || echo "(expected to fail if not on EC2)"

.PHONY: install-systemd
install-systemd: ## Install systemd unit (requires sudo, for EC2)
	@echo "==> Installing netbird.service..."
	sudo cp $(NETBIRD_DIR)/netbird.service /etc/systemd/system/
	sudo systemctl daemon-reload
	sudo systemctl enable netbird
	@echo "==> Installed. Run: sudo systemctl start netbird"
