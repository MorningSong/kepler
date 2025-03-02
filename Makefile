all: kepler

include bpfassets/libbpf/Makefile

### env define ###
export BIN_TIMESTAMP ?=$(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
export TIMESTAMP ?=$(shell echo $(BIN_TIMESTAMP) | tr -d ':' | tr 'T' '-' | tr -d 'Z')

# restrict included verify-* targets to only process project files
SOURCE_GIT_TAG     := $(shell git describe --tags --always --abbrev=7 --match 'v*')
SRC_ROOT           := $(shell pwd)
ARCH               := $(shell arch)
OUTPUT_DIR         := _output
CROSS_BUILD_BINDIR := $(OUTPUT_DIR)/bin
GIT_VERSION        := $(shell git describe --dirty --tags --always --match='v*')
VERSION            ?= $(GIT_VERSION)
LDFLAGS            := "-w -s -X 'github.com/sustainable-computing-io/kepler/pkg/version.Version=$(VERSION)'"
ROOTLESS	       ?= false
IMAGE_REPO         ?= quay.io/sustainable_computing_io
BUILDER_IMAGE      ?= quay.io/sustainable_computing_io/kepler_builder:ubi-9-libbpf-1.2.0
IMAGE_NAME         ?= kepler
IMAGE_TAG          ?= latest
CTR_CMD            ?= $(or $(shell which podman 2>/dev/null), $(shell which docker 2>/dev/null))

# use CTR_CMD_PUSH_OPTIONS to add options to <container-runtime> push command.
# E.g. --tls-verify=false for local develop when using podman
CTR_CMD_PUSH_OPTIONS ?=


ifeq ($(DEBUG),true)
	# throw all the debug info in!
	LD_FLAGS =
	GC_FLAGS =-gcflags "all=-N -l"
else
	# strip everything we can
	LD_FLAGS =-w -s
	GC_FLAGS =
endif

GENERAL_TAGS := 'include_gcs include_oss containers_image_openpgp gssapi providerless netgo osusergo gpu libbpf '
GO_LD_FLAGS := $(GC_FLAGS) -ldflags "-X $(LD_FLAGS)" $(CFLAGS)

# set GOENV
GOOS := $(shell go env GOOS)
GOARCH := $(shell go env GOARCH)
GOENV := GOOS=$(GOOS) GOARCH=$(GOARCH)

LIBBPF_HEADERS := /usr/include/bpf
KEPLER_OBJ_SRC := $(SRC_ROOT)/bpfassets/libbpf/bpf.o/$(GOARCH)_kepler.bpf.o
LIBBPF_OBJ ?= /usr/lib64/libbpf.a

GOENV = GO111MODULE="" GOOS=$(GOOS) GOARCH=$(GOARCH) CGO_ENABLED=1 CC=clang CGO_CFLAGS="-I $(LIBBPF_HEADERS)" CGO_LDFLAGS="$(LIBBPF_OBJ)"

DOCKERFILE := $(SRC_ROOT)/build/Dockerfile
IMAGE_BUILD_TAG := $(SOURCE_GIT_TAG)-linux-$(GOARCH)
GO_BUILD_TAGS := $(GENERAL_TAGS)$(GOOS)

# for testsuite
ENVTEST_ASSETS_DIR=$(SRC_ROOT)/test-bin
export PATH := $(PATH):$(SRC_ROOT)/test-bin

ifndef GOPATH
	GOPATH := $(HOME)/go
endif

ifndef GOBIN
	GOBIN := $(GOPATH)/bin
endif

# NOTE: project related tools get installed to tmp dir which is ignored by 
PROJECT_DIR := $(shell dirname $(abspath $(firstword $(MAKEFILE_LIST))))
TOOLS_DIR=$(PROJECT_DIR)/tmp/bin
KUSTOMIZE = $(TOOLS_DIR)/kustomize
GOVULNCHECK = $(TOOLS_DIR)/govulncheck

base_dir := $(patsubst %/,%,$(dir $(realpath $(firstword $(MAKEFILE_LIST)))))

### Default ###
kepler: build_containerized
.PHONY: kepler

clean: clean-cross-build
.PHONY: clean

### build container ###
build_containerized: tidy-vendor format
	@if [ -z '$(CTR_CMD)' ] ; then echo '!! ERROR: containerized builds require podman||docker CLI, none found $$PATH' >&2 && exit 1; fi
	echo BIN_TIMESTAMP==$(BIN_TIMESTAMP)

	$(CTR_CMD) build -t $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_BUILD_TAG) \
		-f $(DOCKERFILE) \
		--network host \
		--build-arg SOURCE_GIT_TAG=$(SOURCE_GIT_TAG) \
		--build-arg BIN_TIMESTAMP=$(BIN_TIMESTAMP) \
		--platform="linux/$(GOARCH)" \
		.

	$(CTR_CMD) tag $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_BUILD_TAG) $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG)

.PHONY: build_containerized

save-image:
	@mkdir -p _output
	$(CTR_CMD) save $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG) | gzip > "${IMAGE_OUTPUT_PATH}"
.PHONY: save-image

load-image:
	$(CTR_CMD) load -i "${INPUT_PATH}"
.PHONY: load-image

image-prune:
	$(CTR_CMD) image prune -a -f || true
.PHONY: image-prune

push-image:
	$(CTR_CMD) push $(CTR_CMD_PUSH_OPTIONS) $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG)
.PHONY: push-image

clean-cross-build:
	$(RM) -r '$(CROSS_BUILD_BINDIR)'
	$(RM) -rf $(OUTPUT_DIR)/staging
	if [ -d '$(OUTPUT_DIR)' ]; then rmdir --ignore-fail-on-non-empty '$(OUTPUT_DIR)'; fi
.PHONY: clean-cross-build

### build binary ###
build: clean_build_local _build_local copy_build_local
.PHONY: build

_build_local:
	@echo TAGS=$(GO_BUILD_TAGS)
	@mkdir -p "$(CROSS_BUILD_BINDIR)/$(GOOS)_$(GOARCH)"
	+@$(GOENV) go build -v -tags ${GO_BUILD_TAGS} -o $(CROSS_BUILD_BINDIR)/$(GOOS)_$(GOARCH)/kepler -ldflags $(LDFLAGS) ./cmd/exporter/exporter.go

container_build:
	$(CTR_CMD) run --rm \
		--network host \
		-v $(base_dir):/kepler:Z -w /kepler \
		-e GOROOT=/usr/local/go -e PATH=/usr/bin:/bin:/sbin:/usr/local/bin:/usr/local/go/bin \
		$(BUILDER_IMAGE) \
		git config --global --add safe.directory /kepler && make build

build_rpm:
	rpmbuild packaging/rpm/kepler.spec --build-in-place -bb

build_container_rpm:
	rpmbuild packaging/rpm/container-kepler.spec --build-in-place -bb

containerized_build_rpm:
	@mkdir -p $(base_dir)/$(OUTPUT_DIR)/rpmbuild
	$(CTR_CMD) run --rm \
		-v $(base_dir):/kepler:Z -w /kepler -v $(base_dir)/$(OUTPUT_DIR)/rpmbuild:/opt/app-root/src/rpmbuild \
		-e _VERSION_=${_VERSION_} -e _RELEASE_=${_RELEASE_} -e _ARCH_=${_ARCH_} \
		-e _TIMESTAMP_="$(shell date +"%a %b %d %Y")" -e _COMMITTER_=${_COMMITTER_} -e  _CHANGELOG_=${_CHANGELOG_} \
		-e PATH=$(PATH):/usr/local/go/bin \
		$(BUILDER_IMAGE) \
		make build_rpm

containerized_build_container_rpm:
	@mkdir -p $(base_dir)/$(OUTPUT_DIR)/rpmbuild
	$(CTR_CMD) run --rm \
		-v $(base_dir):/kepler:Z -w /kepler -v $(base_dir)/$(OUTPUT_DIR)/rpmbuild:/opt/app-root/src/rpmbuild \
		-e _VERSION_=${_VERSION_} -e _RELEASE_=${_RELEASE_} \
		$(BUILDER_IMAGE) \
		make build_container_rpm

clean_build_local:
	rm -rf $(CROSS_BUILD_BINDIR)

copy_build_local:
	cp $(CROSS_BUILD_BINDIR)/$(GOOS)_$(GOARCH)/kepler $(CROSS_BUILD_BINDIR)

cross-build-linux-amd64:
	+$(MAKE) _build_local GOOS=linux GOARCH=amd64
.PHONY: cross-build-linux-amd64

cross-build-linux-arm64:
	+$(MAKE) _build_local GOOS=linux GOARCH=arm64
.PHONY: cross-build-linux-arm64

cross-build-linux-s390x:
	+$(MAKE) _build_local GOOS=linux GOARCH=s390x
.PHONY: cross-build-linux-s390x

cross-build: clean_build_local cross-build-linux-amd64 cross-build-linux-arm64 cross-build-linux-s390x copy_build_local
.PHONY: cross-build

### toolkit ###
tidy-vendor:
	go mod tidy -v
	go mod vendor

ginkgo-set:
	mkdir -p $(GOBIN)
	mkdir -p $(ENVTEST_ASSETS_DIR)
	@test -f $(ENVTEST_ASSETS_DIR)/ginkgo || \
	 (go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo@v2.4.0  && \
	  cp $(GOBIN)/ginkgo $(ENVTEST_ASSETS_DIR)/ginkgo)

container_test:
	$(CTR_CMD) run --rm \
		-v $(base_dir):/kepler:Z\
		-v ~/.kube/config:/tmp/.kube/config \
		-e GOROOT=/usr/local/go -e PATH=$(PATH):/usr/local/go/bin \
		--network host \
		-w /kepler \
		--privileged \
		$(BUILDER_IMAGE) \
		/bin/sh -c ' \
			yum install -y cpuid && \
			cd doc/ && \
			./dev/prepare_dev_env.sh && \
			cd - && git config --global --add safe.directory /kepler && \
			make test-verbose'

test: ginkgo-set tidy-vendor
	@echo TAGS=$(GO_BUILD_TAGS)
	@$(GOENV) go test -tags $(GO_BUILD_TAGS) ./... --race --bench=. -cover --count=1 --vet=all

test-verbose: ginkgo-set tidy-vendor
	@echo TAGS=$(GO_BUILD_TAGS)
	@echo GOENV=$(GOENV)
	@$(GOENV) go test -tags $(GO_BUILD_TAGS) -covermode=atomic -coverprofile=coverage.out -v $$(go list ./... | grep pkg | grep -v bpfassets) --race --bench=. -cover --count=1 --vet=all
	
test-mac-verbose: ginkgo-set
	@echo TAGS=$(GO_BUILD_TAGS)
	@go test $$(go list ./... | grep pkg | grep -v bpfassets) --race --bench=. -cover --count=1 --vet=all

escapes_detect: tidy-vendor
	@$(GOENV) go build -tags $(GO_BUILD_TAGS) -gcflags="-m -l" ./... 2>&1 | grep "escapes to heap" || true

set_govulncheck:
	./hack/tools.sh govulncheck

govulncheck: set_govulncheck tidy-vendor
	@$(GOVULNCHECK) ./... || true

format:
	./automation/presubmit-tests/gofmt.sh

golint:
	@mkdir -p $(base_dir)/.cache/golangci-lint
	$(CTR_CMD) pull golangci/golangci-lint:latest
	$(CTR_CMD) run --tty --rm \
		--volume '$(base_dir)/.cache/golangci-lint:/root/.cache' \
		--volume '$(base_dir):/app' \
		--workdir /app \
		golangci/golangci-lint \
		golangci-lint run --verbose

genlibbpf: kepler.bpf.o


tools:
	hack/tools.sh
.PHONY: tools

### k8s ###
kustomize: ## Download kustomize locally if necessary.
	hack/tools.sh kustomize

build-manifest: kustomize
	./hack/build-manifest.sh "${OPTS}"
.PHONY: build-manifest

cluster-clean: build-manifest
	./hack/cluster-clean.sh
.PHONY: cluster-clean

cluster-deploy:
	./hack/cluster-deploy.sh
.PHONY: cluster-deploy

cluster-up:
	./hack/cluster.sh up
.PHONY: cluster-up

cluster-down:
	./hack/cluster.sh down
.PHONY: cluster-down

e2e:
	./hack/verify.sh integration
.PHONY: e2e

### platform-validation ###

VALIDATION_DOCKERFILE := $(SRC_ROOT)/build/Dockerfile.kepler-validator

build-validator: tidy-vendor format
	@echo TAGS=$(GO_BUILD_TAGS)
	@mkdir -p "$(CROSS_BUILD_BINDIR)/$(GOOS)_$(GOARCH)"
	+@$(GOENV) go build -v -tags ${GO_BUILD_TAGS} -o $(CROSS_BUILD_BINDIR)/$(GOOS)_$(GOARCH)/validator -ldflags $(LDFLAGS) ./cmd/validator/validator.go
	cp $(CROSS_BUILD_BINDIR)/$(GOOS)_$(GOARCH)/validator $(CROSS_BUILD_BINDIR)
.PHONY: build-validator

build-validation-container:
	$(CTR_CMD) build -t $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG) \
		-f $(VALIDATION_DOCKERFILE) .
.PHONY: build-validation-container

get-power:
	$(CTR_CMD) run -i --rm -v $(SRC_ROOT)/e2e/platform-validation:/output $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG) /usr/bin/validator
.PHONY: get-power

get-env:
	$(CTR_CMD) run -i --rm -v $(SRC_ROOT)/e2e/platform-validation:/output $(IMAGE_REPO)/$(IMAGE_NAME):$(IMAGE_TAG) /usr/bin/validator -gen-env=true
.PHONY: get-env

platform-validation: ginkgo-set get-env
	./hack/verify.sh platform
.PHONY: platform-validation

check: tidy-vendor set_govulncheck govulncheck format golint test
.PHONY: check
