# Dependencies for developing and manually reproducing the smolvm source build.
# Install them with:
#
#   brew bundle --file=Brewfile

brew "e2fsprogs"
brew "pkgconf"
brew "rust"
brew "zig"

if OS.linux?
  brew "bc"
  brew "bison"
  brew "cpio"
  brew "elfutils"
  brew "flex"
  brew "gpatch"
  brew "libdrm"
  brew "libepoxy"
  brew "libyaml"
  brew "mesa"
  brew "meson"
  brew "ninja"
  brew "openssl@3"
  brew "python@3.14"
  brew "vulkan-loader"
  brew "xz"
  brew "zlib-ng-compat"
  brew "zstd"
end

# Building GPU-enabled libkrun will additionally need llvm/libclang. The
# smolvm-virglrenderer Formula is now in this tap, but smolvm does not depend on
# it or build libkrun's GPU feature yet. See docs/smolvm-source-build.md.
