# Image URL to use all building/pushing image targets
IMG ?= kdex-tech/kdex-themeserver:latest

REPOSITORY ?= 
# if REPOSITORY is set make sure it ends with a /
ifneq ($(REPOSITORY),)
override REPOSITORY := $(REPOSITORY)/
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

# If you wish to build the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	$(CONTAINER_TOOL) build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

# PLATFORMS defines the target platforms for the manager image be built to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - be able to use docker buildx. More info: https://docs.docker.com/build/buildx/
# - have enabled BuildKit. More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image to your registry (i.e. if you do not set a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To adequately provide solutions that are compatible with multiple platforms, you should consider using this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	$(CONTAINER_TOOL) buildx inspect kdex-nexus-builder >/dev/null 2>&1 || $(CONTAINER_TOOL) buildx create --name kdex-nexus-builder --use
	$(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag ${REPOSITORY}${IMG} -f Dockerfile.cross .
	rm Dockerfile.cross

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
	trap 'echo "--> Stopping Caddy server (PID: $${CADDY_PID})"; kill $${CADDY_PID}; exit 0' EXIT; \
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
	echo "--> All tests passed"
