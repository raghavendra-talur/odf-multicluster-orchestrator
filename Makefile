PROJECT_DIR := $(shell dirname $(abspath $(lastword $(MAKEFILE_LIST))))
CWD := $(shell pwd)

.DEFAULT_GOAL := help

# All variables are defined here
include hack/make/vars.mk

# Install required tools
include hack/make/tools.mk

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

all: build

##@ General

help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true,preserveUnknownFields=false"

manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

fmt: ## Run go fmt against code.
	go fmt ./...

vet: ## Run go vet against code.
	go vet ./...

golangci-lint: golangci-bin ## Run golangci-lint against code.
	$(GOLANGCI_BIN) run ./...

kube-linter: kubelinter-bin ## Run kube-linter against YAML files
	$(KUBELINTER_BIN) lint ./ --config ./.kube-linter-config.yaml

unit-test: ## Run unit tests
	go test ./... -v -tags unit -coverprofile unit-cover.out

ENVTEST_ASSETS_DIR=$(CWD)/testbin
OPENSHIFT_CI ?= false
test: setup-envtest-bin ## Run integration tests.
ifeq ($(OPENSHIFT_CI), true)
	@echo "Running in OpenShift CI. Syncing vendor"
	go mod tidy && go mod vendor
else
	@echo "Running outside OpenShift CI. Ignoring vendor"
endif
	make manifests generate fmt vet
	mkdir -p ${ENVTEST_ASSETS_DIR}
	source <($(SETUP_ENVTEST_BIN) use -i -p env 1.21.x); go test ./tests/integration/... -v -tags integration -coverprofile integration-cover.out

##@ Build

build: generate fmt vet golangci-lint kube-linter ## Build manager binary.
	go build -o bin/manager main.go

run: manifests generate fmt vet ## Run a controller from your host.
	go run ./main.go

docker-build: generate fmt vet golangci-lint kube-linter ## Build docker image with the manager.
	docker build -t ${IMG} .

docker-push: ## Push docker image with the manager.
	docker push ${IMG}

##@ Deployment

install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | kubectl apply -f -

undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config.
	$(KUSTOMIZE) build config/default | kubectl delete -f -

.PHONY: bundle
bundle: manifests kustomize operator-sdk ## Generate bundle manifests and metadata, then validate generated files.
	$(OSDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG)
	export IMG=$(IMG) && $(KUSTOMIZE) build config/manifests | envsubst | $(OSDK) generate bundle -q --overwrite --version $(VERSION) $(BUNDLE_METADATA_OPTS)
	$(OSDK) bundle validate ./bundle

.PHONY: bundle-build
bundle-build: bundle ## Build the bundle image.
	docker build -f bundle.Dockerfile -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool docker --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

##@ Actions

ensure-clean-workdir: ## Ensure all required changes are generated and committed
	go mod tidy
	$(MAKE) manifests generate fmt vet
	git --no-pager diff
	git status --porcelain 2>&1 | tee /dev/stderr | (! read)
