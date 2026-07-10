REPOSITORY ?=
IMG ?= kdex-tech/backend-static
TAG ?= $(shell git describe --dirty='-d' --tags)

# if REPOSITORY is set make sure it ends with a /
ifneq ($(REPOSITORY),)
override REPOSITORY := $(REPOSITORY)/
endif

# if TAG is set make sure it starts with a :
ifneq ($(TAG),)
override TAG := :$(TAG)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
# Be aware that the target commands are only tested with Docker which is
# scaffolded by default. However, you might want to replace it to use other
# tools. (i.e. podman)
CONTAINER_TOOL ?= docker

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# Conditionally include the .env file if it exists, using -include to prevent errors
-include .env

# Export all variables defined in the Makefile to the shell of the recipes
export

.PHONY: all
all: docker-build

##@ General

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%%-15s\033[0m %%s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST) 

##@ Build

.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	$(CONTAINER_TOOL) build -t ${REPOSITORY}${IMG}${TAG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${REPOSITORY}${IMG}${TAG}

PLATFORMS ?= linux/arm64,linux/amd64
.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for cross-platform support
	# This Dockerfile is single-stage, so we do NOT inject
	# --platform=${BUILDPLATFORM} on the FROM. buildx --platform handles
	# per-target builds natively (with QEMU emulation for non-native
	# targets); forcing BUILDPLATFORM would make every target's image
	# contain the build host's binaries while the manifest list mis-tags
	# them with the target arch. Same fix that landed in kdex-cli-tools
	# v0.3.11 - see kdex-tech/cli-tools commit history.
	$(CONTAINER_TOOL) buildx inspect kdex-builder >/dev/null 2>&1 || $(CONTAINER_TOOL) buildx create --name kdex-builder --use
	$(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag ${REPOSITORY}${IMG}${TAG} --tag ${REPOSITORY}${IMG}:latest .

##@ Testing

CADDY_404_URL ?= /404.html
CADDY_IMPORTS_PATH ?= test/caddy.d/*
CADDY_PORT ?= 8060
CORS_DOMAINS ?= .*\.docker\.localhost|foo\.test
PUBLIC_RESOURCES_DIR ?= test/public

.PHONY: test
test:
	@echo "--> Validating Caddyfile"
	caddy validate --config Caddyfile
	@echo "--> Starting Caddy server in background for testing"
	caddy run --config Caddyfile & CADDY_PID=$$! ; \
	trap 'rc=$$?; echo "--> Stopping Caddy server (PID: $${CADDY_PID})"; kill $${CADDY_PID} 2>/dev/null; exit $$rc' EXIT; \
	echo "Caddy server started with PID: $${CADDY_PID}" ; \
	\
	echo "--> Waiting for Caddy to be ready on port $(CADDY_PORT)..." ; \
	tries=0; \
	until curl -s --fail "http://localhost:$(CADDY_PORT)" > /dev/null 2>&1; do \
		sleep 1; \
		tries=$$((tries + 1)); \
		if [ "$$tries" -ge "10" ]; then \
			echo "Error: Caddy server did not start within 10 seconds."; \
			exit 1; \
		fi; \
	done; \
	echo "Caddy server is ready."; \
	\
	echo "--> Running tests"; \
	echo "  - Testing for 200 OK on /"; \
	curl -s --fail "http://localhost:$(CADDY_PORT)/" > /dev/null; \
	echo "    Success: Received 200 OK"; \
	\
	echo "  - Testing for 404 Not Found on /non-existent-page"; \
	if ! curl -s --fail "http://localhost:$(CADDY_PORT)/non-existent-page" > /dev/null 2>&1; then \
		echo "    Success: Received 404 Not Found as expected"; \
	else \
		echo "    Error: Expected 404 but received a success status."; \
		exit 1; \
	fi; \
	\
	echo "  - Testing PATH_PREFIX functionality"; \
	PATH_PREFIX=/test-prefix CADDY_PORT=8061 caddy run --config Caddyfile & TEST_PREFIX_PID=$$! ; \
	echo "    Waiting for Caddy with PATH_PREFIX to be ready on port 8061..."; \
	tries=0; \
	until curl -s --fail "http://localhost:8061/test-prefix/" > /dev/null 2>&1; do \
		sleep 1; \
		tries=$$((tries + 1)); \
		if [ "$$tries" -ge "10" ]; then \
			echo "    Error: Caddy server with PATH_PREFIX did not start."; \
			kill $$TEST_PREFIX_PID; exit 1; \
		fi; \
	done; \
	echo "    Success: PATH_PREFIX is working"; \
	kill $$TEST_PREFIX_PID; \
	\
	echo "  - Testing health probe (200 OK)"; \
	STATUS_CODE=$$(curl -s -o /dev/null -w "%{http_code}" -H "User-Agent: kube-probe/1.28" "http://localhost:$(CADDY_PORT)/"); \
	if [ "$$STATUS_CODE" != "200" ]; then \
		echo "    Error: Expected 200 for health probe but received $$STATUS_CODE"; \
		exit 1; \
	fi; \
	echo "    Success: Received 200 OK for health probe"; \
	\
	echo "  - Testing caching (304 Not Modified)"; \
	RESPONSE_HEADERS=$$(curl -s -i "http://localhost:$(CADDY_PORT)/" -o /dev/null -D -); \
	ETAG=$$(echo "$$RESPONSE_HEADERS" | grep -i '^etag:' | awk '{print $$2}' | tr -d '\r\n'); \
	if [ -z "$$ETAG" ]; then \
		echo "    Error: No ETag returned for /"; \
		exit 1; \
	fi; \
	STATUS_CODE=$$(curl -s -o /dev/null -w "%{http_code}" -H "If-None-Match: $$ETAG" "http://localhost:$(CADDY_PORT)/"); \
	if [ "$$STATUS_CODE" != "304" ]; then \
		echo "    Error: Expected 304 but received $$STATUS_CODE for /"; \
		exit 1; \
	fi; \
	echo "    Success: Received 304 Not Modified for /"; \
	\
	RESPONSE_HEADERS=$$(curl -s -i "http://localhost:$(CADDY_PORT)/index.html" -o /dev/null -D -); \
	ETAG=$$(echo "$$RESPONSE_HEADERS" | grep -i '^etag:' | awk '{print $$2}' | tr -d '\r\n'); \
	if [ -z "$$ETAG" ]; then \
		echo "    Error: No ETag returned for index.html"; \
		exit 1; \
	fi; \
	STATUS_CODE=$$(curl -s -o /dev/null -w "%{http_code}" -H "If-None-Match: $$ETAG" "http://localhost:$(CADDY_PORT)/index.html"); \
	if [ "$$STATUS_CODE" != "304" ]; then \
		echo "    Error: Expected 304 but received $$STATUS_CODE for index.html"; \
		exit 1; \
	fi; \
	echo "    Success: Received 304 Not Modified for index.html"; \
	\
	echo "  - Testing Cache-Control header (default no-cache, enables ETag revalidation)"; \
	CC=$$(curl -s -i "http://localhost:$(CADDY_PORT)/index.html" -o /dev/null -D - | grep -i '^cache-control:' | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d '\r\n' || true); \
	if [ "$$CC" != "no-cache" ]; then \
		echo "    Error: Expected Cache-Control 'no-cache' but received '$$CC' for index.html"; \
		exit 1; \
	fi; \
	echo "    Success: Cache-Control 'no-cache' present on index.html"; \
	\
	echo "  - Testing CACHE_CONTROL override"; \
	CACHE_CONTROL="public, max-age=60, must-revalidate" CADDY_PORT=8062 caddy run --config Caddyfile & OVERRIDE_PID=$$! ; \
	tries=0; \
	until curl -s --fail "http://localhost:8062/" > /dev/null 2>&1; do \
		sleep 1; \
		tries=$$((tries + 1)); \
		if [ "$$tries" -ge "10" ]; then \
			echo "    Error: Caddy with CACHE_CONTROL override did not start."; \
			kill $$OVERRIDE_PID; exit 1; \
		fi; \
	done; \
	CC=$$(curl -s -i "http://localhost:8062/index.html" -o /dev/null -D - | grep -i '^cache-control:' | cut -d: -f2- | sed 's/^[[:space:]]*//' | tr -d '\r\n' || true); \
	kill $$OVERRIDE_PID; \
	if [ "$$CC" != "public, max-age=60, must-revalidate" ]; then \
		echo "    Error: Expected overridden Cache-Control but received '$$CC'"; \
		exit 1; \
	fi; \
	echo "    Success: CACHE_CONTROL override honored"; \
	\
	echo "--> All tests passed"
