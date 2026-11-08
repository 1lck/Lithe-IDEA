# Builds, runs, tests and packages the Lithe desktop client. Run it from desktop/, or with
# make -C desktop from the repository root. Every Go command goes through
# scripts/desktop/desktop-go.sh, which first builds the pinned Lithe-core-rust library and points
# cgo at it; a plain go build or go test does not link.
#
#   make run                    debug build, then start the client in the foreground
#   make test                   all tests
#   make check                  gofmt, vet and tests, as Desktop CI runs them
#   make package                release core, app, zip and dmg in dist/desktop/<arch>/
#   make package ARCH=amd64 NO_SIGN=1
#   make release NO_SIGN=1      make package for arm64 and amd64, as Desktop Release does
#
# LITHE_CORE_RUST_DIR=<checkout> builds against a local Lithe-core-rust checkout instead of the
# pinned revision; see scripts/desktop/build-desktop-core.sh.

SCRIPTS := ../scripts/desktop
BIN := ../.artifacts/desktop/bin/lithe
ARCH ?= $(shell go env GOARCH)
FORMAT ?= app,zip,dmg
# The version in viva.toml, which the client shows; package-desktop.sh reads it the same way.
VERSION := $(shell sed -n 's/^version = "\([0-9.]*\)"$$/\1/p' viva.toml)
PACKAGE_FLAGS = --arch $(ARCH) --format $(FORMAT) $(if $(NO_SIGN),--no-sign)

.DEFAULT_GOAL := help
.PHONY: help core build run dev test vet fmt fmt-check check package release clean

help:
	@echo "make run | dev     debug build and start the client"
	@echo "make build         debug build into .artifacts/desktop/bin/lithe"
	@echo "make core          build and stage the debug Lithe-core-rust library only"
	@echo "make test | vet    go test or go vet of every package"
	@echo "make fmt           gofmt -w every file; make fmt-check only lists them"
	@echo "make check         fmt-check, vet and test"
	@echo "make package       app, zip and dmg in dist/desktop/<arch>/ (ARCH, FORMAT, NO_SIGN=1)"
	@echo "make release       make package for arm64 and amd64"
	@echo "make clean         remove the client builds and packages (the core cache stays)"

core:
	$(SCRIPTS)/build-desktop-core.sh --debug

build:
	$(SCRIPTS)/desktop-go.sh build -ldflags "-X main.version=$(VERSION)" -o $(BIN) ./cmd/lithe

run dev: build
	$(BIN)

test:
	$(SCRIPTS)/desktop-go.sh test ./...

vet:
	$(SCRIPTS)/desktop-go.sh vet ./...

fmt:
	gofmt -w .

fmt-check:
	@unformatted="$$(gofmt -l .)"; if [ -n "$$unformatted" ]; then echo "gofmt would change:"; echo "$$unformatted"; exit 1; fi

check: fmt-check vet test

package:
	$(SCRIPTS)/package-desktop.sh $(PACKAGE_FLAGS)

release:
	$(MAKE) package ARCH=arm64
	$(MAKE) package ARCH=amd64

clean:
	rm -rf ../.artifacts/desktop/bin ../dist/desktop
