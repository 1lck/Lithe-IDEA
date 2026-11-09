# Builds, runs, tests and packages the Lithe desktop client. Run it from desktop/, or with
# make -C desktop from the repository root. Every Go command goes through
# scripts/desktop/desktop-go.sh, which first builds the pinned Lithe-core-rust library and points
# cgo at it; a plain go build or go test does not link.
#
#   make build                  dev-tagged development build; the Dock icon shows Dev
#   make run | dev              dev-tagged development build, then start (Dock badge: Dev)
#   make test                   all tests
#   make check                  gofmt, vet and tests, as Desktop CI runs them
#   make package                untagged release build and host formats in dist/desktop/<os>-<arch>/
#   make package ARCH=amd64 NO_SIGN=1
#   make release NO_SIGN=1      macOS arm64+amd64, Windows amd64, or the Linux host architecture
#
# LITHE_CORE_RUST_DIR=<checkout> builds against a local Lithe-core-rust checkout instead of the
# pinned revision; see scripts/desktop/build-desktop-core.sh.
#
# On Windows, run it from Git Bash; MinGW-w64 provides GNU make as mingw32-make.

SCRIPTS := ../scripts/desktop
# go build -o writes the exact name it is given, so the Windows build needs the .exe suffix that
# go env GOEXE reports; it is empty on macOS and Linux.
BIN := ../.artifacts/desktop/bin/lithe$(shell go env GOEXE)
ARCH ?= $(shell go env GOARCH)
FORMAT ?=
# The version in viva.toml, which the client embeds and displays.
VERSION := $(shell sed -n 's/^version = "\([0-9.]*\)"$$/\1/p' viva.toml)
PACKAGE_FLAGS = --arch $(ARCH) $(if $(FORMAT),--format $(FORMAT)) $(if $(NO_SIGN),--no-sign)

.DEFAULT_GOAL := help
.PHONY: help core build run dev test vet fmt fmt-check check version package release clean

help:
	@echo "make run | dev     dev-tagged development build and start (Dock badge: Dev)"
	@echo "make build         dev-tagged development build (Dock badge: Dev)"
	@echo "make core          build and stage the debug Lithe-core-rust library only"
	@echo "make test | vet    go test or go vet of every package"
	@echo "make version       print the version in viva.toml"
	@echo "make fmt           gofmt -w every file; make fmt-check only lists them"
	@echo "make check         fmt-check, vet and test"
	@echo "make package       untagged release build in dist/desktop/<os>-<arch>/ (no Dev badge; ARCH, FORMAT, NO_SIGN=1)"
	@echo "make release       macOS arm64+amd64, Windows amd64, or the Linux host architecture"
	@echo "make clean         remove the client builds and packages (the core cache stays)"

core:
	$(SCRIPTS)/build-desktop-core.sh --debug

build:
	$(SCRIPTS)/desktop-go.sh build -tags dev -o $(BIN) ./cmd/lithe

run dev: build
	$(BIN)

test:
	$(SCRIPTS)/desktop-go.sh test ./...
	$(SCRIPTS)/desktop-go.sh test -tags dev ./internal/buildinfo

vet:
	$(SCRIPTS)/desktop-go.sh vet ./...
	$(SCRIPTS)/desktop-go.sh vet -tags dev ./...

fmt:
	gofmt -w .

fmt-check:
	@unformatted="$$(gofmt -l .)"; if [ -n "$$unformatted" ]; then echo "gofmt would change:"; echo "$$unformatted"; exit 1; fi

check: fmt-check vet test

version:
	@printf '%s\n' "$(VERSION)"

package:
	$(SCRIPTS)/package-desktop.sh $(PACKAGE_FLAGS)

release:
	@case "$$(go env GOOS)" in \
		darwin) $(MAKE) package ARCH=arm64 && $(MAKE) package ARCH=amd64 ;; \
		windows) $(MAKE) package ARCH=amd64 ;; \
		linux) $(MAKE) package ARCH=$(ARCH) ;; \
		*) echo "unsupported host OS: $$(go env GOOS)" >&2; exit 2 ;; \
	esac

clean:
	rm -rf ../.artifacts/desktop/bin ../dist/desktop
