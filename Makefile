APPS_DIR := clusters/dev/apps
APPS := postgresql keycloak-postgresql redis keycloak auth
REGISTRY_DIR := clusters/dev

.PHONY: helm-deps helm-test-eso helm-test-image test clean switch-registry which-registry

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

test: helm-test-eso helm-test-image

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
