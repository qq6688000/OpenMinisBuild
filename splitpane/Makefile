# Keep a single release pipeline: real Apple clang/ld, both the tweak and
# preference bundle, signature verification, and versioned Debian packaging.
# The old Linux Theos wrapper silently selected arm64 + LLD and omitted prefs.
PYTHON ?= python3
PROJECT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
.DEFAULT_GOAL := all

.PHONY: all package apple-build check-toolchain clean help
all: package

package apple-build:
	$(PYTHON) "$(PROJECT_DIR)build-apple.py"

check-toolchain:
	$(PYTHON) "$(PROJECT_DIR)build-apple.py" --check-toolchain

clean:
	rm -rf -- "$(PROJECT_DIR)dist-apple"

help:
	@printf '%s\n' \
	  'make package          Build/verify both binaries and package (macOS + full Xcode).' \
	  'make check-toolchain  Check tool identities only; not a successful product build.' \
	  'make clean            Remove generated dist-apple output only.'
