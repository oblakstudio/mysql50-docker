IMAGE         ?= oblakstudio/mysql50
VERSION       ?= 5.0.32
PLATFORM      ?= linux/amd64
PLATFORMS     ?= linux/amd64,linux/386,linux/arm/v5
ROOT_PASSWORD ?= root
PORT          ?= 3306

.PHONY: build build-all run shell structure smoke smoke-all publish-check push clean help

build: ## Build the selected platform as :latest and :$(VERSION)
	docker build --platform=$(PLATFORM) \
		-t $(IMAGE):latest -t $(IMAGE):$(VERSION) .

build-all: ## Build all release platforms into the Buildx cache
	docker buildx build --platform=$(PLATFORMS) \
		-t $(IMAGE):latest -t $(IMAGE):$(VERSION) .

run: ## Run the selected platform locally
	docker run --rm -it --platform=$(PLATFORM) \
		-e MYSQL_ROOT_PASSWORD=$(ROOT_PASSWORD) \
		-p $(PORT):3306 $(IMAGE):latest

shell: ## Open a shell in the selected image
	docker run --rm -it --platform=$(PLATFORM) \
		--entrypoint /bin/bash $(IMAGE):latest

structure: ## Verify package, config, and cleanup invariants
	IMAGE=$(IMAGE):test PLATFORM=$(PLATFORM) ./tests/image-structure.sh

smoke: ## Build and smoke-test the selected platform
	IMAGE=$(IMAGE):test PLATFORM=$(PLATFORM) ./tests/smoke.sh

smoke-all: ## Build and smoke-test every release platform
	@set -e; \
	for platform in linux/amd64 linux/386 linux/arm/v5; do \
		suffix=$$(printf '%s' "$$platform" | tr '/' '-'); \
		tag="$(IMAGE):test-$$suffix"; \
		docker buildx build --load --platform="$$platform" -t "$$tag" .; \
		IMAGE="$$tag" PLATFORM="$$platform" SKIP_BUILD=1 ./tests/smoke.sh; \
	done

publish-check: ## Verify release attestations and Docker Hub README publishing
	./tests/publishing-workflow.sh

push: ## Build and publish the release platform index
	docker buildx build --push --provenance=mode=max --sbom=true \
		--platform=$(PLATFORMS) \
		-t $(IMAGE):latest -t $(IMAGE):$(VERSION) .

clean: ## Remove local development images without prompting
	-docker image rm -f $(IMAGE):latest $(IMAGE):$(VERSION) $(IMAGE):test \
		$(IMAGE):test-linux-amd64 $(IMAGE):test-linux-386 $(IMAGE):test-linux-arm-v5

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
