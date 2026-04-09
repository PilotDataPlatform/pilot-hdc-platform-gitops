ENV ?= dev
$(if $(filter $(ENV),dev prod),,$(error ENV=$(ENV) is invalid. Valid: dev prod))
CLUSTER_DIR := clusters/$(ENV)
APPS_DIR := $(CLUSTER_DIR)/apps
REGISTRY_DIR := $(CLUSTER_DIR)
VERSIONS_FILE := $(CLUSTER_DIR)/versions.yaml
WORKBENCH_DIR := $(CLUSTER_DIR)/workbench

# Full curated app list — filtered to existing dirs so partial envs work
_APPS := registry-secrets greenroom-storage core-storage nfs-provisioner postgresql keycloak-postgresql kong-postgresql redis kafka elasticsearch message-bus-greenroom keycloak auth metadata project dataops dataset approval kong bff minio mailhog notification portal queue-consumer queue-producer queue-socketio pipelinewatch upload-greenroom upload-core download-greenroom download-core metadata-event-handler search kg-integration bff-cli workspace xwiki
APPS := $(strip $(foreach app,$(_APPS),$(if $(wildcard $(APPS_DIR)/$(app)),$(app))))

_WORKBENCH_CHARTS := guacamole-stack superset jupyterhub
WORKBENCH_CHARTS := $(strip $(foreach c,$(_WORKBENCH_CHARTS),$(if $(wildcard $(WORKBENCH_DIR)/$(c)),$(c))))

ifeq ($(ENV),prod)
  DOMAIN := hdc.ebrains.eu
else
  DOMAIN := dev.hdc.ebrains.eu
endif

export ENV

.PHONY: helm-deps helm-deps-workbench helm-test-eso helm-test-image helm-test-versions helm-test-envdup helm-test-pullsecrets helm-test-envvars-rendered helm-test-regsecret-coverage helm-test-workbench sync-versions sync-rsa-key test clean switch-registry which-registry

EXPECTED_REGISTRY := $(shell grep 'imageRegistry:' $(REGISTRY_DIR)/registry.yaml 2>/dev/null | awk '{print $$2}')

# Build helm dependencies for all apps (skip repo refresh for speed)
helm-deps:
	@for app in $(APPS); do \
		echo "Building deps for $$app..."; \
		helm dependency build --skip-refresh $(APPS_DIR)/$$app; \
	done

# Build helm dependencies for workbench charts
helm-deps-workbench:
	@for chart in $(WORKBENCH_CHARTS); do \
		echo "Building deps for workbench/$$chart..."; \
		helm dependency build --skip-refresh $(WORKBENCH_DIR)/$$chart; \
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

# Sync RSA_PUBLIC_KEY from Keycloak terraform output into values.yaml files
sync-rsa-key:
	@bash scripts/sync-rsa-public-key.sh

# Verify image tags rendered by helm template match versions.yaml
helm-test-versions: helm-deps
	@echo "Testing image tags from versions.yaml..."
	@if [ ! -f $(VERSIONS_FILE) ]; then echo "⊘ No versions.yaml (skipped)"; exit 0; fi; \
	failed=0; \
	check_tag() { \
		app=$$1; values_key=$$2; dir=$$3; \
		if [ ! -d $(APPS_DIR)/$$dir ]; then echo "⊘ $$app: not present (skipped)"; return 0; fi; \
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
	check_tag dataops dataops-service dataops; \
	check_tag notification notification-service notification; \
	check_tag approval approval-service approval; \
	check_tag portal portal portal; \
	check_tag pipelinewatch pipelinewatch-service pipelinewatch; \
	check_tag upload-greenroom upload-service upload-greenroom; \
	check_tag upload-core upload-service upload-core; \
	check_tag download-greenroom download-service download-greenroom; \
	check_tag download-core download-service download-core; \
	check_tag metadata-event-handler metadata-event-handler metadata-event-handler; \
	check_tag search search-service search; \
	check_tag bff-cli bff-cli-service bff-cli; \
	check_tag workspace workspace-service workspace; \
	check_tag xwiki xwiki xwiki; \
	exit $$failed

# Detect duplicate env var names that ServerSideApply would reject
helm-test-envdup: helm-deps
	@echo "Testing for duplicate env vars..."
	@if [ -n "$(APPS)" ]; then bash scripts/check-duplicate-env.sh $(APPS); else echo "⊘ No apps to test"; fi

# Ensure every pod spec has imagePullSecrets for private registry access
helm-test-pullsecrets: helm-deps
	@echo "Testing imagePullSecrets on all pod specs..."
	@if [ -n "$(APPS)" ]; then bash scripts/check-pull-secrets.sh $(APPS); else echo "⊘ No apps to test"; fi

# Verify env vars defined in values.yaml are actually rendered in helm template
# Catches chart bugs where extraEnvVars aren't picked up (e.g., Kong migration job)
helm-test-envvars-rendered: helm-deps
	@echo "Testing env vars defined in values.yaml are rendered..."
	@if [ -n "$(APPS)" ]; then bash scripts/check-envvars-rendered.sh $(APPS); else echo "⊘ No apps to test"; fi

# Ensure every namespace that uses docker-registry-secret is covered by registry-secrets
helm-test-regsecret-coverage: helm-deps
	@echo "Testing registry-secret namespace coverage..."
	@if [ -n "$(APPS)" ]; then bash scripts/check-registry-secret-coverage.sh $(APPS); else echo "⊘ No apps to test"; fi

# Test workbench charts render correctly
helm-test-workbench: helm-deps-workbench
	@echo "Testing workbench charts..."
	@failed=0; \
	for chart in $(WORKBENCH_CHARTS); do \
		echo "--- $$chart ---"; \
		output=$$(helm template test $(WORKBENCH_DIR)/$$chart \
			-f $(REGISTRY_DIR)/registry.yaml \
			-f $(WORKBENCH_DIR)/$$chart/values.yaml \
			--set projectName=testproject \
			--set domain=$(DOMAIN) \
			--skip-tests 2>&1); \
		if [ $$? -ne 0 ]; then \
			echo "✗ $$chart: helm template failed"; \
			echo "$$output"; \
			failed=1; \
			continue; \
		fi; \
		images=$$(echo "$$output" | grep -E '^\s+image:' | awk '{print $$2}' | tr -d "\"'" | sort -u); \
		for img in $$images; do \
			if echo "$$img" | grep -q "^$(EXPECTED_REGISTRY)/"; then \
				echo "✓ $$chart: $$img"; \
			else \
				echo "✗ $$chart: $$img (expected $(EXPECTED_REGISTRY))"; \
				failed=1; \
			fi; \
		done; \
		if [ -f $(WORKBENCH_DIR)/$$chart/templates/docker-registry-secret.yaml ]; then \
			if echo "$$output" | grep -q '{{ .username }}' && \
			   echo "$$output" | grep -q '{{ .password }}'; then \
				echo "✓ $$chart: ESO template variables preserved"; \
			else \
				echo "✗ $$chart: ESO template variables NOT preserved"; \
				failed=1; \
			fi; \
		else \
			echo "⊘ $$chart: no docker-registry-secret template (skipped ESO check)"; \
		fi; \
		if echo "$$output" | grep -q 'imagePullSecrets'; then \
			echo "✓ $$chart: imagePullSecrets present"; \
		else \
			echo "✗ $$chart: imagePullSecrets missing"; \
			failed=1; \
		fi; \
	done; \
	exit $$failed

test: helm-test-eso helm-test-image helm-test-versions helm-test-envdup helm-test-pullsecrets helm-test-envvars-rendered helm-test-regsecret-coverage helm-test-workbench

clean:
	@for app in $(APPS); do \
		rm -rf $(APPS_DIR)/$$app/charts $(APPS_DIR)/$$app/Chart.lock; \
	done
	@for chart in $(WORKBENCH_CHARTS); do \
		rm -rf $(WORKBENCH_DIR)/$$chart/charts $(WORKBENCH_DIR)/$$chart/Chart.lock; \
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
