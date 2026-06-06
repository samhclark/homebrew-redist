# smolvm source-build handoff

Last updated: June 6, 2026.

## Current state

The tap's only Formula, `smolvm`, has been reworked from installing an upstream
binary archive to building the host-side software from pinned source:

- smolvm v1.0.1 is built from its tag archive.
- The smol-machines libkrun fork is built from commit
  `e85a254ac1a1a2be58fb5b54e10937fecc55d268`.
- On Linux, the smol-machines libkrunfw fork is built from commit
  `516ceece6aed60ccc84ac8faa459885062e39400`, including its patched Linux
  6.12.87 guest kernel.
- `init.krun` is built as a static guest-architecture ELF with Zig.
- The storage and overlay ext4 templates are generated during installation.
- The v1.0.1 release archive remains as a bootstrap for the Alpine guest rootfs.
- On macOS arm64, `libkrunfw.5.dylib` also remains sourced from the release
  archive because its Linux guest kernel cannot be built natively on macOS
  without an existing VM or cross-build arrangement.

The generated Cargo lockfile is committed at
`Resources/smolvm/Cargo.lock`. Upstream v1.0.1 does not include one.

The sibling checkout at `../../smol-machines/smolvm` is currently four commits
behind its `origin/main`, and its submodules are not initialized after the
reboot. This does not affect the Formula: the v1.0.1 tag records the libkrun and
libkrunfw commits above, and the Formula downloads those commits directly.

The working tree was already one commit ahead of `origin/main` before this
work, at commit `f1315de` (`smolvm: declare bundled libkrunfw + Linux kernel
licenses`). The untracked `reproduce.sh` also predates the source Formula work
and demonstrates the upstream v1.0.1 release's `init.krun` architecture issue.
Do not discard either item accidentally.

After the June 6 reboot, `brew bundle check --file=Brewfile` confirmed that all
listed dependencies are installed. It also reported unrelated conflict markers
in Homebrew core's local `Formula/p/python@3.13.rb`. The Brewfile still passed,
and `brew style Formula/smolvm.rb` passed, but repair or update the local
`homebrew/core` checkout before treating future audit failures as problems in
this tap.

## Proven result

The complete Formula was built on Linux x86_64 using:

```sh
brew reinstall --build-from-source samhclark/redist/smolvm
```

That build completed in 11 minutes 20 seconds. The installed package reported
`smolvm 1.0.1`. The following checks passed:

- `brew style Formula/smolvm.rb`
- `brew audit --strict --formula samhclark/redist/smolvm`
- `brew test samhclark/redist/smolvm`
- Native x86-64 architecture for `smolvm-bin`, both installed `init.krun`
  copies, libkrun, libkrunfw, and the guest agent.
- Static linkage for `init.krun`.
- libkrun SONAME `libkrun.so.1`.
- Required fork-specific symbols:
  `krun_add_disk2`, `krun_add_net_unixstream`,
  `krun_create_disk_overlay`, `krun_set_egress_policy`, and
  `krun_set_snapshot`.
- Correct libkrunfw symlink chain ending at `libkrunfw.so.5.4.0`.
- Sparse 512 MiB ext4 templates, using about 17 MiB of real disk each.

This did not include a full KVM guest boot test. Linux arm64 and macOS arm64
have not yet been tested.

## Reproducing after a reboot

Nothing needed for the build now lives under `/tmp`. The developer workflow
uses `.build/`, which is ignored by Git.

Install the known Homebrew dependencies:

```sh
brew bundle --file=Brewfile
```

Recreate the manual CPU-only build:

```sh
make build
make check
```

The Makefile downloads and verifies every pinned archive needed on the current
platform, extracts sources, applies the two compatibility patches, builds the
host stack, and places a distribution-like result under `.build/stage`.

Use `make clean` before retrying after changing a pin or build patch. The
Makefile uses stamp files and will otherwise retain the previous prepared
source tree.

The manual Makefile is primarily a diagnostic and handoff tool. The Formula
remains the authoritative packaging implementation.

`make formula-check` styles the local Formula, then compares it with the
Formula in `brew --repo samhclark/redist` before running audit and test. It
currently stops at that comparison because Homebrew's registered tap clone
still has the older Formula. Sync the complete tap checkout, including
`Resources/smolvm/Cargo.lock`, before using that target.

## Continuous integration

`.github/workflows/tests.yml` runs Homebrew's `brew test-bot` on the
`ubuntu-24.04` x86_64 GitHub-hosted runner, using Homebrew's official container
and setup action. It runs for pull requests, pushes to `main`, and manual
dispatches. It checks tap syntax, builds changed Formulae from source on pull
requests, and always builds smolvm on `main` and manual runs. It runs the
Formula tests and retains generated bottles as seven-day workflow artifacts.

The workflow deliberately has read-only repository permissions and does not
publish bottles. Add publishing only after the first Linux bottle has passed
relocation checks and its generated bottle block has been reviewed.

The workflow deliberately does not attempt a guest boot. KVM access through
GitHub's hosted runner and Homebrew job container is not treated as a supported
CI contract, so this job covers installation and the Formula's CLI test.

## Build dependencies

The exact Homebrew dependencies are recorded in `Brewfile`.

Common:

- `e2fsprogs`: creates the ext4 disk templates.
- `pkgconf`: resolves C build dependencies.
- `rust`: builds libkrun and smolvm.
- `zig`: cross-builds a static Linux `init.krun`, including from macOS.

Linux-only:

- `bc`, `bison`, `cpio`, `flex`: Linux kernel build tools.
- `elfutils`: libelf support needed by kernel host tools.
- `gpatch`: GNU patch for libkrunfw's kernel patches.
- `openssl@3`: kernel host-side crypto tooling.
- `python@3.14`: runs libkrunfw's bundle generator.
- `zlib-ng-compat`, `zstd`: transitive libelf compression dependencies that
  must be visible through pkg-config.

A host C compiler, GNU-compatible `make`, tar, Perl, and curl are also expected.
On the verified Fedora host these came from the operating system rather than
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

The proven feature set is block and networking only:

```sh
KRUN_INIT_BINARY_PATH=/absolute/path/to/init.krun \
RUSTFLAGS="-C relro-level=partial" \
cargo build --release --locked -p libkrun --features blk,net
```

`KRUN_INIT_BINARY_PATH` is mandatory because libkrun embeds this ELF at compile
time. Partial RELRO matches the upstream distribution build and will be
required if the GPU library's direct dependency is later stripped with
`patchelf`. It is harmless in the current non-GPU build.

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
- Build features (`blk`, `net`, and eventually `gpu`) become package-level API.
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

## GPU support feasibility

Adding a tap-local virglrenderer Formula is feasible and is the most direct
next experiment.

Homebrew core currently provides `libepoxy`, `molten-vk`, `libdrm`, Mesa, and
the Vulkan loader, but not virglrenderer. There is a current working precedent
in `slp/homebrew-krun`: its virglrenderer Formula builds the
`slp/virglrenderer` tag `0.10.4e-krunkit` with:

```sh
meson setup build \
  -Dvenus=true \
  -Drender-server=false
meson compile -C build
meson install -C build
```

That Formula depends on `libepoxy` and `molten-vk`, and the tap was active as
recently as May 26, 2026. It demonstrates that this stack is packageable on
Apple Silicon, but its old forked virglrenderer version should be evaluated
rather than copied blindly.

A direct copy is also insufficient for Linux. smolvm's upstream distribution
expects a `virgl_render_server` executable for Venus, while the example Formula
sets `-Drender-server=false`. A tap-local Formula should enable and install the
render server on Linux; macOS can use the in-process MoltenVK path.

A likely tap design is:

1. Add `Formula/smolvm-virglrenderer.rb`, initially pinned to the exact fork
   and revision known to work with the smol-machines libkrun fork.
2. Depend on `meson`, `ninja`, and `pkgconf` for the build.
3. On macOS depend on `libepoxy` and `molten-vk`.
4. On Linux enable the render server and evaluate `libepoxy`, `libdrm`, Mesa,
   and `vulkan-loader` based on the enabled virglrenderer options.
5. Build libkrun with `--features blk,net,gpu` and add `llvm` so bindgen can
   find libclang (`LIBCLANG_PATH="$(brew --prefix llvm)/lib"`).
6. Symlink the needed virglrenderer libraries and, on Linux,
   `virgl_render_server` into smolvm's `libexec/lib`, or patch the runtime to
   search the dependency's `opt_lib` and `opt_bin`.
7. Decide whether virglrenderer is mandatory or optional.

Modern Homebrew Formulae do not have a good user-facing optional-feature model.
For this tap, making GPU dependencies mandatory is simpler. A separate
`smolvm-gpu` Formula is another option if the added dependency size is
unacceptable.

The upstream Linux release process makes GPU optional at runtime by building
libkrun with partial RELRO, removing its hard virglrenderer `NEEDED` entry with
`patchelf`, and using lazy symbol binding. A dedicated virglrenderer dependency
would avoid that fragile step: keep the normal dynamic dependency and ensure
the library is always installed.

Host packaging is only half of the work. An end-to-end GPU test must confirm:

- The pinned libkrun fork's GPU feature builds on each platform.
- libkrun can locate virglrenderer and its transitive libraries at runtime.
- macOS install names, rpaths, and ad-hoc signatures remain valid.
- The libkrunfw kernel enables the required virtio-gpu support.
- The guest workload contains a compatible Mesa Venus driver.
- A real Vulkan workload succeeds inside a VM.

GPU support expands the guest-facing rendering attack surface, so the
virglrenderer pin will need regular security updates.

## Recommended next steps

1. Confirm the Linux x86_64 workflow completes and inspect its generated bottle.
2. Extend CI to Linux arm64 and macOS arm64.
3. Add a real VM boot smoke test where KVM/HVF runners permit it.
4. Test macOS codesigning and rpath behavior.
5. Bottle `smolvm-libkrunfw` before attempting broader refactoring.
6. Prototype `smolvm-virglrenderer` using the slp tap Formula as a reference.
7. Build `smolvm-libkrun` with `blk,net,gpu` against that Formula and run a
   guest Vulkan smoke test.

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
