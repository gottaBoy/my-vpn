# my-vpn — VPN domain: NetBird self-hosted + WireGuard fleet mesh
# Prerequisite: my-infra PKI platform (cert-manager + Vault) for TLS certificates.
SHELL := /bin/bash
.DEFAULT_GOAL := help

NETBIRD_DIR := netbird
COMPOSE_FILES_DEV   := -f $(NETBIRD_DIR)/docker-compose.yaml
COMPOSE_FILES_TEST  := -f $(NETBIRD_DIR)/docker-compose.yaml -f $(NETBIRD_DIR)/docker-compose.test.yaml
COMPOSE_FILES_PROD  := -f $(NETBIRD_DIR)/docker-compose.yaml -f $(NETBIRD_DIR)/docker-compose.prod.yaml

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

.PHONY: netbird-up-test
netbird-up-test: cert-export ## Start NetBird in macOS test mode (Caddy reverse proxy, no Coturn)
	@echo "==> Checking /etc/hosts for netbird.local..."
	@grep -q 'netbird.local' /etc/hosts || \
		{ echo "ERROR: Add '127.0.0.1 netbird.local' to /etc/hosts first:"; \
		  echo "  sudo sh -c 'echo \"127.0.0.1 netbird.local\" >> /etc/hosts'"; exit 1; }
	docker compose $(COMPOSE_FILES_TEST) up -d
	@echo "==> Waiting for services (Zitadel init takes ~60s)..."
	@sleep 15
	docker compose $(COMPOSE_FILES_TEST) ps
	@echo ""
	@echo "==> Caddy proxy is routing:"
	@echo "    https://netbird.local       → Dashboard"
	@echo "    https://netbird.local/api   → Management API"
	@echo "    https://netbird.local/zitadel → Zitadel IdP"

.PHONY: netbird-down-test
netbird-down-test: ## Stop NetBird (test mode)
	docker compose $(COMPOSE_FILES_TEST) down

.PHONY: netbird-down
netbird-down: ## Stop NetBird (dev)
	docker compose $(COMPOSE_FILES_DEV) down

.PHONY: netbird-logs-test
netbird-logs-test: ## Tail NetBird logs (test mode)
	docker compose $(COMPOSE_FILES_TEST) logs -f

.PHONY: netbird-logs
netbird-logs: ## Tail NetBird logs
	docker compose $(COMPOSE_FILES_DEV) logs -f

.PHONY: netbird-status
netbird-status: ## Check NetBird API health
	@curl -sk https://netbird.internal/api/status 2>/dev/null || \
		curl -sk https://localhost/api/status 2>/dev/null || \
		echo "NetBird not reachable. Is it running? (make netbird-up)"

.PHONY: setup-key-create
setup-key-create: ## Create a reusable Setup Key for vehicle registration (requires PAT)
	@echo "Creating reusable setup key (valid 30 days, 1000 uses)..."
	@echo ""
	@echo "  First, create a PAT in Dashboard:"
	@echo "    1. Open https://netbird.local"
	@echo "    2. Login → Settings → Personal Access Tokens"
	@echo "    3. Create token → copy it"
	@echo ""
	@echo "  Then run:"
	@echo '    make setup-key-create PAT=<your-token>'
	@echo ""
	@if [ -n "$$PAT" ]; then \
		curl -sk -X POST "https://netbird.local:8443/api/setup-keys" \
			-H "Authorization: Token $$PAT" \
			-H "Content-Type: application/json" \
			-d '{"name":"factory-fleet","type":"reusable","usage_limit":1000,"expires_in":2592000}'; \
	fi

## ---------- client E2E test ----------

.PHONY: client-install
client-install: ## Install netbird CLI on macOS
	@echo "==> Installing netbird CLI..."
	@if command -v netbird >/dev/null 2>&1; then \
		echo "  [OK] netbird $(netbird version 2>/dev/null || echo 'installed')"; \
	elif [ -f /usr/local/bin/netbird ]; then \
		echo "  [OK] found at /usr/local/bin/netbird"; \
	else \
		echo ""; \
		echo "  Download from: https://github.com/netbirdio/netbird/releases/latest"; \
		echo "  macOS ARM64: netbird_0.72.1_darwin_arm64.tar.gz"; \
		echo ""; \
		echo "  tar xzf netbird_*.tar.gz"; \
		echo "  sudo cp netbird /usr/local/bin/"; \
		echo "  sudo chmod +x /usr/local/bin/netbird"; \
		exit 1; \
	fi

.PHONY: client-up
client-up: ## Connect netbird client to local server (requires SETUP_KEY env)
	@echo "==> Connecting netbird client..."
	@command -v netbird >/dev/null 2>&1 || { echo "ERROR: Install netbird first: make client-install"; exit 1; }
	@test -n "$$SETUP_KEY" || { \
		echo "ERROR: SETUP_KEY not set."; \
		echo "  Create one in Dashboard: https://netbird.local → Setup Keys"; \
		echo "  Then: make client-up SETUP_KEY=<your-key>"; \
		exit 1; \
	}
	@echo "  Management URL: https://netbird.local:8443"
	@echo "  Setup key: $${SETUP_KEY:0:8}..."
	@sudo netbird down 2>/dev/null || true
	sudo netbird up \
		--management-url "https://netbird.local:8443" \
		--setup-key "$$SETUP_KEY" \
		--hostname "macos-test" \
		--log-level info
	@sleep 3
	@echo ""
	@echo "==> Client status:"
	@netbird status

.PHONY: client-down
client-down: ## Disconnect netbird client
	sudo netbird down 2>/dev/null || echo "netbird not running"

.PHONY: client-status
client-status: ## Show netbird client status and peers
	netbird status 2>/dev/null || echo "netbird not running"

.PHONY: client-test
client-test: client-install ## Full client E2E test (server must be running: make test first)
	@echo "============================================================"
	@echo "  NetBird Client E2E Test"
	@echo "============================================================"
	@echo ""
	@# Check server
	@echo "[1/4] Checking server..."
	@dash_code=$$(curl -sk -o /dev/null -w '%{http_code}' https://netbird.local:8443/ 2>/dev/null); \
	if [ "$$dash_code" = "200" ] || [ "$$dash_code" = "302" ]; then \
		echo "  [OK] Server reachable (HTTP $$dash_code)"; \
	else \
		echo "  [FAIL] Server not reachable. Run 'make test' first."; \
		exit 1; \
	fi
	@# Check setup key
	@echo "[2/4] Setup key..."
	@test -n "$$SETUP_KEY" || { \
		echo ""; \
		echo "  ⚠  SETUP_KEY not set. Create one:"; \
		echo "    1. Open https://netbird.local"; \
		echo "    2. Login → Setup Keys → Create"; \
		echo "    3. Copy key → re-run: make client-test SETUP_KEY=<key>"; \
		echo ""; \
		exit 1; \
	}
	@echo "  [OK] SETUP_KEY=$${SETUP_KEY:0:8}..."
	@# Connect client
	@echo "[3/4] Connecting client..."
	@sudo netbird down 2>/dev/null || true
	@sudo netbird up \
		--management-url "https://netbird.local:8443" \
		--setup-key "$$SETUP_KEY" \
		--hostname "macos-test" \
		--log-level info 2>&1 | tail -5
	@sleep 5
	@# Verify
	@echo "[4/4] Verifying connectivity..."
	@STATUS=$$(netbird status 2>/dev/null || echo ""); \
	echo "$$STATUS"; \
	if echo "$$STATUS" | grep -qi 'connected\|running'; then \
		echo ""; \
		echo "  [OK] Client connected successfully!"; \
		echo "  Peers: $$(netbird status 2>/dev/null | grep -i peers || echo 'check status')"; \
	else \
		echo "  [WARN] Check status manually: netbird status"; \
	fi
	@echo ""
	@echo "============================================================"
	@echo "  Client test complete!"
	@echo ""
	@echo "  Status:   netbird status"
	@echo "  Disconnect: make client-down"
	@echo "  Logs:     sudo netbird up --log-level trace   (verbose)"
	@echo "============================================================"

.PHONY: clean
clean: netbird-down ## Stop NetBird and remove local certs
	rm -rf $(NETBIRD_DIR)/certs

## ---------- end-to-end test (macOS) ----------

COMPOSE_TEST := docker compose $(COMPOSE_FILES_TEST)

.PHONY: test
test: ## Run full e2e test on macOS (PKI → cert export → NetBird start → API check)
	@echo "============================================================"
	@echo "  NetBird E2E Test (macOS)"
	@echo "============================================================"
	@echo ""
	@# --- Step 0: prerequisites ---
	@echo "[0/5] Checking prerequisites..."
	@command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found"; exit 1; }
	@docker compose version >/dev/null 2>&1 || { echo "ERROR: docker compose not found"; exit 1; }
	@grep -q 'netbird.local' /etc/hosts 2>/dev/null || { \
		echo ""; \
		echo "  Add netbird.local to /etc/hosts:"; \
		echo "    sudo sh -c 'echo \"127.0.0.1 netbird.local\" >> /etc/hosts'"; \
		echo ""; \
		exit 1; }
	@echo "  [OK] docker + /etc/hosts"
	@# --- Step 1: cert export ---
	@echo "[1/5] Exporting TLS certificate from K8s Secret..."
	@bash $(NETBIRD_DIR)/cert-export.sh || { \
		echo "  [FAIL] cert-export.sh failed. Is my-infra kind cluster running?"; \
		echo "  Run: cd ../my-infra && make kind-up && make bootstrap && make test"; \
		exit 1; }
	@# --- Step 2: start services ---
	@echo "[2/5] Starting NetBird (Caddy + Management + Signal + Zitadel + Dashboard)..."
	@$(COMPOSE_TEST) down --remove-orphans 2>/dev/null || true
	@$(COMPOSE_TEST) up -d
	@echo "  Waiting for containers (Zitadel init takes ~90s)..."
	@for i in $$(seq 1 30); do \
		total=$$($(COMPOSE_TEST) ps -q 2>/dev/null | wc -l | tr -d ' '); \
		healthy=$$($(COMPOSE_TEST) ps 2>/dev/null | grep -c '(healthy)' || true); \
		[ "$$total" -gt 0 ] && [ "$$total" = "$$healthy" ] && break; \
		sleep 5; \
	done
	@echo ""
	@$(COMPOSE_TEST) ps
	@echo ""
	@# --- Step 3: verify TLS cert ---
	@echo "[3/5] Verifying TLS certificate..."
	@sleep 3
	@curl -sk --resolve netbird.local:443:127.0.0.1 https://netbird.local/api/status 2>/dev/null | head -c 200 || \
		{ echo "  [WARN] API not ready yet. Checking container logs..."; \
		  $(COMPOSE_TEST) logs --tail=20 management; }
	@echo ""
	@# --- Step 4: API health check ---
	@echo "[4/5] Checking Management API health..."
	@for i in $$(seq 1 12); do \
		resp=$$(curl -sk --resolve netbird.local:443:127.0.0.1 https://netbird.local/api/status 2>/dev/null || true); \
		if echo "$$resp" | grep -q '"status"'; then \
			echo "  [OK] Management API: $$resp"; \
			break; \
		fi; \
		[ "$$i" = "12" ] && { echo "  [FAIL] API not healthy after 60s"; exit 1; }; \
		sleep 5; \
	done
	@echo ""
	@# --- Step 5: dashboard reachable ---
	@echo "[5/5] Checking Dashboard..."
	@dash_code=$$(curl -sk --resolve netbird.local:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://netbird.local/ 2>/dev/null || echo "000"); \
	if [ "$$dash_code" = "200" ] || [ "$$dash_code" = "302" ]; then \
		echo "  [OK] Dashboard HTTP $$dash_code"; \
	else \
		echo "  [WARN] Dashboard returned $$dash_code (Zitadel may still be initializing)"; \
	fi
	@echo ""
	@# --- Step 6: auto-init Zitadel OIDC ---
	@echo "[6/6] Auto-configuring Zitadel OIDC application..."
	@NETBIRD_DOMAIN="$${NETBIRD_DOMAIN:-netbird.local}" bash $(NETBIRD_DIR)/auto-init.sh
	@echo ""
	@echo "============================================================"
	@echo "  Test complete!"
	@echo ""
	@echo "  Dashboard:  https://netbird.local"
	@echo "  API:        https://netbird.local/api/status"
	@echo "  Login:      netbird-admin / NetBirdAdmin123!"
	@echo ""
	@echo "  Cert info:  make cert-verify"
	@echo "  Logs:       make netbird-logs-test"
	@echo "  Stop:       make netbird-down-test"
	@echo "============================================================"

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
