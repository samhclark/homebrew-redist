SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:

SMOLVM_VERSION := 1.3.8
SMOLVM_SHA256 := 3e5904cb16cbb363531107d7f8872cc770e2368a1ebcbfe4d63b92517594c877
LIBKRUN_REV := f11d9dc75c6d050ed6d81ea5fd86910256862546
LIBKRUN_SHA256 := fcc637d752cfd9eec4d5eadedb1bfc7c80ddb31329f158cca11e906c946331ee
LIBKRUNFW_REV := 392573f22f46bb1f2c864476ba3764170fe29507
LIBKRUNFW_SHA256 := 0b1c9cb0e4c01dc9bcdf3c9cec8e32f551e8cc5532d1a086336ffbddb69efbc6
LIBKRUNFW_VERSION := 5.5.0
KERNEL_VERSION := 6.12.91
KERNEL_SHA256 := fbfc5216bcf5b17ea6dd2a07608b589e15e6895e38252291ae23221b64336729
MUSL_VERSION := 1.2.5
MUSL_SHA256 := a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4
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
SMOLVM_BIN ?= $(shell prefix="$$(brew --prefix smolvm 2>/dev/null)" && printf '%s/bin/smolvm' "$$prefix")
SMOKE_TIMEOUT ?= 120
SMOKE_GUEST_TIMEOUT ?= 60s
SMOKE_MARKER := smolvm-boot-smoke-ok
GPU_SMOKE_TIMEOUT ?= 180
GPU_SMOKE_GUEST_TIMEOUT ?= 120s
GPU_SMOKE_MARKER := smolvm-gpu-device-smoke-ok
VULKAN_SMOKE_IMAGE ?= fedora:42
VULKAN_SMOKE_COPR ?= slp/mesa-libkrun-vulkan
VULKAN_SMOKE_TIMEOUT ?= 900
VULKAN_SMOKE_GUEST_TIMEOUT ?= 840s
VULKAN_SMOKE_MARKER := smolvm-vulkan-smoke-ok
PODMAN ?= podman
VULKAN_COMPUTE_LOCAL_IMAGE ?= localhost/smolvm-vulkan-smoke:dev
VULKAN_COMPUTE_IMAGE ?= ghcr.io/samhclark/smolvm-vulkan-smoke:main
VULKAN_COMPUTE_TIMEOUT ?= 600
VULKAN_COMPUTE_GUEST_TIMEOUT ?= 540s
VULKAN_COMPUTE_MARKER := smolvm-vulkan-compute-smoke-ok
VULKAN_COMPUTE_IIDFILE := $(BUILD_DIR)/vulkan-smoke-image-id

SMOLVM_ARCHIVE := $(DOWNLOAD_DIR)/smolvm-$(SMOLVM_VERSION).tar.gz
LIBKRUN_ARCHIVE := $(DOWNLOAD_DIR)/libkrun-$(LIBKRUN_REV).tar.gz
LIBKRUNFW_ARCHIVE := $(DOWNLOAD_DIR)/libkrunfw-$(LIBKRUNFW_REV).tar.gz
KERNEL_ARCHIVE := $(DOWNLOAD_DIR)/linux-$(KERNEL_VERSION).tar.gz
MUSL_ARCHIVE := $(DOWNLOAD_DIR)/musl-$(MUSL_VERSION).tar.gz
PYELFTOOLS_ARCHIVE := $(DOWNLOAD_DIR)/pyelftools-$(PYELFTOOLS_VERSION).tar.gz

SMOLVM_SRC := $(SOURCE_DIR)/smolvm
LIBKRUN_SRC := $(SOURCE_DIR)/libkrun
LIBKRUNFW_SRC := $(SOURCE_DIR)/libkrunfw
MUSL_SRC := $(SOURCE_DIR)/musl
PYELFTOOLS_SRC := $(SOURCE_DIR)/pyelftools
RUNTIME_SRC := $(SOURCE_DIR)/runtime
PREPARED := $(SOURCE_DIR)/.prepared

ifeq ($(HOST_ARCH),x86_64)
GUEST_ARCH := x86_64
ZIG_TARGET := x86_64-linux-musl
RUST_TARGET := x86_64-unknown-linux-musl
RUST_LINKER_ENV := CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER
else ifneq (,$(filter $(HOST_ARCH),aarch64 arm64))
GUEST_ARCH := aarch64
ZIG_TARGET := aarch64-linux-musl
RUST_TARGET := aarch64-unknown-linux-musl
RUST_LINKER_ENV := CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER
else
$(error Unsupported architecture: $(HOST_ARCH))
endif

ifeq ($(HOST_OS),Darwin)
ifneq ($(HOST_ARCH),arm64)
$(error smolvm only supports macOS on arm64)
endif
# The v1.3.8 Darwin archive has a truncated tar stream. The macOS build only
# needs the arm64 Linux guest rootfs from the runtime archive.
RUNTIME_PLATFORM := linux-arm64
RUNTIME_SHA256 := 55a6ef346b4d1c5e1031fa291197be929ba7646d4cb07b47de4577ad07ae2073
LIBKRUN_NAME := libkrun.dylib
LIBKRUN_FEATURES := blk,net
MACOS_CROSS_PATH := $(shell brew --prefix aarch64-elf-gcc)/bin:$(shell brew --prefix aarch64-elf-binutils)/bin:$(shell brew --prefix bison)/bin:$(shell brew --prefix flex)/bin
MACOS_GMAKE := $(shell brew --prefix make)/bin/gmake
MACOS_GPATCH := $(shell brew --prefix gpatch)/bin/gpatch
MACOS_PYTHON := $(shell brew --prefix python@3.14)/bin/python3.14
MACOS_KERNEL_SRC := $(LIBKRUNFW_SRC)/linux-$(KERNEL_VERSION)
MACOS_HOST_INCLUDE := $(LIBKRUNFW_SRC)/host-include
else ifeq ($(HOST_OS),Linux)
ifeq ($(GUEST_ARCH),aarch64)
RUNTIME_PLATFORM := linux-arm64
RUNTIME_SHA256 := 55a6ef346b4d1c5e1031fa291197be929ba7646d4cb07b47de4577ad07ae2073
else
RUNTIME_PLATFORM := linux-x86_64
RUNTIME_SHA256 := 9c784fa666e2bb39c3bf9d81dfee4d50bba11a0a654b80b8556c8103a9e58979
endif
LIBKRUN_NAME := libkrun.so
LIBKRUN_FEATURES := blk,net,gpu
LLVM_LIB := $(shell brew --prefix llvm)/lib
BZIP2_LIB := $(shell brew --prefix bzip2)/lib
LIBEPOXY_LIB := $(shell brew --prefix libepoxy)/lib
VIRGL_PREFIX := $(shell brew --prefix smolvm-virglrenderer)
VIRGL_LIB := $(VIRGL_PREFIX)/lib
VIRGL_LIBEXEC := $(VIRGL_PREFIX)/libexec
GPU_PKG_CONFIG_PATH := $(VIRGL_LIB)/pkgconfig:$(shell brew --prefix xorgproto)/share/pkgconfig
GPU_LIBRARY_PATH := $(VIRGL_LIB):$(BZIP2_LIB)
else
$(error Unsupported operating system: $(HOST_OS))
endif

RUNTIME_ARCHIVE := $(DOWNLOAD_DIR)/smolvm-$(SMOLVM_VERSION)-$(RUNTIME_PLATFORM).tar.gz
INIT_TARGET_DIR := $(TARGET_DIR)/libkrun-init
INIT_KRUN := $(INIT_TARGET_DIR)/$(RUST_TARGET)/release/krun-init
ZIG_CC := $(BUILD_DIR)/zig-cc
LIBKRUN_OUTPUT := $(TARGET_DIR)/libkrun/release/$(LIBKRUN_NAME)
LIBKRUNFW_MARKER := $(STAGE_DIR)/lib/.libkrunfw-built
SMOLVM_OUTPUT := $(TARGET_DIR)/smolvm/release/smolvm
BUILD_COMPLETE := $(STAGE_DIR)/.complete

BREW_PATH = $(shell brew --prefix gpatch)/bin:$(shell brew --prefix flex)/bin:$(shell brew --prefix bison)/bin:$(PATH)
BREW_PKG_CONFIG_PATH = $(shell brew --prefix elfutils)/lib/pkgconfig:$(shell brew --prefix openssl@3)/lib/pkgconfig:$(shell brew --prefix zlib-ng-compat)/lib/pkgconfig:$(shell brew --prefix zstd)/lib/pkgconfig
BREW_LIBRARY_PATH = $(shell brew --prefix elfutils)/lib
KERNEL_CC ?= $(shell command -v gcc || command -v clang)
MKFS_EXT4 = $(shell brew --prefix e2fsprogs)/sbin/mkfs.ext4
GPU_FEATURE_CHECK = python3 -c 'import ctypes, sys; lib = ctypes.CDLL(sys.argv[1]); lib.krun_has_feature.argtypes = [ctypes.c_uint64]; lib.krun_has_feature.restype = ctypes.c_int; assert lib.krun_has_feature(2) == 1, "libkrun GPU feature is disabled"'

FETCH_ARCHIVES := $(SMOLVM_ARCHIVE) $(LIBKRUN_ARCHIVE) $(LIBKRUNFW_ARCHIVE)
FETCH_ARCHIVES += $(KERNEL_ARCHIVE) $(MUSL_ARCHIVE) $(PYELFTOOLS_ARCHIVE)
FETCH_ARCHIVES += $(RUNTIME_ARCHIVE)

.PHONY: help deps fetch verify prepare build build-init build-libkrun
.PHONY: build-libkrunfw build-smolvm stage check formula-check
.PHONY: build-vulkan-smoke-image
.PHONY: smoke-installed smoke-gpu-installed smoke-vulkan-installed
.PHONY: smoke-vulkan-compute-installed
.PHONY: clean

help:
	@printf '%s\n' \
	  'smolvm source-build helper' \
	  '' \
	  '  make deps          Install Homebrew dependencies from Brewfile' \
	  '  make fetch         Download all pinned source/runtime archives' \
	  '  make verify        Verify every downloaded archive checksum' \
	  '  make build         Recreate the source-built distribution in .build/stage' \
	  '  make check         Inspect the manually built artifacts' \
	  '  make formula-check Run style, audit, and the installed Formula test' \
	  '  make smoke-installed Boot the Homebrew-installed smolvm and run a guest command' \
	  '  make smoke-gpu-installed Verify virtio-gpu devices in an Alpine guest' \
	  '  make smoke-vulkan-installed Run vulkaninfo through Venus in a Fedora guest' \
	  '  make build-vulkan-smoke-image Build the Vulkan compute image with Podman' \
	  '  make smoke-vulkan-compute-installed Dispatch a Vulkan compute shader through Venus' \
	  '  make clean         Remove generated .build state' \
	  '' \
	  'Linux builds include GPU support; macOS remains CPU-only.'
	@printf '%s\n' \
	  'The manual macOS path reproduces the source-built smolvm-libkrunfw' \
	  'dylib used by the published dependency Formula.'

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
	  "https://github.com/gregkh/linux/archive/refs/tags/v$(KERNEL_VERSION).tar.gz"
	mv "$@.tmp" "$@"

$(MUSL_ARCHIVE): | $(DOWNLOAD_DIR)
	curl -fL --retry 3 -o "$@.tmp" \
	  "https://musl.libc.org/releases/musl-$(MUSL_VERSION).tar.gz"
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
	check "$(LIBKRUNFW_SHA256)" "$(LIBKRUNFW_ARCHIVE)"; \
	check "$(KERNEL_SHA256)" "$(KERNEL_ARCHIVE)"; \
	check "$(MUSL_SHA256)" "$(MUSL_ARCHIVE)"; \
	check "$(PYELFTOOLS_SHA256)" "$(PYELFTOOLS_ARCHIVE)"; \
	check "$(RUNTIME_SHA256)" "$(RUNTIME_ARCHIVE)"

prepare: $(PREPARED)

$(PREPARED): | verify
	mkdir -p "$(SOURCE_DIR)" "$(TARGET_DIR)" "$(STAGE_DIR)/lib" "$(CARGO_HOME)"
	mkdir -p "$(SMOLVM_SRC)" "$(LIBKRUN_SRC)" "$(LIBKRUNFW_SRC)"
	mkdir -p "$(MUSL_SRC)" "$(PYELFTOOLS_SRC)" "$(RUNTIME_SRC)"
	tar -xf "$(SMOLVM_ARCHIVE)" -C "$(SMOLVM_SRC)" --strip-components=1
	tar -xf "$(LIBKRUN_ARCHIVE)" -C "$(LIBKRUN_SRC)" --strip-components=1
	tar -xf "$(LIBKRUNFW_ARCHIVE)" -C "$(LIBKRUNFW_SRC)" --strip-components=1
	tar -xf "$(MUSL_ARCHIVE)" -C "$(MUSL_SRC)" --strip-components=1
	tar -xf "$(PYELFTOOLS_ARCHIVE)" -C "$(PYELFTOOLS_SRC)" --strip-components=1
	tar -xf "$(RUNTIME_ARCHIVE)" -C "$(RUNTIME_SRC)" --strip-components=1
ifeq ($(HOST_OS),Linux)
	mkdir -p "$(LIBKRUNFW_SRC)/tarballs"
	perl -pi -e 's/KERNEL_TARBALL = tarballs\/\$$\(KERNEL_VERSION\)\.tar\.xz/KERNEL_TARBALL = tarballs\/\$$(KERNEL_VERSION).tar.gz/' \
	  "$(LIBKRUNFW_SRC)/Makefile"
	cp "$(KERNEL_ARCHIVE)" "$(LIBKRUNFW_SRC)/tarballs/linux-$(KERNEL_VERSION).tar.gz"
ifeq ($(GUEST_ARCH),x86_64)
	grep -qx '# CONFIG_DRM is not set' "$(LIBKRUNFW_SRC)/config-libkrunfw_x86_64"
	perl -0pi -e 's/# CONFIG_DRM is not set/CONFIG_DRM=y\nCONFIG_DRM_VIRTIO_GPU=y/' \
	  "$(LIBKRUNFW_SRC)/config-libkrunfw_x86_64"
endif
endif
	touch "$@"

build: $(BUILD_COMPLETE)

build-init: $(INIT_KRUN)

$(INIT_KRUN): $(PREPARED)
	printf '%s\n' \
	  '#!/bin/sh' \
	  'set -eu' \
	  'for arg do' \
	  '  case "$$arg" in' \
	  '    rcrt1.o|crti.o|crtbeginS.o|crtendS.o|crtn.o|-nostartfiles) ;;' \
	  '    *) set -- "$$@" "$$arg" ;;' \
	  '  esac' \
	  '  shift' \
	  'done' \
	  "exec \"$$(command -v zig)\" cc -target \"$(ZIG_TARGET)\" \"\$$@\"" \
	  > "$(ZIG_CC)"
	chmod 0755 "$(ZIG_CC)"
	cd "$(LIBKRUN_SRC)" && env \
	  CARGO_HOME="$(CARGO_HOME)" \
	  CARGO_TARGET_DIR="$(INIT_TARGET_DIR)" \
	  RUSTC_BOOTSTRAP=1 \
	  "$(RUST_LINKER_ENV)=$(ZIG_CC)" \
	  ZIG_GLOBAL_CACHE_DIR="$(BUILD_DIR)/zig-global-cache" \
	  ZIG_LOCAL_CACHE_DIR="$(BUILD_DIR)/zig-local-cache" \
	  cargo build --release --locked -Z build-std=std,panic_abort \
	    --target "$(RUST_TARGET)" -p krun-init
	file "$@" | grep -F 'statically linked'

build-libkrun: $(LIBKRUN_OUTPUT)

$(LIBKRUN_OUTPUT): $(INIT_KRUN)
ifeq ($(HOST_OS),Linux)
	cd "$(LIBKRUN_SRC)" && env \
	  CARGO_HOME="$(CARGO_HOME)" \
	  CARGO_TARGET_DIR="$(TARGET_DIR)/libkrun" \
	  KRUN_INIT_BINARY_PATH="$(INIT_KRUN)" \
	  LIBCLANG_PATH="$(LLVM_LIB)" \
	  LIBRARY_PATH="$(GPU_LIBRARY_PATH)$${LIBRARY_PATH:+:$$LIBRARY_PATH}" \
	  PKG_CONFIG_PATH="$(GPU_PKG_CONFIG_PATH)$${PKG_CONFIG_PATH:+:$$PKG_CONFIG_PATH}" \
	  RUSTFLAGS="$${RUSTFLAGS:+$$RUSTFLAGS }-C relro-level=partial" \
	  cargo build --release --locked -p libkrun --features "$(LIBKRUN_FEATURES)"
else
	cd "$(LIBKRUN_SRC)" && env \
	  CARGO_HOME="$(CARGO_HOME)" \
	  CARGO_TARGET_DIR="$(TARGET_DIR)/libkrun" \
	  KRUN_INIT_BINARY_PATH="$(INIT_KRUN)" \
	  cargo build --release --locked -p libkrun --features "$(LIBKRUN_FEATURES)"
endif
	cp "$@" "$(STAGE_DIR)/lib/$(LIBKRUN_NAME)"
ifeq ($(HOST_OS),Linux)
	ln -sfn "libkrun.so" "$(STAGE_DIR)/lib/libkrun.so.2"
	ln -sfn "$(BZIP2_LIB)/libbz2.so.1.0" "$(STAGE_DIR)/lib/libbz2.so.1.0"
	ln -sfn "$(LIBEPOXY_LIB)/libepoxy.so.0" "$(STAGE_DIR)/lib/libepoxy.so.0"
	ln -sfn "$(VIRGL_LIB)/libvirglrenderer.so.1" "$(STAGE_DIR)/lib/libvirglrenderer.so.1"
	ln -sfn "$(VIRGL_LIBEXEC)/virgl_render_server" "$(STAGE_DIR)/lib/virgl_render_server"
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
	  LD_LIBRARY_PATH="$(BREW_LIBRARY_PATH)$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" \
	  PYTHONPATH="$(PYELFTOOLS_SRC)" \
	  CC="$(KERNEL_CC)" \
	  HOSTCC="$(KERNEL_CC)" \
	  make -j"$(JOBS)" "GUESTARCH=$(GUEST_ARCH)"
	cp "$(LIBKRUNFW_SRC)/libkrunfw.so.$(LIBKRUNFW_VERSION)" "$(STAGE_DIR)/lib/"
	ln -sfn "libkrunfw.so.$(LIBKRUNFW_VERSION)" "$(STAGE_DIR)/lib/libkrunfw.so.5"
	ln -sfn "libkrunfw.so.5" "$(STAGE_DIR)/lib/libkrunfw.so"
else
		rm -rf "$(MACOS_KERNEL_SRC)" "$(MACOS_HOST_INCLUDE)"
		tar -xf "$(KERNEL_ARCHIVE)" -C "$(LIBKRUNFW_SRC)"
		for patch in "$(LIBKRUNFW_SRC)"/patches/0*.patch; do \
		  "$(MACOS_GPATCH)" -s -p1 -d "$(MACOS_KERNEL_SRC)" < "$$patch"; \
		done
		cp "$(LIBKRUNFW_SRC)/config-libkrunfw_aarch64" "$(MACOS_KERNEL_SRC)/.config"
		perl -0pi -e 's/typedef struct \{\n\t__u8 b\[16\];\n\} uuid_t;/#ifndef __APPLE__\ntypedef struct {\n\t__u8 b[16];\n} uuid_t;\n#endif/' \
		  "$(MACOS_KERNEL_SRC)/scripts/mod/file2alias.c"
		perl -pi -e 's/uuid->b\[/(*uuid)[/g' \
		  "$(MACOS_KERNEL_SRC)/scripts/mod/file2alias.c"
		mkdir -p "$(MACOS_HOST_INCLUDE)"
		printf '%s\n' \
		  '#pragma once' \
		  '#define bswap_16(x) __builtin_bswap16(x)' \
		  '#define bswap_32(x) __builtin_bswap32(x)' \
		  '#define bswap_64(x) __builtin_bswap64(x)' \
		  > "$(MACOS_HOST_INCLUDE)/byteswap.h"
		cp "$(MUSL_SRC)/include/elf.h" "$(MACOS_HOST_INCLUDE)/elf.h"
		env PATH="$(MACOS_CROSS_PATH):$$PATH" \
		  "$(MACOS_GMAKE)" -C "$(MACOS_KERNEL_SRC)" -j"$(JOBS)" \
		    ARCH=arm64 CROSS_COMPILE=aarch64-elf- \
		    HOSTCC="$(KERNEL_CC)" \
		    HOSTCFLAGS="-I$(MACOS_HOST_INCLUDE)" \
		    KBUILD_BUILD_TIMESTAMP='Mon Jun  1 16:28:39 CEST 2026' \
		    KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=libkrunfw olddefconfig
		env PATH="$(MACOS_CROSS_PATH):$$PATH" \
		  "$(MACOS_GMAKE)" -C "$(MACOS_KERNEL_SRC)" -j"$(JOBS)" \
		    ARCH=arm64 CROSS_COMPILE=aarch64-elf- \
		    HOSTCC="$(KERNEL_CC)" \
		    HOSTCFLAGS="-I$(MACOS_HOST_INCLUDE)" \
		    KBUILD_BUILD_TIMESTAMP='Mon Jun  1 16:28:39 CEST 2026' \
		    KBUILD_BUILD_USER=root KBUILD_BUILD_HOST=libkrunfw Image
		cd "$(LIBKRUNFW_SRC)" && env PYTHONPATH="$(PYELFTOOLS_SRC)" \
		  "$(MACOS_PYTHON)" bin2cbundle.py --os Darwin -t Image \
		    "$(MACOS_KERNEL_SRC)/arch/arm64/boot/Image" kernel.c
		"$(KERNEL_CC)" -dynamiclib -fPIC -O2 -DABI_VERSION=5 \
		  -Wl,-install_name,@rpath/libkrunfw.5.dylib \
		  -o "$(STAGE_DIR)/lib/libkrunfw.5.dylib" "$(LIBKRUNFW_SRC)/kernel.c"
		codesign --force --sign - "$(STAGE_DIR)/lib/libkrunfw.5.dylib"
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
	rm -rf "$(STAGE_DIR)/agent-rootfs" "$(STAGE_DIR)/agent-rootfs.tar"
	cp -a "$(RUNTIME_SRC)/agent-rootfs" "$(STAGE_DIR)/agent-rootfs"
	tar -cpf "$(STAGE_DIR)/agent-rootfs.tar" -C "$(STAGE_DIR)/agent-rootfs" .
	rm -rf "$(STAGE_DIR)/agent-rootfs"
	dd if=/dev/zero of="$(STAGE_DIR)/storage-template.ext4" bs=1 count=0 seek=536870912 2>/dev/null
	"$(MKFS_EXT4)" -F -q -m 0 -L smolvm "$(STAGE_DIR)/storage-template.ext4"
	perl -e 'truncate($$ARGV[0], 20 * 1024 * 1024 * 1024) or die "truncate: $$!"' \
	  "$(STAGE_DIR)/storage-template.ext4"
	dd if=/dev/zero of="$(STAGE_DIR)/overlay-template.ext4" bs=1 count=0 seek=536870912 2>/dev/null
	"$(MKFS_EXT4)" -F -q -m 0 -L smolvm-overlay "$(STAGE_DIR)/overlay-template.ext4"
	perl -e 'truncate($$ARGV[0], 10 * 1024 * 1024 * 1024) or die "truncate: $$!"' \
	  "$(STAGE_DIR)/overlay-template.ext4"
	touch "$@"

check: $(BUILD_COMPLETE)
	"$(STAGE_DIR)/smolvm" --version
	file "$(STAGE_DIR)/smolvm-bin" "$(INIT_KRUN)" \
	  "$(STAGE_DIR)/lib/$(LIBKRUN_NAME)" \
	  "$(STAGE_DIR)/lib/libkrunfw.$(if $(filter Darwin,$(HOST_OS)),5.dylib,so.5)"
	tar -tf "$(STAGE_DIR)/agent-rootfs.tar" | grep -Fx './usr/local/bin/smolvm-agent'
	ls -l "$(STAGE_DIR)/lib"
	du -h "$(STAGE_DIR)/storage-template.ext4" "$(STAGE_DIR)/overlay-template.ext4"
ifeq ($(HOST_OS),Linux)
	test -x "$(STAGE_DIR)/lib/virgl_render_server"
	env LD_LIBRARY_PATH="$(STAGE_DIR)/lib" \
	  $(GPU_FEATURE_CHECK) "$(STAGE_DIR)/lib/libkrun.so"
endif

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

build-vulkan-smoke-image:
	@command -v "$(PODMAN)" >/dev/null || { \
	  printf '%s is required to build the Vulkan smoke image\n' "$(PODMAN)" >&2; \
	  exit 1; \
	}
	mkdir -p "$(BUILD_DIR)"
	rm -f "$(VULKAN_COMPUTE_IIDFILE)"
	# Tag separately so strict containers-policy.json files do not reject a
	# cached unsigned local image during Podman's final named-image copy.
	"$(PODMAN)" build --format oci \
	  --iidfile "$(VULKAN_COMPUTE_IIDFILE)" \
	  --file Resources/vulkan-smoke/Containerfile \
	  Resources/vulkan-smoke
	"$(PODMAN)" tag "$$(cat "$(VULKAN_COMPUTE_IIDFILE)")" \
	  "$(VULKAN_COMPUTE_LOCAL_IMAGE)"
	"$(PODMAN)" image inspect "$(VULKAN_COMPUTE_LOCAL_IMAGE)" \
	  --format '{{.Id}} {{.Architecture}} {{json .Config.Entrypoint}}'

smoke-installed:
	@test -x "$(SMOLVM_BIN)" || { \
	  printf 'smolvm is not installed by Homebrew; run brew install samhclark/redist/smolvm\n' >&2; \
	  exit 1; \
	}
	@if [[ "$(HOST_OS)" == "Linux" ]]; then \
	  test -c /dev/kvm || { printf '/dev/kvm is unavailable\n' >&2; exit 1; }; \
	  test -r /dev/kvm && test -w /dev/kvm || { \
	    printf '/dev/kvm is not readable and writable by this user\n' >&2; \
	    exit 1; \
	  }; \
	  libdir="$$(brew --prefix smolvm)/libexec/lib"; \
	  test -x "$$libdir/virgl_render_server"; \
	  env LD_LIBRARY_PATH="$$libdir" \
	    $(GPU_FEATURE_CHECK) "$$libdir/libkrun.so"; \
	fi
	@tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	mkdir -p "$$tmpdir/home"; \
	host_timeout=(); \
	if command -v timeout >/dev/null; then \
	  host_timeout=(timeout "$(SMOKE_TIMEOUT)"); \
	fi; \
	if output="$$(env \
	  HOME="$$tmpdir/home" \
	  XDG_CACHE_HOME="$$tmpdir/cache" \
	  XDG_DATA_HOME="$$tmpdir/data" \
	  "$${host_timeout[@]}" "$(SMOLVM_BIN)" machine run \
	    --cpus 1 --mem 512 --timeout "$(SMOKE_GUEST_TIMEOUT)" \
	    -- echo "$(SMOKE_MARKER)" 2>&1)"; then \
	  status=0; \
	else \
	  status=$$?; \
	fi; \
	printf '%s\n' "$$output"; \
	if [[ $$status -ne 0 ]]; then \
	  printf 'smolvm VM smoke test failed with exit status %s\n' "$$status" >&2; \
	  exit "$$status"; \
	fi; \
	grep -Fq -- "$(SMOKE_MARKER)" <<<"$$output" || { \
	  printf 'smolvm VM smoke marker was not returned by the guest\n' >&2; \
	  exit 1; \
	}

smoke-gpu-installed:
	@test "$(HOST_OS)" = "Linux" || { \
	  printf 'the installed GPU smoke test currently supports Linux only\n' >&2; \
	  exit 1; \
	}
	@test -x "$(SMOLVM_BIN)" || { \
	  printf 'smolvm is not installed by Homebrew; run brew install samhclark/redist/smolvm\n' >&2; \
	  exit 1; \
	}
	@test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm || { \
	  printf '/dev/kvm is unavailable or inaccessible\n' >&2; \
	  exit 1; \
	}
	@test -c /dev/dri/renderD128 || { \
	  printf '/dev/dri/renderD128 is unavailable on the host\n' >&2; \
	  exit 1; \
	}
	@libdir="$$(brew --prefix smolvm)/libexec/lib"; \
	test -x "$$libdir/virgl_render_server"; \
	env LD_LIBRARY_PATH="$$libdir" \
	  $(GPU_FEATURE_CHECK) "$$libdir/libkrun.so"
	@tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	mkdir -p "$$tmpdir/home"; \
	host_timeout=(); \
	if command -v timeout >/dev/null; then \
	  host_timeout=(timeout "$(GPU_SMOKE_TIMEOUT)"); \
	fi; \
	if output="$$(env \
	  HOME="$$tmpdir/home" \
	  XDG_CACHE_HOME="$$tmpdir/cache" \
	  XDG_DATA_HOME="$$tmpdir/data" \
	  "$${host_timeout[@]}" "$(SMOLVM_BIN)" machine run \
	    --gpu --gpu-vram 512 --net --image alpine:latest \
	    --cpus 1 --mem 1024 --timeout "$(GPU_SMOKE_GUEST_TIMEOUT)" \
	    -- sh -c 'test -c /dev/dri/renderD128 && test -c /dev/dri/card0 && echo "$(GPU_SMOKE_MARKER)"' \
	    2>&1)"; then \
	  status=0; \
	else \
	  status=$$?; \
	fi; \
	printf '%s\n' "$$output"; \
	if [[ $$status -ne 0 ]]; then \
	  printf 'smolvm GPU smoke test failed with exit status %s\n' "$$status" >&2; \
	  exit "$$status"; \
	fi; \
	grep -Fq -- "$(GPU_SMOKE_MARKER)" <<<"$$output" || { \
	  printf 'smolvm GPU smoke marker was not returned by the guest\n' >&2; \
	  exit 1; \
	}

smoke-vulkan-installed:
	@test "$(HOST_OS)" = "Linux" || { \
	  printf 'the installed Vulkan smoke test currently supports Linux only\n' >&2; \
	  exit 1; \
	}
	@test -x "$(SMOLVM_BIN)" || { \
	  printf 'smolvm is not installed by Homebrew; run brew install samhclark/redist/smolvm\n' >&2; \
	  exit 1; \
	}
	@test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm || { \
	  printf '/dev/kvm is unavailable or inaccessible\n' >&2; \
	  exit 1; \
	}
	@test -c /dev/dri/renderD128 || { \
	  printf '/dev/dri/renderD128 is unavailable on the host\n' >&2; \
	  exit 1; \
	}
	@libdir="$$(brew --prefix smolvm)/libexec/lib"; \
	test -x "$$libdir/virgl_render_server"; \
	env LD_LIBRARY_PATH="$$libdir" \
	  $(GPU_FEATURE_CHECK) "$$libdir/libkrun.so"
	@tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	mkdir -p "$$tmpdir/home"; \
	host_timeout=(); \
	if command -v timeout >/dev/null; then \
	  host_timeout=(timeout "$(VULKAN_SMOKE_TIMEOUT)"); \
	fi; \
	if output="$$(env \
	  HOME="$$tmpdir/home" \
	  XDG_CACHE_HOME="$$tmpdir/cache" \
	  XDG_DATA_HOME="$$tmpdir/data" \
	  "$${host_timeout[@]}" "$(SMOLVM_BIN)" machine run \
	    --gpu --gpu-vram 2048 --net --image "$(VULKAN_SMOKE_IMAGE)" \
	    --cpus 2 --mem 4096 --timeout "$(VULKAN_SMOKE_GUEST_TIMEOUT)" \
	    -- bash -eu -o pipefail -c '\
	      dnf install -y dnf-plugins-core; \
	      dnf copr enable -y "$(VULKAN_SMOKE_COPR)"; \
	      dnf install -y --allowerasing mesa-vulkan-drivers vulkan-tools; \
	      test -c /dev/dri/renderD128; \
	      test -c /dev/dri/card0; \
	      export XDG_RUNTIME_DIR=/tmp; \
	      vulkaninfo --summary 2>&1 | tee /tmp/vulkaninfo.txt; \
	      grep -qiE "deviceName[[:space:]]*=[[:space:]]*Virtio-GPU Venus" /tmp/vulkaninfo.txt; \
	      grep -qiE "driverName[[:space:]]*=[[:space:]]*venus" /tmp/vulkaninfo.txt; \
	      grep -qiE "apiVersion[[:space:]]*=[[:space:]]*1\\.[2-9]" /tmp/vulkaninfo.txt; \
	      echo "$(VULKAN_SMOKE_MARKER)"' \
	    2>&1)"; then \
	  status=0; \
	else \
	  status=$$?; \
	fi; \
	printf '%s\n' "$$output"; \
	if [[ $$status -ne 0 ]]; then \
	  printf 'smolvm Vulkan smoke test failed with exit status %s\n' "$$status" >&2; \
	  exit "$$status"; \
	fi; \
	grep -Fq -- "$(VULKAN_SMOKE_MARKER)" <<<"$$output" || { \
	  printf 'smolvm Vulkan smoke marker was not returned by the guest\n' >&2; \
	  exit 1; \
	}

smoke-vulkan-compute-installed:
	@test "$(HOST_OS)" = "Linux" || { \
	  printf 'the installed Vulkan compute smoke test currently supports Linux only\n' >&2; \
	  exit 1; \
	}
	@test -x "$(SMOLVM_BIN)" || { \
	  printf 'smolvm is not installed by Homebrew; run brew install samhclark/redist/smolvm\n' >&2; \
	  exit 1; \
	}
	@test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm || { \
	  printf '/dev/kvm is unavailable or inaccessible\n' >&2; \
	  exit 1; \
	}
	@test -c /dev/dri/renderD128 || { \
	  printf '/dev/dri/renderD128 is unavailable on the host\n' >&2; \
	  exit 1; \
	}
	@libdir="$$(brew --prefix smolvm)/libexec/lib"; \
	test -x "$$libdir/virgl_render_server"; \
	env LD_LIBRARY_PATH="$$libdir" \
	  $(GPU_FEATURE_CHECK) "$$libdir/libkrun.so"
	@tmpdir="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	mkdir -p "$$tmpdir/home"; \
	host_timeout=(); \
	if command -v timeout >/dev/null; then \
	  host_timeout=(timeout "$(VULKAN_COMPUTE_TIMEOUT)"); \
	fi; \
	if output="$$(env \
	  HOME="$$tmpdir/home" \
	  XDG_CACHE_HOME="$$tmpdir/cache" \
	  XDG_DATA_HOME="$$tmpdir/data" \
	  "$${host_timeout[@]}" "$(SMOLVM_BIN)" machine run \
	    --gpu --gpu-vram 2048 --net --image "$(VULKAN_COMPUTE_IMAGE)" \
	    --cpus 2 --mem 4096 --timeout "$(VULKAN_COMPUTE_GUEST_TIMEOUT)" \
	    -- /usr/local/bin/smolvm-vulkan-compute \
	    2>&1)"; then \
	  status=0; \
	else \
	  status=$$?; \
	fi; \
	printf '%s\n' "$$output"; \
	if [[ $$status -ne 0 ]]; then \
	  printf 'smolvm Vulkan compute smoke test failed with exit status %s\n' "$$status" >&2; \
	  exit "$$status"; \
	fi; \
	grep -Fq -- "$(VULKAN_COMPUTE_MARKER)" <<<"$$output" || { \
	  printf 'smolvm Vulkan compute smoke marker was not returned by the guest\n' >&2; \
	  exit 1; \
	}

clean:
	rm -rf "$(BUILD_DIR)"
