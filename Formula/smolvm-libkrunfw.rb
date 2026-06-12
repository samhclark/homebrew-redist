class SmolvmLibkrunfw < Formula
  desc "Linux guest kernel firmware for smolvm's libkrun"
  homepage "https://github.com/smol-machines/libkrunfw"
  url "https://github.com/smol-machines/libkrunfw/archive/516ceece6aed60ccc84ac8faa459885062e39400.tar.gz"
  version "5.4.0"
  sha256 "c9c43a5d54a239f2bb69f1c6762ad40854a8f5c996a9890872bd3ca39d52ba5d"
  license all_of: ["LGPL-2.1-only", "GPL-2.0-only"]

  bottle do
    root_url "https://github.com/samhclark/homebrew-redist/releases/download/smolvm-libkrunfw-5.4.0"
    rebuild 2
    sha256 cellar: :any_skip_relocation, arm64_tahoe: "f71f0cba290e099876c8255d104e0224bc2419c0be983aef0b9dbb5c7efec511"
  end

  depends_on "aarch64-elf-binutils" => :build
  depends_on "aarch64-elf-gcc" => :build
  depends_on "bc" => :build
  depends_on "bison" => :build
  depends_on "cpio" => :build
  depends_on "flex" => :build
  depends_on "gpatch" => :build
  depends_on "make" => :build
  depends_on "python@3.14" => :build
  depends_on "xz" => :build
  depends_on arch: :arm64
  depends_on :macos

  preserve_rpath

  resource "linux-kernel" do
    url "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.87.tar.xz"
    sha256 "cc12a7644b4cef9e06627b29de8753e22b3d076703a9b52be84263e05c8b9830"
  end

  resource "musl" do
    url "https://musl.libc.org/releases/musl-1.2.5.tar.gz"
    sha256 "a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
  end

  resource "pyelftools" do
    url "https://files.pythonhosted.org/packages/b9/ab/33968940b2deb3d92f5b146bc6d4009a5f95d1d06c148ea2f9ee965071af/pyelftools-0.32.tar.gz"
    sha256 "6de90ee7b8263e740c8715a925382d4099b354f29ac48ea40d840cf7aa14ace5"
  end

  def install
    musl = buildpath/"musl"
    resource("musl").stage musl

    pyelftools = buildpath/"pyelftools"
    resource("pyelftools").stage pyelftools
    ENV["PYTHONPATH"] = pyelftools

    linux_kernel = buildpath/"linux-6.12.87"
    system "tar", "-xf", resource("linux-kernel").cached_download
    apply_kernel_patches(linux_kernel)
    patch_kernel_host_tools(linux_kernel)
    cp "config-libkrunfw_aarch64", linux_kernel/".config"

    host_include = buildpath/"host-include"
    host_include.mkpath
    (host_include/"byteswap.h").write <<~C
      #pragma once
      #define bswap_16(x) __builtin_bswap16(x)
      #define bswap_32(x) __builtin_bswap32(x)
      #define bswap_64(x) __builtin_bswap64(x)
    C
    cp musl/"include/elf.h", host_include/"elf.h"

    ENV.prepend_path "PATH", Formula["aarch64-elf-binutils"].opt_bin
    ENV.prepend_path "PATH", Formula["aarch64-elf-gcc"].opt_bin
    ENV.prepend_path "PATH", Formula["bison"].opt_bin
    ENV.prepend_path "PATH", Formula["flex"].opt_bin

    kernel_host_cflags = "-I#{host_include}"
    kernel_make = [
      Formula["make"].opt_bin/"gmake",
      "-C", linux_kernel,
      "-j#{ENV.make_jobs}",
      "ARCH=arm64",
      "CROSS_COMPILE=aarch64-elf-",
      "HOSTCC=#{DevelopmentTools.locate(DevelopmentTools.default_compiler)}",
      "HOSTCFLAGS=#{kernel_host_cflags}",
      "KBUILD_BUILD_TIMESTAMP=#{build_timestamp}",
      "KBUILD_BUILD_USER=root",
      "KBUILD_BUILD_HOST=libkrunfw"
    ]

    system(*kernel_make, "olddefconfig")
    system(*kernel_make, "Image")

    system "python3", "bin2cbundle.py", "--os", "Darwin", "-t", "Image",
                      linux_kernel/"arch/arm64/boot/Image", "kernel.c"

    libkrunfw = buildpath/"libkrunfw.5.dylib"
    system ENV.cc, "-dynamiclib", "-fPIC", "-O2", "-DABI_VERSION=5",
                   "-Wl,-install_name,@rpath/libkrunfw.5.dylib",
                   "-o", libkrunfw, "kernel.c"
    system "codesign", "--force", "--sign", "-", libkrunfw

    lib.install libkrunfw
    lib.install_symlink "libkrunfw.5.dylib" => "libkrunfw.dylib"
  end

  test do
    libkrunfw = lib/"libkrunfw.5.dylib"
    assert_equal "@rpath/libkrunfw.5.dylib", MachO.open(libkrunfw).dylib_id
    system "codesign", "--verify", libkrunfw

    require "fiddle"
    get_version = Fiddle::Function.new(Fiddle.dlopen(libkrunfw)["krunfw_get_version"], [], Fiddle::TYPE_INT)
    assert_equal 5, get_version.call
  end

  private

  def apply_kernel_patches(linux_kernel)
    patch = Formula["gpatch"].opt_bin/"gpatch"
    Dir["patches/0*.patch"].each do |kernel_patch|
      system patch, "-p1", "-d", linux_kernel, "-i", buildpath/kernel_patch
    end
  end

  def patch_kernel_host_tools(linux_kernel)
    file2alias = linux_kernel/"scripts/mod/file2alias.c"
    inreplace file2alias,
              "typedef struct {\n\t__u8 b[16];\n} uuid_t;",
              "#ifndef __APPLE__\ntypedef struct {\n\t__u8 b[16];\n} uuid_t;\n#endif"
    inreplace file2alias, "uuid->b[", "(*uuid)["
  end

  def build_timestamp
    "Fri May  8 14:25:15 CEST 2026"
  end
end
