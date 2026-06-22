# Dependencies for developing and manually reproducing the smolvm source build.
# Install them with:
#
#   brew bundle --file=Brewfile

brew "e2fsprogs"
brew "perl"
brew "pkgconf"
brew "rust"
brew "zig"

if OS.mac?
  brew "aarch64-elf-binutils"
  brew "aarch64-elf-gcc"
  brew "bc"
  brew "bison"
  brew "cpio"
  brew "flex"
  brew "gpatch"
  brew "make"
  brew "python@3.14", link: false
  brew "xz"
  brew "samhclark/redist/smolvm-libkrunfw"
end

if OS.linux?
  brew "bc"
  brew "bison"
  brew "bzip2"
  brew "cpio"
  brew "elfutils"
  brew "flex"
  brew "gpatch"
  brew "libdrm"
  brew "libepoxy"
  brew "libyaml"
  brew "llvm"
  brew "mesa"
  brew "meson"
  brew "ninja"
  brew "openssl@3"
  brew "python@3.14", link: false
  brew "vulkan-loader"
  brew "xz"
  brew "zlib-ng-compat"
  brew "zstd"
  brew "samhclark/redist/smolvm-libkrunfw"
  brew "samhclark/redist/smolvm-virglrenderer"
end
