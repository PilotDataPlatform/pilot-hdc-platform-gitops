APPS_DIR := clusters/dev/apps
APPS := registry-secrets postgresql keycloak-postgresql kong-postgresql redis kafka keycloak auth metadata project kong bff minio portal
REGISTRY_DIR := clusters/dev
VERSIONS_FILE := clusters/dev/versions.yaml

.PHONY: helm-deps helm-test-eso helm-test-image helm-test-versions helm-test-envdup helm-test-pullsecrets helm-test-envvars-rendered sync-versions test clean switch-registry which-registry

EXPECTED_REGISTRY := $(shell grep 'imageRegistry:' $(REGISTRY_DIR)/registry.yaml 2>/dev/null | awk '{print $$2}')

# Build helm dependencies for all apps (skip repo refresh for speed)
helm-deps:
	@for app in $(APPS); do \
		echo "Building deps for $$app..."; \
		helm dependency build --skip-refresh $(APPS_DIR)/$$app; \
	done

# Test ExternalSecret templates render ESO variables correctly
helm-test-eso: helm-deps
	@echo "Testing ExternalSecret template rendering..."
	@failed=0; \
	for app in $(APPS); do \
		if [ ! -f $(APPS_DIR)/$$app/templates/docker-registry-secret.yaml ]; then \
			echo "⊘ $$app: no docker-registry-secret template (skipped)"; \
			continue; \
		fi; \
		output=$$(helm template test $(APPS_DIR)/$$app -f $(REGISTRY_DIR)/registry.yaml --show-only templates/docker-registry-secret.yaml 2>&1); \
		if echo "$$output" | grep -q '{{ .username }}' && \
		   echo "$$output" | grep -q '{{ .password }}' && \
		   echo "$$output" | grep -q '{{ printf "%s:%s" .username .password | b64enc }}'; then \
			echo "✓ $$app: ESO template variables preserved"; \
		else \
			echo "✗ $$app: ESO template variables NOT preserved"; \
			echo "$$output" | grep dockerconfigjson; \
			failed=1; \
		fi; \
	done; \
	exit $$failed

# Test images use internal registry, not docker.io
helm-test-image: helm-deps
	@echo "Testing image registry..."
	@failed=0; \
	for app in $(APPS); do \
		images=$$(helm template test $(APPS_DIR)/$$app -f $(REGISTRY_DIR)/registry.yaml --skip-tests 2>/dev/null | grep -E '^\s+image:' | awk '{print $$2}' | tr -d '"' | sort -u); \
		for img in $$images; do \
			if echo "$$img" | grep -q "^$(EXPECTED_REGISTRY)/"; then \
				echo "✓ $$app: $$img"; \
			else \
				echo "✗ $$app: $$img (expected $(EXPECTED_REGISTRY))"; \
				failed=1; \
			fi; \
		done; \
	done; \
	exit $$failed

# Sync chart dependency versions from versions.yaml into each app's Chart.yaml
# Chart.yaml versions can't be set via Helm values — they're read at `helm dependency build` time.
# Workflow: bump version in versions.yaml → make sync-versions → commit both files.
sync-versions:
	@bash scripts/sync-chart-versions.sh

# Verify image tags rendered by helm template match versions.yaml
helm-test-versions: helm-deps
	@echo "Testing image tags from versions.yaml..."
	@failed=0; \
	check_tag() { \
		app=$$1; values_key=$$2; dir=$$3; \
		expected=$$(yq ".\"$$values_key\".image.tag" $(VERSIONS_FILE)); \
		rendered=$$(helm template test $(APPS_DIR)/$$dir \
			-f $(REGISTRY_DIR)/registry.yaml \
			-f $(VERSIONS_FILE) \
			-f $(APPS_DIR)/$$dir/values.yaml \
			--skip-tests 2>/dev/null \
		| grep -E '^\s+image:' | sed 's/.*image:\s*"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | grep -F "$${expected}" | head -1); \
		if [ -n "$$rendered" ]; then \
			echo "✓ $$app: tag $$expected found"; \
		else \
			echo "✗ $$app: expected tag $$expected not found in rendered output"; \
			failed=1; \
		fi; \
	}; \
	check_tag auth auth-service auth; \
	check_tag metadata metadata-service metadata; \
	check_tag project project-service project; \
	check_tag postgresql postgresql postgresql; \
	check_tag keycloak keycloak keycloak; \
	check_tag portal portal portal; \
	exit $$failed

# Detect duplicate env var names that ServerSideApply would reject
helm-test-envdup: helm-deps
	@echo "Testing for duplicate env vars..."
	@bash scripts/check-duplicate-env.sh $(APPS)

# Ensure every pod spec has imagePullSecrets for private registry access
helm-test-pullsecrets: helm-deps
	@echo "Testing imagePullSecrets on all pod specs..."
	@bash scripts/check-pull-secrets.sh $(APPS)

# Verify env vars defined in values.yaml are actually rendered in helm template
# Catches chart bugs where extraEnvVars aren't picked up (e.g., Kong migration job)
helm-test-envvars-rendered: helm-deps
	@echo "Testing env vars defined in values.yaml are rendered..."
	@bash scripts/check-envvars-rendered.sh $(APPS)

test: helm-test-eso helm-test-image helm-test-versions helm-test-envdup helm-test-pullsecrets helm-test-envvars-rendered

clean:
	@for app in $(APPS); do \
		rm -rf $(APPS_DIR)/$$app/charts $(APPS_DIR)/$$app/Chart.lock; \
	done

# Registry switching: make switch-registry TO=ovh|ebrains
switch-registry:
	@test -n "$(TO)" || (echo "Usage: make switch-registry TO=ovh|ebrains" && exit 1)
	@test -f $(REGISTRY_DIR)/registry-$(TO).yaml || (echo "No preset: $(REGISTRY_DIR)/registry-$(TO).yaml" && exit 1)
	$(eval OLD_REG := $(shell grep 'imageRegistry:' $(REGISTRY_DIR)/registry.yaml 2>/dev/null | awk '{print $$2}'))
	$(eval NEW_REG := $(shell grep 'imageRegistry:' $(REGISTRY_DIR)/registry-$(TO).yaml | awk '{print $$2}'))
	cp $(REGISTRY_DIR)/registry-$(TO).yaml $(REGISTRY_DIR)/registry.yaml
	@if [ "$(OLD_REG)" != "$(NEW_REG)" ]; then \
		for app in $(APPS); do \
			if grep -q '$(OLD_REG)' $(APPS_DIR)/$$app/values.yaml 2>/dev/null; then \
				sed -i 's|$(OLD_REG)|$(NEW_REG)|g' $(APPS_DIR)/$$app/values.yaml; \
				echo "  Updated $$app/values.yaml"; \
			fi; \
		done; \
	fi
	@echo "Switched to $(TO): $(NEW_REG)"

which-registry:
	@echo "Active: $$(grep 'imageRegistry:' $(REGISTRY_DIR)/registry.yaml | awk '{print $$2}')"
	@echo "Vault:  $$(grep 'registryVaultPath:' $(REGISTRY_DIR)/registry.yaml | awk '{print $$2}')"
