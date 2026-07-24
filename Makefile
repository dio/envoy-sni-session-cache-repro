SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c

RELEASE_TAG := pr45982-f5ed8537
RELEASE_BASE_URL := https://github.com/dio/envoy-sni-session-cache-repro/releases/download/$(RELEASE_TAG)
UPSTREAM_BASE_URL := https://archive.tetratelabs.io/envoy/download/dev
UPSTREAM_SHA := 8cac4c63e8a905baa1f53020dd69f5914777a506
CANDIDATE_SHA := f5ed853725477db07c606a44a0cebce57ea8d1ed
ARTIFACT_DIR := .artifacts

HOST_PLATFORM := $(shell uname -s)/$(shell uname -m)

ifeq ($(HOST_PLATFORM),Darwin/arm64)
PLATFORM := darwin-arm64
CHECKSUM_COMMAND := shasum -a 256
else ifeq ($(HOST_PLATFORM),Linux/x86_64)
PLATFORM := linux-amd64
CHECKSUM_COMMAND := sha256sum
else
$(error Unsupported platform $(HOST_PLATFORM); supported platforms are Darwin/arm64 and Linux/x86_64)
endif

UPSTREAM_ARCHIVE_NAME := envoy-dev-$(PLATFORM).tar.xz
CANDIDATE_ARCHIVE_NAME := envoy-pr45982-f5ed8537-$(PLATFORM).tar.xz
UPSTREAM_ARCHIVE := $(ARTIFACT_DIR)/$(UPSTREAM_ARCHIVE_NAME)
CANDIDATE_ARCHIVE := $(ARTIFACT_DIR)/$(CANDIDATE_ARCHIVE_NAME)
CHECKSUMS := $(ARTIFACT_DIR)/SHA256SUMS
UPSTREAM_BIN := $(ARTIFACT_DIR)/envoy-dev-$(PLATFORM)/bin/envoy
CANDIDATE_BIN := $(ARTIFACT_DIR)/envoy-pr45982-f5ed8537-$(PLATFORM)/bin/envoy

.PHONY: help download verify repro clean

help:
	@printf '%s\n' \
	  'make verify  Download, checksum, inspect, and verify both Envoy binaries' \
	  'make repro   Verify the binaries, then reproduce the issue and fix' \
	  'make clean   Remove downloaded and extracted artifacts'

download: $(UPSTREAM_ARCHIVE) $(CANDIDATE_ARCHIVE) $(CHECKSUMS)

$(ARTIFACT_DIR):
	mkdir -p "$@"

$(UPSTREAM_ARCHIVE): | $(ARTIFACT_DIR)
	curl --fail --location --retry 3 \
	  "$(UPSTREAM_BASE_URL)/$(UPSTREAM_ARCHIVE_NAME)" \
	  --output "$@"

$(CANDIDATE_ARCHIVE): | $(ARTIFACT_DIR)
	curl --fail --location --retry 3 \
	  "$(RELEASE_BASE_URL)/$(CANDIDATE_ARCHIVE_NAME)" \
	  --output "$@"

$(CHECKSUMS): | $(ARTIFACT_DIR)
	curl --fail --location --retry 3 \
	  "$(RELEASE_BASE_URL)/SHA256SUMS" \
	  --output "$@"

verify: download
	grep "  $(CANDIDATE_ARCHIVE_NAME)$$" "$(CHECKSUMS)" | \
	  (cd "$(ARTIFACT_DIR)" && $(CHECKSUM_COMMAND) -c -)
	tar -tJf "$(CANDIDATE_ARCHIVE)" >/dev/null
	for directory in \
	  "$(ARTIFACT_DIR)/envoy-dev-$(PLATFORM)" \
	  "$(ARTIFACT_DIR)/envoy-pr45982-f5ed8537-$(PLATFORM)"; do \
	  if [[ -e "$$directory" ]]; then \
	    rm -r -- "$$directory"; \
	  fi; \
	done
	tar -xJf "$(UPSTREAM_ARCHIVE)" -C "$(ARTIFACT_DIR)"
	tar -xJf "$(CANDIDATE_ARCHIVE)" -C "$(ARTIFACT_DIR)"
	chmod +x "$(UPSTREAM_BIN)" "$(CANDIDATE_BIN)"
	"$(UPSTREAM_BIN)" --version 2>&1 | grep -Fq "$(UPSTREAM_SHA)"
	"$(CANDIDATE_BIN)" --version 2>&1 | grep -Fq "$(CANDIDATE_SHA)"
	"$(UPSTREAM_BIN)" --version 2>&1 | sed -n '/ version:/p'
	"$(CANDIDATE_BIN)" --version 2>&1 | sed -n '/ version:/p'

repro: verify
	./reproduce.sh "$(UPSTREAM_BIN)" "$(CANDIDATE_BIN)"

clean:
	if [[ -d "$(ARTIFACT_DIR)" ]]; then rm -r -- "$(ARTIFACT_DIR)"; fi
