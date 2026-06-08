# smolvm source-build handoff

Last updated: June 8, 2026.

## Current state

The `smolvm` Formula has been reworked from installing an upstream binary
archive to building the host-side software from pinned source:

- smolvm v1.0.1 is built from its tag archive.
- The smol-machines libkrun fork is built from commit
  `e85a254ac1a1a2be58fb5b54e10937fecc55d268`.
- On Linux, libkrun is built with `blk,net,gpu` against the tap's
  `smolvm-virglrenderer` Formula. macOS remains on `blk,net`.
- On Linux, the smol-machines libkrunfw fork is built from commit
  `516ceece6aed60ccc84ac8faa459885062e39400`, including its patched Linux
  6.12.87 guest kernel.
- On x86_64 Linux, the libkrunfw kernel config is amended to enable DRM and
  virtio-gpu. The pinned arm64 config already enables those options.
- `init.krun` is built as a static guest-architecture ELF with Zig.
- The storage and overlay ext4 templates are generated during installation.
- The v1.0.1 release archive remains as a bootstrap for the Alpine guest rootfs.
- The guest rootfs is stored as `agent-rootfs.tar` in the keg. Upstream smolvm
  extracts it atomically into the user's cache on first use.
- The Linux keg stages version-stable symlinks for libepoxy, libbz2,
  libvirglrenderer, and `virgl_render_server` beside libkrun, matching the
  lookup paths in smolvm v1.0.1.
- On macOS arm64, `libkrunfw.5.dylib` also remains sourced from the release
  archive because its Linux guest kernel cannot be built natively on macOS
  without an existing VM or cross-build arrangement.
- The release dylib's install ID is normalized to
  `@rpath/libkrunfw.5.dylib` and ad-hoc signed before installation.

The generated Cargo lockfile is committed at
`Resources/smolvm/Cargo.lock`. Upstream v1.0.1 does not include one.

The sibling checkout at `../../smol-machines/smolvm` is not required for a
build. The v1.0.1 tag records the libkrun and libkrunfw commits above, and the
Formula downloads those exact commits directly.

The untracked `reproduce.sh` predates this work and demonstrates the upstream
v1.0.1 release's `init.krun` architecture issue. It is user-owned and should not
be discarded.

## Proven result

The complete Formula was built on Linux x86_64 using:

```sh
brew reinstall --build-from-source samhclark/redist/smolvm
```

The GPU-enabled revision build completed in 11 minutes 19 seconds. Homebrew
installed package revision `1.0.1_2`, while the CLI correctly reported upstream
version `smolvm 1.0.1`. The following checks passed:

- `brew style Formula/smolvm.rb`
- `brew audit --strict --formula samhclark/redist/smolvm`
- `brew test samhclark/redist/smolvm`
- `brew linkage --test samhclark/redist/smolvm`
- Native x86-64 architecture for `smolvm-bin`, the installed and archived
  `init.krun` copies, libkrun, libkrunfw, and the guest agent.
- Static linkage for `init.krun`.
- libkrun SONAME `libkrun.so.1`.
- `krun_has_feature(KRUN_FEATURE_GPU)` returned `1`.
- libkrun's direct `libbz2.so.1.0` and `libvirglrenderer.so.1` dependencies
  resolved from the installed keg.
- The staged `virgl_render_server` is executable.
- Required fork-specific symbols:
  `krun_add_disk2`, `krun_add_net_unixstream`,
  `krun_create_disk_overlay`, `krun_set_egress_policy`, and
  `krun_set_snapshot`.
- Correct libkrunfw symlink chain ending at `libkrunfw.so.5.4.0`.
- Sparse 512 MiB ext4 templates, using about 17 MiB of real disk each.

The installed Linux x86_64 revision also passes four local KVM tests:

- The bundled bare Alpine guest returns `smolvm-boot-smoke-ok`.
- An Alpine OCI workload started with `--gpu` exposes
  `/dev/dri/renderD128` and `/dev/dri/card0`.
- A Fedora 42 workload with the `slp/mesa-libkrun-vulkan` Mesa packages runs
  `vulkaninfo --summary`. It reports the Mesa Venus driver, a
  `Virtio-GPU Venus (Intel(R) Iris(R) Xe Graphics (TGL GT2))` device, and
  Vulkan 1.4.
- A compiled Vulkan probe dispatches a compute shader through that Venus
  device, reads 256 transformed integers back from a storage buffer, and
  verifies every result. It returns `smolvm-vulkan-compute-smoke-ok`.

The revision passed the complete test-bot build and Formula test sequence on
Linux x86_64, Linux arm64, and macOS 26 arm64:
<https://github.com/samhclark/homebrew-redist/actions/runs/27099891376>.
The publish workflow also succeeded:
<https://github.com/samhclark/homebrew-redist/actions/runs/27100575301>.

The `smolvm-1.0.1_2` release contains bottles for Linux x86_64, Linux arm64,
and macOS 26 arm64:
<https://github.com/samhclark/homebrew-redist/releases/tag/smolvm-1.0.1_2>.
The published Linux x86_64 bottle was force-poured locally and passed the
Formula test, strict linkage test, bare-guest smoke, GPU-device smoke, and
Vulkan smoke. The separately packaged `smolvm-virglrenderer` 1.3.0 bottles are
published for Linux x86_64 and arm64.

## Reproducing after a reboot

Nothing needed for the build now lives under `/tmp`. The developer workflow
uses `.build/`, which is ignored by Git.

Install the known Homebrew dependencies:

```sh
brew bundle --file=Brewfile
```

Recreate the manual build:

```sh
make build
make check
```

The Makefile downloads and verifies every pinned archive needed on the current
platform, extracts sources, applies the source compatibility and guest-kernel
config changes, builds the host stack, and places a distribution-like result
under `.build/stage`. Linux includes GPU support; macOS remains CPU-only.

Use `make clean` before retrying after changing a pin or build patch. The
Makefile uses stamp files and will otherwise retain the previous prepared
source tree.

The manual Makefile is primarily a diagnostic and handoff tool. The Formula
remains the authoritative packaging implementation.

`make formula-check` styles the local Formula, then compares it with the
Formula in `brew --repo samhclark/redist` before running audit and test. The
registered tap copy on this machine currently matches and passes. After
retapping or resetting that checkout, sync the complete tap, including
`Resources/smolvm/Cargo.lock`, before using the target or rebuilding.

After installing or upgrading the Formula on a KVM/HVF-capable development
host, run the end-to-end guest boot smoke test:

```sh
make smoke-installed
```

This resolves the Homebrew-installed `smolvm`. On Linux it first checks that
the render server exists and libkrun reports its GPU feature, then checks
`/dev/kvm` access. It boots the bundled bare Alpine guest with one vCPU and
512 MiB of memory. The guest must return `smolvm-boot-smoke-ok`. It does not
pull an OCI image or enable guest networking, and it isolates cache/data state
under a temporary home that is removed afterward.

GNU `timeout` is used as a 120-second outer guard when available; smolvm's own
60-second guest-command timeout is always used. Override the defaults when
diagnosing a slower host:

```sh
make smoke-installed SMOLVM_BIN=/path/to/smolvm \
  SMOKE_TIMEOUT=240 SMOKE_GUEST_TIMEOUT=120s
```

On Linux, verify that virtio-gpu device nodes reach an Alpine OCI workload:

```sh
make smoke-gpu-installed
```

This pulls `alpine:latest`, starts an ephemeral GPU-enabled VM, and requires
both `/dev/dri/renderD128` and `/dev/dri/card0` inside the container. It
returns `smolvm-gpu-device-smoke-ok` on success.

For a stronger Vulkan initialization and device-enumeration check:

```sh
make smoke-vulkan-installed
```

This pulls `fedora:42`, enables the `slp/mesa-libkrun-vulkan` COPR, installs
`mesa-vulkan-drivers` and `vulkan-tools`, and runs `vulkaninfo --summary`. The
test requires a Mesa Venus driver, a `Virtio-GPU Venus` device, Vulkan 1.2 or
newer, and both guest DRM device nodes. It uses two vCPUs, 4 GiB of guest
memory, and 2 GiB of GPU shared memory.

This target is intentionally a maintainer diagnostic, not a Formula or CI
test. It downloads a large Fedora image and packages from mutable Fedora and
third-party COPR repositories. It also imports that COPR's signing key inside
the disposable guest. The temporary Home and XDG directories are deleted
afterward.

The image, COPR, and timeouts are configurable:

```sh
make smoke-vulkan-installed \
  VULKAN_SMOKE_IMAGE=fedora:42 \
  VULKAN_SMOKE_COPR=slp/mesa-libkrun-vulkan \
  VULKAN_SMOKE_TIMEOUT=1200 \
  VULKAN_SMOKE_GUEST_TIMEOUT=1140s
```

For a deterministic compute test without installing packages at guest boot,
build the dedicated Fedora image locally with Podman:

```sh
make build-vulkan-smoke-image
```

This creates `localhost/smolvm-vulkan-smoke:dev`. The multi-stage
`Resources/vulkan-smoke/Containerfile` assembles and validates a SPIR-V shader,
compiles a small Vulkan C program, and installs the COPR's Venus-enabled Mesa
runtime in the final image. No Docker daemon is used.

The local image validates the build artifact, but smolvm v1.0.1 cannot consume
Podman's local image store directly. smolvm pulls OCI images from a registry
inside its guest. Run the published image through smolvm with:

```sh
make smoke-vulkan-compute-installed
```

The test pulls `ghcr.io/samhclark/smolvm-vulkan-smoke:main`, enables a 2 GiB
virtio-gpu shared-memory region, and explicitly runs the image's
`/usr/local/bin/smolvm-vulkan-compute` executable. The explicit command is
required because smolvm v1.0.1 rejects an empty `machine run` command before it
loads the OCI entrypoint. The probe rejects llvmpipe and any device not named
`Virtio-GPU Venus`, then verifies the shader's output buffer before returning
`smolvm-vulkan-compute-smoke-ok`.

Override the image with an immutable digest from the image workflow when
reproducing a specific result:

```sh
make smoke-vulkan-compute-installed \
  VULKAN_COMPUTE_IMAGE=ghcr.io/samhclark/smolvm-vulkan-smoke@sha256:<digest>
```

## Continuous integration

`.github/workflows/tests.yml` runs Homebrew's `brew test-bot` on native
GitHub-hosted Linux x86_64, Linux arm64, and macOS 26 arm64 runners. The Linux
jobs use `ubuntu-24.04` and `ubuntu-24.04-arm` with Homebrew's official
container; the macOS job uses the native `macos-26` runner. All jobs use
Homebrew's setup action. The workflow runs for pull requests, pushes to `main`,
and manual dispatches. It checks tap syntax, builds changed Formulae from
source on pull requests, and always builds smolvm on `main` and manual runs. It
runs the Formula tests and retains platform-specific bottles as seven-day
workflow artifacts. On Linux, the Formula test loads libkrun and asserts that
its GPU feature is enabled.

The test workflow deliberately has read-only repository permissions.

Linux pushes and manual runs also build `smolvm-virglrenderer` in a separate
job on x86_64 and arm64. Its artifacts use the
`virglrenderer-bottles-<platform>` prefix so the smolvm-only publisher does not
mistake them for release inputs.

`.github/workflows/publish.yml` is a separate, manually dispatched workflow
that publishes one Formula's artifacts from a selected successful test run.
Choose either `smolvm` or `smolvm-virglrenderer` when dispatching it. It:

1. Confirms the run used `tests.yml`, succeeded on `main`, and is an ancestor
   of the current revision.
2. Refuses to publish if the selected Formula's inputs changed after that run.
3. Requires exactly the selected Formula's supported bottle tags, all built
   from the selected revision.
4. Runs Homebrew's `brew pr-upload`, which merges the bottle JSON into the
   Formula, creates the `<formula>-<version>` GitHub release, and uploads the
   validated bottle archives.
5. Pushes Homebrew's generated bottle-block commit to `main`.

Publish within the test artifacts' seven-day retention window:

```sh
gh run list --workflow tests.yml --branch main --status success --limit 5
gh workflow run publish.yml -f formula=smolvm -f run_id=<run-id>
gh workflow run publish.yml \
  -f formula=smolvm-virglrenderer \
  -f run_id=27082234975
gh run watch
```

The workflow's `GITHUB_TOKEN` needs the repository's normal `contents: write`
permission. The manual dispatch and source checks prevent routine pushes from
republishing an existing version.

`.github/workflows/vulkan-smoke-image.yml` uses Red Hat's Buildah and registry
actions to build the OCI-format Linux amd64 Vulkan compute image and publish
`main` and `sha-<commit>` tags to GHCR. After its first successful run, make
the `smolvm-vulkan-smoke` package public in its
[GitHub package settings](https://docs.github.com/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility).
GHCR packages initially default to private, while smolvm needs anonymous
access from its disposable guest.

The workflows deliberately do not attempt a guest boot. Standard
[GitHub-hosted runners](https://docs.github.com/actions/reference/github-hosted-runners-reference)
do not provide a reliable nested-KVM plus `/dev/dri/render*` contract for this
workload. CI builds and publishes the image;
`smoke-vulkan-compute-installed` runs it on the maintainer's Linux host with
real KVM and GPU access. The four `smoke-*-installed` targets cover bare guest
boot, device forwarding, Vulkan initialization, and an actual compute dispatch
with readback.

## Updating smolvm

Do not assume a future version number exists. Start an update only after
upstream has published a concrete tag and matching runtime archives.

For an actual new release:

1. Inspect the tag's `.gitmodules` and gitlink entries:

   ```sh
   git -C ../../smol-machines/smolvm fetch --tags
   git -C ../../smol-machines/smolvm show <tag>:.gitmodules
   git -C ../../smol-machines/smolvm ls-tree <tag> libkrun libkrunfw
   ```

2. Update the smolvm URL/version/hash, pinned libkrun and libkrunfw revisions
   and hashes, kernel version/hash, and per-platform runtime archive hashes in
   both `Formula/smolvm.rb` and `Makefile`.
3. Generate a fresh Cargo lockfile from the exact tag and replace
   `Resources/smolvm/Cargo.lock`. Review dependency changes before committing.
4. Recheck every source patch in the Formula and Makefile. Remove patches that
   upstream fixed, and fail explicitly if an expected replacement no longer
   matches.
5. Run the local source and Formula checks:

   ```sh
   brew bundle --file=Brewfile
   make clean
   make build
   make check
   brew reinstall --build-from-source samhclark/redist/smolvm
   make formula-check
   make smoke-installed
   make smoke-gpu-installed
   make smoke-vulkan-installed
   make smoke-vulkan-compute-installed
   ```

6. Push the version update and wait for `tests.yml` to pass on Linux x86_64,
   Linux arm64, and macOS arm64. Inspect all generated bottles.
7. Publish that successful run within seven days:

   ```sh
   gh workflow run publish.yml \
     -f formula=smolvm \
     -f run_id=<successful-tests-run-id>
   ```

8. Pull Homebrew's generated bottle-block commit, reinstall normally, confirm
   Homebrew pours the bottle, and rerun the applicable installed smoke tests.

Keep the version update, build fixes, and generated bottle block as distinct
commits where practical. Never copy hashes or submodule revisions from a
different upstream tag.

## Build dependencies

The exact Homebrew dependencies are recorded in `Brewfile`.

Common:

- `e2fsprogs`: creates the ext4 disk templates.
- `perl`: applies source compatibility patches in the Makefile workflow.
- `pkgconf`: resolves C build dependencies.
- `rust`: builds libkrun and smolvm.
- `zig`: cross-builds a static Linux `init.krun`, including from macOS.

Linux-only:

- `bc`, `bison`, `cpio`, `flex`: Linux kernel build tools.
- `bzip2`: direct runtime dependency introduced by libkrun's GPU feature.
- `elfutils`: libelf support needed by kernel host tools.
- `gpatch`: GNU patch for libkrunfw's kernel patches.
- `llvm`: provides libclang for the GPU bindings generated by bindgen.
- `libepoxy`: loaded explicitly by smolvm before virglrenderer.
- `openssl@3`: kernel host-side crypto tooling.
- `python@3.14`: runs libkrunfw's bundle generator.
- `smolvm-virglrenderer`: supplies libvirglrenderer and
  `virgl_render_server`.
- `xz`: extracts the Linux kernel source archive.
- `zlib-ng-compat`, `zstd`: transitive libelf compression dependencies that
  must be visible through pkg-config.

The Brewfile also records virglrenderer development dependencies such as
libdrm, Mesa, Vulkan loader, Meson, Ninja, and libyaml so that its Formula can
be reproduced independently. X11 libraries and `xorgproto` arrive through that
dependency graph.

A host C compiler, GNU-compatible `make`, tar, and curl are also expected. On
the verified Fedora host these came from the operating system rather than
Homebrew.

## Important build details

### Source archives replace Git submodules

GitHub tag archives do not contain submodule contents. The Formula declares the
two pinned submodule commits as independent resources instead of invoking Git
or relying on the sibling checkout.

The `smolvm-sdk` submodule is not needed for the CLI build.

### init.krun must be rebuilt

The v1.0.1 Linux x86_64 release contains an aarch64 `init.krun`. The Formula
does not reuse it. It compiles the pinned libkrun init sources with:

```sh
zig cc -target x86_64-linux-musl -O2 -static -s -Wall \
  -o init init.c dhcp.c
```

Use `aarch64-linux-musl` on arm64 hosts and macOS arm64.

Zig's musl headers expose a portability bug in the fork: it refers to glibc's
private `__environ`. The build changes that reference to standard `environ`
and adds `extern char **environ;`.

### libkrun

The proven Linux feature set is block, networking, and GPU:

```sh
KRUN_INIT_BINARY_PATH=/absolute/path/to/init.krun \
LIBCLANG_PATH="$(brew --prefix llvm)/lib" \
LIBRARY_PATH="$(brew --prefix smolvm-virglrenderer)/lib:\
$(brew --prefix bzip2)/lib${LIBRARY_PATH:+:$LIBRARY_PATH}" \
PKG_CONFIG_PATH="$(brew --prefix smolvm-virglrenderer)/lib/pkgconfig:\
$(brew --prefix xorgproto)/share/pkgconfig\
${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
RUSTFLAGS="-C relro-level=partial" \
cargo build --release --locked -p libkrun --features blk,net,gpu
```

`KRUN_INIT_BINARY_PATH` is mandatory because libkrun embeds this ELF at compile
time. `LIBCLANG_PATH` is required by bindgen. The pkg-config path includes
`xorgproto` because libepoxy's private X11 dependency chain needs protocol
metadata that Homebrew installs under `share/pkgconfig`. `LIBRARY_PATH` is
required because the pinned rutabaga build emits `-lvirglrenderer` but does not
propagate virglrenderer's native search directory to libkrun's final cdylib
link.

Partial RELRO matches the upstream distribution build. This tap keeps
libkrun's normal virglrenderer `NEEDED` entry because virglrenderer is a
mandatory Linux dependency, rather than deleting it with `patchelf`.

The macOS build remains:

```sh
KRUN_INIT_BINARY_PATH=/absolute/path/to/init.krun \
cargo build --release --locked -p libkrun --features blk,net
```

### libkrunfw and the Linux kernel

The kernel tarball must be copied to:

```text
libkrunfw/tarballs/linux-6.12.87.tar.xz
```

pyelftools is staged from its source archive and exposed with `PYTHONPATH`.
The Homebrew paths needed by the manual build are:

```sh
PATH="$(brew --prefix gpatch)/bin:\
$(brew --prefix flex)/bin:\
$(brew --prefix bison)/bin:$PATH"

PKG_CONFIG_PATH="$(brew --prefix elfutils)/lib/pkgconfig:\
$(brew --prefix openssl@3)/lib/pkgconfig:\
$(brew --prefix zlib-ng-compat)/lib/pkgconfig:\
$(brew --prefix zstd)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

LD_LIBRARY_PATH="$(brew --prefix elfutils)/lib\
${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

Run `make` from inside the libkrunfw source directory:

```sh
make -j"$(nproc)" GUESTARCH=x86_64
```

Do not use `make -C libkrunfw`. Its implicit `-w` enters `MAKEFLAGS`; the
upstream Makefile forwards `MAKEFLAGS` to the kernel as command arguments, and
the kernel then tries to build a target named `w`.

During a Formula build, do not use Homebrew's compiler shim for the kernel.
Superenv removes the kernel's per-file `-O0` flag and adds `-O2`, causing
`crypto/jitterentropy.c` to fail its intentional safety check. The Formula
removes `Superenv.shims_path` from `PATH` and explicitly sets `CC` and `HOSTCC`
to the real system compiler for this step.

Using the real compiler also means kernel host tools do not receive Superenv's
runtime library paths. `objtool` links against Homebrew's `libelf.so.1`, then
must execute repeatedly during the kernel build. Keep the elfutils library
directory in `LD_LIBRARY_PATH` for this build step or `objtool` will fail to
start even though it linked successfully.

### smolvm

The source archive receives the committed Cargo lockfile and is built with
`--locked`.

The source is patched to search beside the running `smolvm-bin` for
`init.krun`. This is required for Linuxbrew prefixes such as
`/home/linuxbrew/.linuxbrew`; upstream only checks user data directories,
`/usr/local/share/smolvm`, and `/opt/homebrew/share/smolvm`.

The built init is also copied into the bundled agent rootfs. This avoids the
same problem for the normal bundled-rootfs path and replaces the incorrect
release init.

The Formula archives that rootfs rather than installing its directory tree
directly into the keg. Its Alpine executables are guest binaries linked against
musl and guest libraries; if installed unpacked, `brew linkage --test` mistakes
them for host executables and reports missing and unwanted system libraries.
smolvm v1.0.1 already supports `SMOLVM_AGENT_ROOTFS_TAR`, including
content-versioned, atomic extraction into the user's cache, so no custom
extraction code is needed in the tap.

### macOS libkrunfw bottle relocation

The upstream `libkrunfw.5.dylib` has only enough Mach-O header space for its
original short install ID. If Homebrew rewrites it to an absolute `opt` path
during installation, creating a bottle later fails because the longer
`@@HOMEBREW_PREFIX@@` relocation placeholder no longer fits in the header.

Before installing the dylib, the Formula changes its ID to
`@rpath/libkrunfw.5.dylib` and applies a new ad-hoc signature. The Formula's
`preserve_rpath` declaration keeps that compact ID unchanged through install
and bottle relocation.

## Remaining binary bootstrap

The build is not yet entirely from source. The matching release archive still
provides:

- The Alpine guest rootfs.
- Its statically linked `smolvm-agent`.
- On macOS, libkrunfw and its embedded Linux kernel.

Rebuilding the rootfs invokes Alpine package downloads and image tooling from
`scripts/build-agent-rootfs.sh`. That is a poor fit for Homebrew's deterministic
build sandbox. A future improvement would be for upstream to publish the
rootfs as a separately checksummed release artifact, or to provide a
reproducible rootfs source bundle containing all package inputs.

Cargo crates are locked but not vendored. First-time source builds still need
network access to crates.io unless Homebrew's cache is already populated.

## Should libkrun and libkrunfw become separate Formulae?

### libkrunfw: probably yes

A tap-specific `smolvm-libkrunfw` Formula would provide the clearest benefit:

- It isolates the slow full-kernel build.
- It can be bottled and reused across smolvm rebuilds.
- Its ABI and SONAME already form a natural package boundary.
- Linux and macOS policy can be handled independently: build from source on
  Linux, use a separately published firmware artifact on macOS until a native
  source build exists.

It should be named for smolvm rather than simply `libkrunfw`. smolvm pins a
patched fork and kernel configuration, so presenting it as a generic upstream
libkrunfw package would be misleading.

### libkrun: useful after libkrunfw, but more tightly coupled

A separate `smolvm-libkrun` Formula would shorten the main Formula and make GPU
feature work easier. It could depend on `smolvm-libkrunfw`, install the required
SONAME links, and expose the smolvm-specific init alongside the library.

The costs are real:

- libkrun embeds `init.krun`, so the package includes smolvm-specific behavior.
- The fork provides APIs that smolvm requires and generic libkrun may not.
- Build features (`blk`, `net`, and `gpu`) become package-level API.
- libkrun and libkrunfw revisions must be updated and tested together.
- Homebrew dependency versioning is not a substitute for testing that exact
  pair.

Recommendation: first extract `smolvm-libkrunfw` and bottle it. Extract
`smolvm-libkrun` only if build time, GPU work, or another consumer justifies
the extra release coordination. Do not depend on the generic
`slp/krun/libkrun` Formula without verifying the smol-machines fork patches;
the current Formula intentionally uses a different commit.

If split, the main Formula should load the libraries from dependency `opt_lib`
paths rather than copying them into its own Cellar. The current loader
explicitly opens both libraries from smolvm's single `libexec/lib` directory,
so the least invasive implementation is to install symlinks there that point
at each dependency's version-stable `opt_lib` path. A cleaner but larger change
would teach smolvm separate libkrun and libkrunfw search paths. Linux loader
paths, macOS install names/rpaths, and codesigning all need dedicated tests.

## GPU support

`Formula/smolvm-virglrenderer.rb` targets Linux and pins upstream
virglrenderer 1.3.0.

The Formula has published bottles for Linux x86_64 and arm64. Source-built and
bottle-poured installations pass the Formula test and strict Homebrew linkage
checks. The installed library exports
`virgl_renderer_context_get_poll_fd` and `virgl_renderer_context_poll`, which
are the extra polling APIs used by smolvm's pinned libkrun fork.

Homebrew core provides its dependencies (`libepoxy`, `libdrm`, Mesa/GBM, and
the Vulkan loader) but not virglrenderer itself. Upstream 1.3.0 automatically
builds `virgl_render_server` whenever Venus is enabled, so the Linux Formula
uses:

```sh
meson setup build \
  -Dplatforms=egl \
  -Dvenus=true \
  -Drender-server-worker=process \
  -Dvulkan-dload=true
meson compile -C build
meson install -C build
```

The older `slp/homebrew-krun` Formula is useful macOS precedent, but it packages
the `slp/virglrenderer` fork at `0.10.4e-krunkit` and explicitly disables the
render server. Copying it would not satisfy smolvm's Linux design.

macOS is intentionally not declared yet. Upstream 1.3.0 recognizes Darwin but
its dynamic Vulkan loader still searches for `libvulkan.so.1` and
`libvulkan.so`, while smolvm needs MoltenVK. A macOS Formula needs a focused
loader patch or link-time MoltenVK integration, plus native bottle and runtime
testing, before `depends_on :linux` can be removed.

The Linux integration is now implemented:

- `smolvm` depends on `smolvm-virglrenderer`, libepoxy, and bzip2.
- LLVM is a build-only dependency for bindgen.
- The pinned libkrun builds with `--features blk,net,gpu`.
- libepoxy, libbz2, libvirglrenderer, and `virgl_render_server` are symlinked
  into `smolvm`'s `libexec/lib`.
- The Formula test and Makefile checks call `krun_has_feature(2)` and require
  it to return `1`.
- The normal KVM boot smoke test passes with this runtime layout.
- The x86_64 libkrunfw guest kernel enables DRM and virtio-gpu.
- The Alpine GPU smoke sees both DRM device nodes inside the container.
- The Fedora Vulkan smoke initializes Mesa Venus and enumerates a physical
  `Virtio-GPU Venus` device through `vulkaninfo`.

Modern Homebrew Formulae do not have a good user-facing optional-feature model.
For this tap, making GPU dependencies mandatory on Linux is simpler than a
separate `smolvm-gpu` variant. Splitting the feature would duplicate or
conflict with the main `smolvm` executable and libkrun keg, while still
requiring coordinated revisions.

The upstream Linux release process makes GPU optional at runtime by building
libkrun with partial RELRO, removing its hard virglrenderer `NEEDED` entry with
`patchelf`, and using lazy symbol binding. This tap avoids that fragile step:
the dedicated virglrenderer dependency is mandatory, and libkrun keeps its
normal dynamic dependency.

The local Fedora `vulkaninfo` smoke proves the Vulkan loader, Mesa Venus ICD,
virtio-gpu transport, and physical-device enumeration. It still uses mutable
`fedora:42` and COPR package inputs at guest runtime, so it remains a useful
diagnostic rather than a repeatable regression test.

The stronger Vulkan compute smoke is now implemented for Linux x86_64. The
`vulkan-smoke-image.yml` workflow builds a Fedora-based OCI image with Buildah
and publishes it to GHCR. The image contains a compiled Vulkan probe and a
validated SPIR-V compute shader. `make smoke-vulkan-compute-installed` pulls
that image through smolvm, runs the probe explicitly, rejects llvmpipe, selects
the `Virtio-GPU Venus` device, dispatches the shader, reads back 256 integers,
and verifies every result.

That image should stay Linux amd64-only until real Linux arm64 GPU hardware is
available. An arm64 Mac does not validate the Linux KVM, virtio-gpu, Venus, and
Mesa runtime path.

For better reproducibility, the Makefile should eventually default
`VULKAN_COMPUTE_IMAGE` to a published GHCR digest rather than `:main`. The
image build itself still consumes mutable Fedora and COPR inputs, but a digest
pin freezes the produced test artifact for local regression runs.

macOS remains a separate project because it also needs a MoltenVK-capable
virglrenderer package, install-name/rpath handling, and codesigning tests.

GPU support expands the guest-facing rendering attack surface, so the
virglrenderer pin will need regular security updates.

## Recommended next steps

1. Pin `VULKAN_COMPUTE_IMAGE` to the digest produced by the successful GHCR
   image workflow, then rerun `make smoke-vulkan-compute-installed`.
2. Report or patch the smolvm v1.0.1 `machine run` behavior where an empty
   command is rejected before the OCI image entrypoint is loaded, despite the
   help text documenting that default.
3. Reconsider a separate `smolvm-libkrunfw` Formula now that the Linux GPU
   dependency graph and bottles are proven. Extract `smolvm-libkrun` only if
   the libkrunfw split helps in practice.
4. Add and test the macOS MoltenVK loader path if macOS GPU support becomes a
   goal.
5. Keep the Vulkan smoke image Linux amd64-only unless real Linux arm64 GPU
   hardware is available for runtime validation.
6. For any real future smolvm release, follow the documented update checklist.

## Reference sources

- smolvm: <https://github.com/smol-machines/smolvm>
- smol-machines libkrun fork:
  <https://github.com/smol-machines/libkrun>
- smol-machines libkrunfw fork:
  <https://github.com/smol-machines/libkrunfw>
- Generic libkrun build documentation:
  <https://github.com/containers/libkrun>
- Existing Homebrew GPU stack:
  <https://github.com/slp/homebrew-krun>
- virglrenderer upstream:
  <https://gitlab.freedesktop.org/virgl/virglrenderer>
