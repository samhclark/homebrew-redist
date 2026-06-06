SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

SMOLVM_VERSION := 1.0.1
SMOLVM_SHA256 := 2192f54c53a8621ecd038a1bbdee1cc917e111abe3d935e81bdaee51daccc862
LIBKRUN_REV := e85a254ac1a1a2be58fb5b54e10937fecc55d268
LIBKRUN_SHA256 := 627bddfe16be6b144a7582fea79fb2d87175df9927d3dfeffbcd4ce7d6d5b6b3
LIBKRUNFW_REV := 516ceece6aed60ccc84ac8faa459885062e39400
LIBKRUNFW_SHA256 := c9c43a5d54a239f2bb69f1c6762ad40854a8f5c996a9890872bd3ca39d52ba5d
LIBKRUNFW_VERSION := 5.4.0
KERNEL_VERSION := 6.12.87
KERNEL_SHA256 := cc12a7644b4cef9e06627b29de8753e22b3d076703a9b52be84263e05c8b9830
PYELFTOOLS_VERSION := 0.32
PYELFTOOLS_SHA256 := 6de90ee7b8263e740c8715a925382d4099b354f29ac48ea40d840cf7aa14ace5

HOST_OS := $(shell uname -s)
HOST_ARCH := $(shell uname -m)
JOBS ?= $(shell command -v nproc >/dev/null && nproc || sysctl -n hw.ncpu)
BUILD_DIR ?= $(CURDIR)/.build
DOWNLOAD_DIR := $(BUILD_DIR)/downloads
SOURCE_DIR := $(BUILD_DIR)/src
TARGET_DIR := $(BUILD_DIR)/target
STAGE_DIR := $(BUILD_DIR)/stage
CARGO_HOME := $(BUILD_DIR)/cargo-home

SMOLVM_ARCHIVE := $(DOWNLOAD_DIR)/smolvm-$(SMOLVM_VERSION).tar.gz
LIBKRUN_ARCHIVE := $(DOWNLOAD_DIR)/libkrun-$(LIBKRUN_REV).tar.gz
LIBKRUNFW_ARCHIVE := $(DOWNLOAD_DIR)/libkrunfw-$(LIBKRUNFW_REV).tar.gz
KERNEL_ARCHIVE := $(DOWNLOAD_DIR)/linux-$(KERNEL_VERSION).tar.xz
PYELFTOOLS_ARCHIVE := $(DOWNLOAD_DIR)/pyelftools-$(PYELFTOOLS_VERSION).tar.gz

SMOLVM_SRC := $(SOURCE_DIR)/smolvm
LIBKRUN_SRC := $(SOURCE_DIR)/libkrun
LIBKRUNFW_SRC := $(SOURCE_DIR)/libkrunfw
PYELFTOOLS_SRC := $(SOURCE_DIR)/pyelftools
RUNTIME_SRC := $(SOURCE_DIR)/runtime
PREPARED := $(SOURCE_DIR)/.prepared

ifeq ($(HOST_ARCH),x86_64)
GUEST_ARCH := x86_64
ZIG_TARGET := x86_64-linux-musl
else ifneq (,$(filter $(HOST_ARCH),aarch64 arm64))
GUEST_ARCH := aarch64
ZIG_TARGET := aarch64-linux-musl
else
$(error Unsupported architecture: $(HOST_ARCH))
endif

ifeq ($(HOST_OS),Darwin)
ifneq ($(HOST_ARCH),arm64)
$(error smolvm only supports macOS on arm64)
endif
RUNTIME_PLATFORM := darwin-arm64
RUNTIME_SHA256 := d6a2830cfa7087a935590b0fed859c59bda83410e510a75c0ae5add8c9d21700
LIBKRUN_NAME := libkrun.dylib
else ifeq ($(HOST_OS),Linux)
ifeq ($(GUEST_ARCH),aarch64)
RUNTIME_PLATFORM := linux-arm64
RUNTIME_SHA256 := c8c6cf8dbc4427ca28c356fe8c27e49749f6691fbda058daf09b2643cd688399
else
RUNTIME_PLATFORM := linux-x86_64
RUNTIME_SHA256 := a4c85e8b3e14e0df7976eb00a9dbdb55e2d90d7f2a0e8c237e8518030496d34a
endif
LIBKRUN_NAME := libkrun.so
else
$(error Unsupported operating system: $(HOST_OS))
endif

RUNTIME_ARCHIVE := $(DOWNLOAD_DIR)/smolvm-$(SMOLVM_VERSION)-$(RUNTIME_PLATFORM).tar.gz
INIT_KRUN := $(LIBKRUN_SRC)/init/init
LIBKRUN_OUTPUT := $(TARGET_DIR)/libkrun/release/$(LIBKRUN_NAME)
LIBKRUNFW_MARKER := $(STAGE_DIR)/lib/.libkrunfw-built
SMOLVM_OUTPUT := $(TARGET_DIR)/smolvm/release/smolvm
BUILD_COMPLETE := $(STAGE_DIR)/.complete

BREW_PATH = $(shell brew --prefix gpatch)/bin:$(shell brew --prefix flex)/bin:$(shell brew --prefix bison)/bin:$(PATH)
BREW_PKG_CONFIG_PATH = $(shell brew --prefix elfutils)/lib/pkgconfig:$(shell brew --prefix openssl@3)/lib/pkgconfig:$(shell brew --prefix zlib-ng-compat)/lib/pkgconfig:$(shell brew --prefix zstd)/lib/pkgconfig
KERNEL_CC ?= $(shell command -v gcc || command -v clang)
MKFS_EXT4 = $(shell brew --prefix e2fsprogs)/sbin/mkfs.ext4

FETCH_ARCHIVES := $(SMOLVM_ARCHIVE) $(LIBKRUN_ARCHIVE) $(RUNTIME_ARCHIVE)
ifeq ($(HOST_OS),Linux)
FETCH_ARCHIVES += $(LIBKRUNFW_ARCHIVE) $(KERNEL_ARCHIVE) $(PYELFTOOLS_ARCHIVE)
endif

.PHONY: help deps fetch verify prepare build build-init build-libkrun
.PHONY: build-libkrunfw build-smolvm stage check formula-check clean

help:
	@printf '%s\n' \
	  'smolvm source-build helper' \
	  '' \
	  '  make deps          Install Homebrew dependencies from Brewfile' \
	  '  make fetch         Download all pinned source/runtime archives' \
	  '  make verify        Verify every downloaded archive checksum' \
	  '  make build         Recreate the proven CPU-only distribution in .build/stage' \
	  '  make check         Inspect the manually built artifacts' \
	  '  make formula-check Run style, audit, and the installed Formula test' \
	  '  make clean         Remove generated .build state' \
	  '' \
	  'The build is intentionally GPU-disabled. See docs/smolvm-source-build.md.'

deps:
	brew bundle --file="$(CURDIR)/Brewfile"

fetch: $(FETCH_ARCHIVES)

$(DOWNLOAD_DIR):
	mkdir -p "$@"

$(SMOLVM_ARCHIVE): | $(DOWNLOAD_DIR)
	curl -fL --retry 3 -o "$@.tmp" \
	  "https://github.com/smol-machines/smolvm/archive/refs/tags/v$(SMOLVM_VERSION).tar.gz"
	mv "$@.tmp" "$@"

$(LIBKRUN_ARCHIVE): | $(DOWNLOAD_DIR)
	curl -fL --retry 3 -o "$@.tmp" \
	  "https://github.com/smol-machines/libkrun/archive/$(LIBKRUN_REV).tar.gz"
	mv "$@.tmp" "$@"

$(LIBKRUNFW_ARCHIVE): | $(DOWNLOAD_DIR)
	curl -fL --retry 3 -o "$@.tmp" \
	  "https://github.com/smol-machines/libkrunfw/archive/$(LIBKRUNFW_REV).tar.gz"
	mv "$@.tmp" "$@"

$(KERNEL_ARCHIVE): | $(DOWNLOAD_DIR)
	curl -fL --retry 3 -o "$@.tmp" \
	  "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$(KERNEL_VERSION).tar.xz"
	mv "$@.tmp" "$@"

$(PYELFTOOLS_ARCHIVE): | $(DOWNLOAD_DIR)
	curl -fL --retry 3 -o "$@.tmp" \
	  "https://files.pythonhosted.org/packages/b9/ab/33968940b2deb3d92f5b146bc6d4009a5f95d1d06c148ea2f9ee965071af/pyelftools-$(PYELFTOOLS_VERSION).tar.gz"
	mv "$@.tmp" "$@"

$(RUNTIME_ARCHIVE): | $(DOWNLOAD_DIR)
	curl -fL --retry 3 -o "$@.tmp" \
	  "https://github.com/smol-machines/smolvm/releases/download/v$(SMOLVM_VERSION)/smolvm-$(SMOLVM_VERSION)-$(RUNTIME_PLATFORM).tar.gz"
	mv "$@.tmp" "$@"

verify: fetch
	@check() { \
	  expected="$$1"; file="$$2"; \
	  if command -v sha256sum >/dev/null; then \
	    actual="$$(sha256sum "$$file" | awk '{print $$1}')"; \
	  else \
	    actual="$$(shasum -a 256 "$$file" | awk '{print $$1}')"; \
	  fi; \
	  if [[ "$$actual" != "$$expected" ]]; then \
	    printf 'checksum mismatch: %s\nexpected: %s\nactual:   %s\n' "$$file" "$$expected" "$$actual" >&2; \
	    exit 1; \
	  fi; \
	  printf 'verified %s\n' "$$file"; \
	}; \
	check "$(SMOLVM_SHA256)" "$(SMOLVM_ARCHIVE)"; \
	check "$(LIBKRUN_SHA256)" "$(LIBKRUN_ARCHIVE)"; \
	if [[ "$(HOST_OS)" == "Linux" ]]; then \
	  check "$(LIBKRUNFW_SHA256)" "$(LIBKRUNFW_ARCHIVE)"; \
	  check "$(KERNEL_SHA256)" "$(KERNEL_ARCHIVE)"; \
	  check "$(PYELFTOOLS_SHA256)" "$(PYELFTOOLS_ARCHIVE)"; \
	fi; \
	check "$(RUNTIME_SHA256)" "$(RUNTIME_ARCHIVE)"

prepare: $(PREPARED)

$(PREPARED): verify Resources/smolvm/Cargo.lock
	mkdir -p "$(SOURCE_DIR)" "$(TARGET_DIR)" "$(STAGE_DIR)/lib" "$(CARGO_HOME)"
	mkdir -p "$(SMOLVM_SRC)" "$(LIBKRUN_SRC)" "$(RUNTIME_SRC)"
	tar -xf "$(SMOLVM_ARCHIVE)" -C "$(SMOLVM_SRC)" --strip-components=1
	tar -xf "$(LIBKRUN_ARCHIVE)" -C "$(LIBKRUN_SRC)" --strip-components=1
	tar -xf "$(RUNTIME_ARCHIVE)" -C "$(RUNTIME_SRC)" --strip-components=1
	cp Resources/smolvm/Cargo.lock "$(SMOLVM_SRC)/Cargo.lock"
ifeq ($(HOST_OS),Linux)
	mkdir -p "$(LIBKRUNFW_SRC)" "$(PYELFTOOLS_SRC)"
	tar -xf "$(LIBKRUNFW_ARCHIVE)" -C "$(LIBKRUNFW_SRC)" --strip-components=1
	tar -xf "$(PYELFTOOLS_ARCHIVE)" -C "$(PYELFTOOLS_SRC)" --strip-components=1
	mkdir -p "$(LIBKRUNFW_SRC)/tarballs"
	cp "$(KERNEL_ARCHIVE)" "$(LIBKRUNFW_SRC)/tarballs/linux-$(KERNEL_VERSION).tar.xz"
endif
	perl -0pi -e 's/#include <unistd\.h>\n/#include <unistd.h>\n\nextern char **environ;\n/' \
	  "$(LIBKRUN_SRC)/init/init.c"
	perl -pi -e 's/__environ/environ/g' "$(LIBKRUN_SRC)/init/init.c"
	perl -0pi -e 's/    let sources = \[\n/    let sources = [\n        std::env::current_exe()\n            .ok()\n            .and_then(|path| path.parent().map(|dir| dir.join("init.krun"))),\n/' \
	  "$(SMOLVM_SRC)/src/vm/backend/libkrun.rs"
	touch "$@"

build: $(BUILD_COMPLETE)

build-init: $(INIT_KRUN)

$(INIT_KRUN): $(PREPARED)
	env \
	  ZIG_GLOBAL_CACHE_DIR="$(BUILD_DIR)/zig-global-cache" \
	  ZIG_LOCAL_CACHE_DIR="$(BUILD_DIR)/zig-local-cache" \
	  zig cc -target "$(ZIG_TARGET)" -O2 -static -s -Wall \
	    -o "$@" "$(LIBKRUN_SRC)/init/init.c" "$(LIBKRUN_SRC)/init/dhcp.c"

build-libkrun: $(LIBKRUN_OUTPUT)

$(LIBKRUN_OUTPUT): $(INIT_KRUN)
	cd "$(LIBKRUN_SRC)" && env \
	  CARGO_HOME="$(CARGO_HOME)" \
	  CARGO_TARGET_DIR="$(TARGET_DIR)/libkrun" \
	  KRUN_INIT_BINARY_PATH="$(INIT_KRUN)" \
	  RUSTFLAGS="$${RUSTFLAGS:+$$RUSTFLAGS }-C relro-level=partial" \
	  cargo build --release --locked -p libkrun --features blk,net
	cp "$@" "$(STAGE_DIR)/lib/$(LIBKRUN_NAME)"
ifeq ($(HOST_OS),Linux)
	ln -sfn "libkrun.so" "$(STAGE_DIR)/lib/libkrun.so.1"
endif

build-libkrunfw: $(LIBKRUNFW_MARKER)

$(LIBKRUNFW_MARKER): $(PREPARED)
ifeq ($(HOST_OS),Linux)
	# Do not use `make -C`: its implicit `-w` reaches the kernel as a target.
	# Use the real compiler, not Homebrew's Superenv shim. The shim removes the
	# kernel's per-file -O0 and breaks crypto/jitterentropy.c.
	cd "$(LIBKRUNFW_SRC)" && env \
	  PATH="$(BREW_PATH)" \
	  PKG_CONFIG_PATH="$(BREW_PKG_CONFIG_PATH)$${PKG_CONFIG_PATH:+:$$PKG_CONFIG_PATH}" \
	  PYTHONPATH="$(PYELFTOOLS_SRC)" \
	  CC="$(KERNEL_CC)" \
	  HOSTCC="$(KERNEL_CC)" \
	  make -j"$(JOBS)" "GUESTARCH=$(GUEST_ARCH)"
	cp "$(LIBKRUNFW_SRC)/libkrunfw.so.$(LIBKRUNFW_VERSION)" "$(STAGE_DIR)/lib/"
	ln -sfn "libkrunfw.so.$(LIBKRUNFW_VERSION)" "$(STAGE_DIR)/lib/libkrunfw.so.5"
	ln -sfn "libkrunfw.so.5" "$(STAGE_DIR)/lib/libkrunfw.so"
else
	cp "$(RUNTIME_SRC)/lib/libkrunfw.5.dylib" "$(STAGE_DIR)/lib/"
	ln -sfn "libkrunfw.5.dylib" "$(STAGE_DIR)/lib/libkrunfw.dylib"
endif
	touch "$@"

build-smolvm: $(SMOLVM_OUTPUT)

$(SMOLVM_OUTPUT): $(LIBKRUN_OUTPUT) $(LIBKRUNFW_MARKER)
	cd "$(SMOLVM_SRC)" && env \
	  CARGO_HOME="$(CARGO_HOME)" \
	  CARGO_TARGET_DIR="$(TARGET_DIR)/smolvm" \
	  LIBKRUN_BUNDLE="$(STAGE_DIR)/lib" \
	  cargo build --release --locked --bin smolvm
ifeq ($(HOST_OS),Darwin)
	codesign --force --sign - --entitlements "$(SMOLVM_SRC)/smolvm.entitlements" "$@"
endif

stage: $(BUILD_COMPLETE)

$(BUILD_COMPLETE): $(SMOLVM_OUTPUT)
	cp "$(SMOLVM_OUTPUT)" "$(STAGE_DIR)/smolvm-bin"
	cp "$(SMOLVM_SRC)/scripts/smolvm-wrapper.sh" "$(STAGE_DIR)/smolvm"
	chmod 0755 "$(STAGE_DIR)/smolvm" "$(STAGE_DIR)/smolvm-bin"
	rm -rf "$(STAGE_DIR)/agent-rootfs"
	cp -a "$(RUNTIME_SRC)/agent-rootfs" "$(STAGE_DIR)/agent-rootfs"
	cp "$(INIT_KRUN)" "$(STAGE_DIR)/init.krun"
	cp "$(INIT_KRUN)" "$(STAGE_DIR)/agent-rootfs/init.krun"
	chmod 0755 "$(STAGE_DIR)/init.krun" "$(STAGE_DIR)/agent-rootfs/init.krun"
	dd if=/dev/zero of="$(STAGE_DIR)/storage-template.ext4" bs=1 count=0 seek=536870912 2>/dev/null
	"$(MKFS_EXT4)" -F -q -m 0 -L smolvm "$(STAGE_DIR)/storage-template.ext4"
	dd if=/dev/zero of="$(STAGE_DIR)/overlay-template.ext4" bs=1 count=0 seek=536870912 2>/dev/null
	"$(MKFS_EXT4)" -F -q -m 0 -L smolvm-overlay "$(STAGE_DIR)/overlay-template.ext4"
	touch "$@"

check: $(BUILD_COMPLETE)
	"$(STAGE_DIR)/smolvm" --version
	file "$(STAGE_DIR)/smolvm-bin" "$(STAGE_DIR)/init.krun" \
	  "$(STAGE_DIR)/agent-rootfs/init.krun" "$(STAGE_DIR)/lib/$(LIBKRUN_NAME)"
	ls -l "$(STAGE_DIR)/lib"
	du -h "$(STAGE_DIR)/storage-template.ext4" "$(STAGE_DIR)/overlay-template.ext4"

formula-check:
	env HOMEBREW_CACHE="$(BUILD_DIR)/homebrew-cache" HOMEBREW_NO_AUTO_UPDATE=1 \
	  HOMEBREW_NO_INSTALL_FROM_API=1 \
	  brew style Formula/smolvm.rb
	@tap_repo="$$(brew --repo samhclark/redist)"; \
	if ! cmp -s Formula/smolvm.rb "$$tap_repo/Formula/smolvm.rb"; then \
	  printf '%s\n' \
	    "The registered tap does not contain this Formula revision." \
	    "Sync Formula/smolvm.rb to $$tap_repo before running audit or test."; \
	  exit 1; \
	fi
	env HOMEBREW_CACHE="$(BUILD_DIR)/homebrew-cache" HOMEBREW_NO_AUTO_UPDATE=1 \
	  HOMEBREW_NO_INSTALL_FROM_API=1 \
	  brew audit --strict --formula samhclark/redist/smolvm
	env HOMEBREW_CACHE="$(BUILD_DIR)/homebrew-cache" HOMEBREW_NO_AUTO_UPDATE=1 \
	  HOMEBREW_NO_INSTALL_FROM_API=1 \
	  brew test samhclark/redist/smolvm

clean:
	rm -rf "$(BUILD_DIR)"
