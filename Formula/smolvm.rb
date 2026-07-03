class Smolvm < Formula
  desc "OCI-native microVM runtime for hardware-isolated local execution"
  homepage "https://github.com/smol-machines/smolvm"
  url "https://github.com/smol-machines/smolvm/archive/refs/tags/v1.3.8.tar.gz"
  sha256 "3e5904cb16cbb363531107d7f8872cc770e2368a1ebcbfe4d63b92517594c877"
  license all_of: ["Apache-2.0", "LGPL-2.1-only", "GPL-2.0-only"]

  depends_on "e2fsprogs" => :build
  depends_on "pkgconf" => :build
  depends_on "rust" => :build
  depends_on "zig" => :build

  on_macos do
    depends_on arch: :arm64
    depends_on "smolvm-libkrunfw"
  end

  on_linux do
    depends_on "llvm" => :build
    depends_on "bzip2"
    depends_on "libepoxy"
    depends_on "smolvm-libkrunfw"
    depends_on "smolvm-virglrenderer"
  end

  preserve_rpath

  resource "libkrun" do
    url "https://github.com/smol-machines/libkrun/archive/f11d9dc75c6d050ed6d81ea5fd86910256862546.tar.gz"
    sha256 "fcc637d752cfd9eec4d5eadedb1bfc7c80ddb31329f158cca11e906c946331ee"
  end

  resource "runtime" do
    on_macos do
      # The v1.3.8 Darwin archive has a truncated tar stream. This Formula only
      # consumes the arm64 Linux guest rootfs from the runtime archive on macOS.
      url "https://github.com/smol-machines/smolvm/releases/download/v1.3.8/smolvm-1.3.8-linux-arm64.tar.gz"
      sha256 "55a6ef346b4d1c5e1031fa291197be929ba7646d4cb07b47de4577ad07ae2073"
    end
    on_linux do
      on_arm do
        url "https://github.com/smol-machines/smolvm/releases/download/v1.3.8/smolvm-1.3.8-linux-arm64.tar.gz"
        sha256 "55a6ef346b4d1c5e1031fa291197be929ba7646d4cb07b47de4577ad07ae2073"
      end
      on_intel do
        url "https://github.com/smol-machines/smolvm/releases/download/v1.3.8/smolvm-1.3.8-linux-x86_64.tar.gz"
        sha256 "9c784fa666e2bb39c3bf9d81dfee4d50bba11a0a654b80b8556c8103a9e58979"
      end
    end
  end

  def install
    resource_root = buildpath.parent
    resource("libkrun").stage resource_root/"libkrun"
    resource("runtime").stage resource_root/"runtime"

    libdir = libexec/"lib"
    libdir.mkpath
    init_krun = build_init
    build_libkrun(init_krun, libdir)

    if OS.linux?
      install_linux_gpu_runtime(libdir)
      install_linux_libkrunfw(libdir)
    else
      libdir.install_symlink formula_opt_lib("smolvm-libkrunfw")/"libkrunfw.5.dylib"
      libdir.install_symlink "libkrunfw.5.dylib" => "libkrunfw.dylib"
      ENV["LIBKRUN_BUNDLE"] = libdir
    end

    main_root = resource_root/"main-install"
    system "cargo", "install", *std_cargo_args(root: main_root), "--bin", "smolvm"
    smolvm_bin = main_root/"bin/smolvm"
    if OS.mac?
      system "codesign", "--force", "--sign", "-", "--entitlements", "smolvm.entitlements",
                         smolvm_bin
    end

    libexec.install smolvm_bin => "smolvm-bin"
    libexec.install "scripts/smolvm-wrapper.sh" => "smolvm"
    system "tar", "-cpf", libexec/"agent-rootfs.tar",
                  "-C", resource_root/"runtime/agent-rootfs", "."
    chmod 0755, libexec/"smolvm"

    create_disk_template "storage-template.ext4", "smolvm", 20
    create_disk_template "overlay-template.ext4", "smolvm-overlay", 10

    bin.install_symlink libexec/"smolvm"
  end

  def caveats
    platform_notes = if OS.linux?
      <<~EOS
        libkrun is built with GPU support using the tap's virglrenderer package.
        libkrunfw and its Linux guest kernel are provided by the tap's
        smolvm-libkrunfw package, which is built from source and bottled
        separately.

        smolvm requires KVM to run guests:
          * /dev/kvm must exist
          * your user must be in the "kvm" group (or have read/write access)
      EOS
    else
      <<~EOS
        libkrunfw and its Linux guest kernel are provided by the tap's
        smolvm-libkrunfw package, which is built from source and bottled
        separately.
      EOS
    end

    <<~EOS
      The smolvm CLI and libkrun are built from source. The Alpine guest rootfs
      is bootstrapped from the matching upstream release because constructing it
      requires networked Alpine package installation during the build.

      #{platform_notes}
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/smolvm --version")
    assert_match "smolvm", shell_output("#{bin}/smolvm --help")
    assert_match "./usr/local/bin/smolvm-agent", shell_output("tar -tf #{libexec}/agent-rootfs.tar")
    assert_match "./sbin/init", shell_output("tar -tf #{libexec}/agent-rootfs.tar")
    if OS.linux?
      assert_path_exists libexec/"lib/libepoxy.so.0"
      assert_path_exists libexec/"lib/libvirglrenderer.so.1"
      assert_predicate libexec/"lib/virgl_render_server", :executable?
      assert_predicate libexec/"lib/libkrun.so.2", :symlink?
      libkrunfw = libexec/"lib/libkrunfw.so.5"
      assert_predicate libkrunfw, :symlink?
      assert_equal (formula_opt_lib("smolvm-libkrunfw")/"libkrunfw.so.5").realpath,
                   libkrunfw.realpath

      ENV.prepend_path "LD_LIBRARY_PATH", libexec/"lib"
      require "fiddle"
      libkrun = Fiddle.dlopen(libexec/"lib/libkrun.so")
      has_feature = Fiddle::Function.new(
        libkrun["krun_has_feature"],
        [Fiddle::TYPE_LONG_LONG],
        Fiddle::TYPE_INT,
      )
      assert_equal 1, has_feature.call(2)
    else
      libkrunfw = libexec/"lib/libkrunfw.5.dylib"
      assert_predicate libkrunfw, :symlink?
      assert_equal (formula_opt_lib("smolvm-libkrunfw")/"libkrunfw.5.dylib").realpath,
                 libkrunfw.realpath
      assert_equal "@rpath/libkrunfw.5.dylib", MachO.open(libkrunfw).dylib_id
      system "codesign", "--verify", libkrunfw
    end
  end

  private

  def build_init
    libkrun = buildpath.parent/"libkrun"
    rust_target = Hardware::CPU.arm? ? "aarch64-unknown-linux-musl" : "x86_64-unknown-linux-musl"
    zig_target = Hardware::CPU.arm? ? "aarch64-linux-musl" : "x86_64-linux-musl"
    linker = buildpath.parent/"zig-cc"
    linker.write <<~SH
      #!/bin/sh
      set -eu
      for arg do
        case "$arg" in
          rcrt1.o|crti.o|crtbeginS.o|crtendS.o|crtn.o|-nostartfiles) ;;
          *) set -- "$@" "$arg" ;;
        esac
        shift
      done
      exec "#{formula_opt_bin("zig")}/zig" cc -target "#{zig_target}" "$@"
    SH
    chmod 0755, linker

    target_dir = buildpath.parent/"libkrun-init-target"
    linker_env = "CARGO_TARGET_#{rust_target.upcase.tr("-", "_")}_LINKER"
    ENV["ZIG_GLOBAL_CACHE_DIR"] = buildpath.parent/"zig-global-cache"
    ENV["ZIG_LOCAL_CACHE_DIR"] = buildpath.parent/"zig-local-cache"
    with_env("RUSTC_BOOTSTRAP" => "1", linker_env => linker) do
      cd libkrun do
        system "cargo", "build", "--release", "--locked", "-Z", "build-std=std,panic_abort",
                        "--target", rust_target, "--target-dir", target_dir, "-p", "krun-init"
      end
    end

    init_krun = target_dir/rust_target/"release/krun-init"
    init_description = Utils.safe_popen_read("file", "-b", init_krun)
    valid_init = init_description.include?("ELF") && init_description.include?("statically linked")
    raise "krun-init must be a static Linux executable: #{init_description}" unless valid_init

    init_krun
  end

  def build_libkrun(init_krun, libdir)
    libkrun = buildpath.parent/"libkrun"
    ENV["KRUN_INIT_BINARY_PATH"] = init_krun
    features = "blk,net"
    build_env = {}
    if OS.linux?
      virglrenderer = Formula["smolvm-virglrenderer"]
      ENV.prepend_path "PKG_CONFIG_PATH", virglrenderer.opt_lib/"pkgconfig"
      ENV.prepend_path "LIBRARY_PATH", virglrenderer.opt_lib
      build_env["LIBCLANG_PATH"] = formula_opt_lib("llvm")
      build_env["RUSTFLAGS"] = [ENV["RUSTFLAGS"], "-C relro-level=partial"].compact.join(" ")
      features += ",gpu"
    end

    with_env(build_env) do
      cd libkrun do
        system "cargo", "build", "--release", "--locked", "-p", "libkrun", "--features", features
      end
    end

    if OS.mac?
      libdir.install libkrun/"target/release/libkrun.dylib"
    else
      libdir.install libkrun/"target/release/libkrun.so"
      libdir.install_symlink "libkrun.so" => "libkrun.so.2"
    end
  end

  def install_linux_gpu_runtime(libdir)
    virglrenderer = Formula["smolvm-virglrenderer"]
    libdir.install_symlink formula_opt_lib("bzip2")/"libbz2.so.1.0"
    libdir.install_symlink formula_opt_lib("libepoxy")/"libepoxy.so.0"
    libdir.install_symlink virglrenderer.opt_lib/"libvirglrenderer.so.1"
    libdir.install_symlink virglrenderer.opt_libexec/"virgl_render_server"
  end

  def install_linux_libkrunfw(libdir)
    libkrunfw = Formula["smolvm-libkrunfw"]
    versioned_library = "libkrunfw.so.#{libkrunfw.version}"
    libdir.install_symlink libkrunfw.opt_lib/versioned_library
    libdir.install_symlink versioned_library => "libkrunfw.so.5"
    libdir.install_symlink "libkrunfw.so.5" => "libkrunfw.so"
  end

  def create_disk_template(filename, label, virtual_size_gib)
    template = libexec/filename
    File.open(template, "wb") { |file| file.truncate(512 * 1024 * 1024) }
    system Formula["e2fsprogs"].opt_sbin/"mkfs.ext4", "-F", "-q", "-m", "0", "-L", label, template
    File.open(template, "ab") { |file| file.truncate(virtual_size_gib * 1024 * 1024 * 1024) }
  end
end
