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
  brew "openssl@3"
  brew "python@3.14"
  brew "xz"
  brew "zlib-ng-compat"
  brew "zstd"
end

# GPU work is not part of the proven build. It will additionally need at least
# meson, ninja, llvm, libepoxy, and a virglrenderer Formula. See
# docs/smolvm-source-build.md.
