APPS_DIR := clusters/dev/apps
APPS := postgresql keycloak-postgresql redis

.PHONY: helm-deps helm-test-eso test clean

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
		output=$$(helm template test $(APPS_DIR)/$$app --show-only templates/docker-registry-secret.yaml 2>&1); \
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

test: helm-test-eso

clean:
	@for app in $(APPS); do \
		rm -rf $(APPS_DIR)/$$app/charts $(APPS_DIR)/$$app/Chart.lock; \
	done
