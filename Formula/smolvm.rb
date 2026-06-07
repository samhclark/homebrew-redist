class Smolvm < Formula
  desc "OCI-native microVM runtime for hardware-isolated local execution"
  homepage "https://github.com/smol-machines/smolvm"
  url "https://github.com/smol-machines/smolvm/archive/refs/tags/v1.0.1.tar.gz"
  sha256 "2192f54c53a8621ecd038a1bbdee1cc917e111abe3d935e81bdaee51daccc862"
  license all_of: ["Apache-2.0", "LGPL-2.1-only", "GPL-2.0-only"]
  revision 2

  bottle do
    root_url "https://github.com/samhclark/homebrew-redist/releases/download/smolvm-1.0.1_2"
    rebuild 3
    sha256               arm64_tahoe:  "2e3e715a62202c4c4edf7886102a693f6679f4ded5d94cfb78b44ef2b2f4e8d3"
    sha256 cellar: :any, arm64_linux:  "ba6a423f24d70c60757e6df229a46ec04b2e243f96fdb6ad50664f9b36aea7fc"
    sha256 cellar: :any, x86_64_linux: "47d467f54d21d34ef3a032f0c02a41c7c5e4517201d31a89a27dc9e50a4d1979"
  end

  depends_on "e2fsprogs" => :build
  depends_on "pkgconf" => :build
  depends_on "rust" => :build
  depends_on "zig" => :build

  on_macos do
    depends_on arch: :arm64
  end

  on_linux do
    depends_on "bc" => :build
    depends_on "bison" => :build
    depends_on "cpio" => :build
    depends_on "elfutils" => :build
    depends_on "flex" => :build
    depends_on "gpatch" => :build
    depends_on "llvm" => :build
    depends_on "openssl@3" => :build
    depends_on "python@3.14" => :build
    depends_on "xz" => :build
    depends_on "zlib-ng-compat" => :build
    depends_on "zstd" => :build
    depends_on "bzip2"
    depends_on "libepoxy"
    depends_on "smolvm-virglrenderer"

    resource "libkrunfw" do
      url "https://github.com/smol-machines/libkrunfw/archive/516ceece6aed60ccc84ac8faa459885062e39400.tar.gz"
      sha256 "c9c43a5d54a239f2bb69f1c6762ad40854a8f5c996a9890872bd3ca39d52ba5d"
    end

    resource "linux-kernel" do
      url "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.87.tar.xz"
      sha256 "cc12a7644b4cef9e06627b29de8753e22b3d076703a9b52be84263e05c8b9830"
    end

    resource "pyelftools" do
      url "https://files.pythonhosted.org/packages/b9/ab/33968940b2deb3d92f5b146bc6d4009a5f95d1d06c148ea2f9ee965071af/pyelftools-0.32.tar.gz"
      sha256 "6de90ee7b8263e740c8715a925382d4099b354f29ac48ea40d840cf7aa14ace5"
    end
  end

  preserve_rpath

  resource "libkrun" do
    url "https://github.com/smol-machines/libkrun/archive/e85a254ac1a1a2be58fb5b54e10937fecc55d268.tar.gz"
    sha256 "627bddfe16be6b144a7582fea79fb2d87175df9927d3dfeffbcd4ce7d6d5b6b3"
  end

  resource "runtime" do
    on_macos do
      url "https://github.com/smol-machines/smolvm/releases/download/v1.0.1/smolvm-1.0.1-darwin-arm64.tar.gz"
      sha256 "d6a2830cfa7087a935590b0fed859c59bda83410e510a75c0ae5add8c9d21700"
    end
    on_linux do
      on_arm do
        url "https://github.com/smol-machines/smolvm/releases/download/v1.0.1/smolvm-1.0.1-linux-arm64.tar.gz"
        sha256 "c8c6cf8dbc4427ca28c356fe8c27e49749f6691fbda058daf09b2643cd688399"
      end
      on_intel do
        url "https://github.com/smol-machines/smolvm/releases/download/v1.0.1/smolvm-1.0.1-linux-x86_64.tar.gz"
        sha256 "a4c85e8b3e14e0df7976eb00a9dbdb55e2d90d7f2a0e8c237e8518030496d34a"
      end
    end
  end

  def install
    resource_root = buildpath.parent
    resource("libkrun").stage resource_root/"libkrun"
    resource("runtime").stage resource_root/"runtime"

    # Upstream does not commit a lockfile, so keep the generated v1.0.1 lockfile
    # in the tap and require Cargo to honor it.
    cp Pathname(__dir__).parent/"Resources/smolvm/Cargo.lock", "Cargo.lock"

    # The release layout puts init.krun next to smolvm-bin. Include that location
    # so Linuxbrew installations outside /usr/local and /opt/homebrew can find it.
    inreplace "src/vm/backend/libkrun.rs" do |s|
      s.sub! "    let sources = [\n", <<~RUST
        let sources = [
            std::env::current_exe()
                .ok()
                .and_then(|path| path.parent().map(|dir| dir.join("init.krun"))),
      RUST
    end

    libdir = libexec/"lib"
    libdir.mkpath
    init_krun = build_init
    build_libkrun(init_krun, libdir)

    if OS.linux?
      install_linux_gpu_runtime(libdir)
      build_libkrunfw(libdir)
    else
      libkrunfw = resource_root/"runtime/lib/libkrunfw.5.dylib"
      MachO::Tools.change_dylib_id(libkrunfw, "@rpath/libkrunfw.5.dylib")
      MachO.codesign!(libkrunfw)
      libdir.install libkrunfw
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

    agent_init = resource_root/"runtime/agent-rootfs/init.krun"
    cp init_krun, agent_init
    chmod 0755, agent_init

    inreplace "scripts/smolvm-wrapper.sh",
              'SMOLVM_BUNDLED_ROOTFS="$SCRIPT_DIR/agent-rootfs"',
              'SMOLVM_BUNDLED_ROOTFS_TAR="$SCRIPT_DIR/agent-rootfs.tar"'
    inreplace "scripts/smolvm-wrapper.sh",
              'if [[ -d "$SMOLVM_BUNDLED_ROOTFS" ]]; then',
              'if [[ -f "$SMOLVM_BUNDLED_ROOTFS_TAR" ]]; then'
    inreplace "scripts/smolvm-wrapper.sh",
              'export SMOLVM_AGENT_ROOTFS="${SMOLVM_AGENT_ROOTFS:-$SMOLVM_BUNDLED_ROOTFS}"',
              'export SMOLVM_AGENT_ROOTFS_TAR="${SMOLVM_AGENT_ROOTFS_TAR:-$SMOLVM_BUNDLED_ROOTFS_TAR}"'

    libexec.install smolvm_bin => "smolvm-bin"
    libexec.install "scripts/smolvm-wrapper.sh" => "smolvm"
    system "tar", "-cpf", libexec/"agent-rootfs.tar",
                  "-C", resource_root/"runtime/agent-rootfs", "."
    libexec.install init_krun => "init.krun"
    chmod 0755, libexec/"smolvm"

    create_disk_template "storage-template.ext4", "smolvm"
    create_disk_template "overlay-template.ext4", "smolvm-overlay"

    bin.install_symlink libexec/"smolvm"
  end

  def caveats
    platform_notes = if OS.linux?
      <<~EOS
        libkrun is built with GPU support using the tap's virglrenderer package.
        libkrunfw and its Linux guest kernel are built from source.

        smolvm requires KVM to run guests:
          * /dev/kvm must exist
          * your user must be in the "kvm" group (or have read/write access)
      EOS
    else
      <<~EOS
        libkrunfw is taken from the matching upstream release because its Linux
        guest kernel cannot be built natively on macOS.
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
    assert_path_exists libexec/"init.krun"
    assert_match "./init.krun", shell_output("tar -tf #{libexec}/agent-rootfs.tar")
    if OS.linux?
      assert_path_exists libexec/"lib/libepoxy.so.0"
      assert_path_exists libexec/"lib/libvirglrenderer.so.1"
      assert_predicate libexec/"lib/virgl_render_server", :executable?

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
      assert_equal "@rpath/libkrunfw.5.dylib", MachO.open(libkrunfw).dylib_id
      system "codesign", "--verify", libkrunfw
    end
  end

  private

  def build_init
    libkrun = buildpath.parent/"libkrun"
    init_source = libkrun/"init/init.c"
    inreplace init_source do |s|
      s.sub! "#include <unistd.h>\n", "#include <unistd.h>\n\nextern char **environ;\n"
      s.gsub! "__environ", "environ"
    end

    target = Hardware::CPU.arm? ? "aarch64-linux-musl" : "x86_64-linux-musl"
    init_krun = libkrun/"init/init"
    ENV["ZIG_GLOBAL_CACHE_DIR"] = buildpath.parent/"zig-global-cache"
    ENV["ZIG_LOCAL_CACHE_DIR"] = buildpath.parent/"zig-local-cache"
    system "zig", "cc", "-target", target, "-O2", "-static", "-s", "-Wall",
                  "-o", init_krun, init_source, libkrun/"init/dhcp.c"
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
      build_env["LIBCLANG_PATH"] = Formula["llvm"].opt_lib
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
      libdir.install_symlink "libkrun.so" => "libkrun.so.1"
    end
  end

  def install_linux_gpu_runtime(libdir)
    virglrenderer = Formula["smolvm-virglrenderer"]
    libdir.install_symlink Formula["bzip2"].opt_lib/"libbz2.so.1.0"
    libdir.install_symlink Formula["libepoxy"].opt_lib/"libepoxy.so.0"
    libdir.install_symlink virglrenderer.opt_lib/"libvirglrenderer.so.1"
    libdir.install_symlink virglrenderer.opt_libexec/"virgl_render_server"
  end

  def build_libkrunfw(libdir)
    libkrunfw = buildpath.parent/"libkrunfw"
    pyelftools = buildpath.parent/"pyelftools"
    resource("libkrunfw").stage libkrunfw
    resource("pyelftools").stage pyelftools

    if Hardware::CPU.intel?
      inreplace libkrunfw/"config-libkrunfw_x86_64",
                "# CONFIG_DRM is not set",
                "CONFIG_DRM=y\nCONFIG_DRM_VIRTIO_GPU=y"
    end

    kernel_tarball = libkrunfw/"tarballs/linux-6.12.87.tar.xz"
    kernel_tarball.dirname.mkpath
    cp resource("linux-kernel").cached_download, kernel_tarball

    ENV["PYTHONPATH"] = pyelftools
    guest_arch = Hardware::CPU.arm? ? "aarch64" : "x86_64"
    kernel_path = ENV["PATH"].split(File::PATH_SEPARATOR)
                             .reject { |entry| entry == Superenv.shims_path.to_s }
                             .join(File::PATH_SEPARATOR)
    kernel_library_path = [Formula["elfutils"].opt_lib, ENV["LD_LIBRARY_PATH"]]
                          .compact
                          .join(File::PATH_SEPARATOR)
    cc = DevelopmentTools.locate(DevelopmentTools.default_compiler)
    with_env(PATH: kernel_path, LD_LIBRARY_PATH: kernel_library_path, CC: cc, HOSTCC: cc) do
      cd libkrunfw do
        system "make", "-j#{ENV.make_jobs}", "GUESTARCH=#{guest_arch}"
      end
    end

    libdir.install libkrunfw/"libkrunfw.so.5.4.0"
    libdir.install_symlink "libkrunfw.so.5.4.0" => "libkrunfw.so.5"
    libdir.install_symlink "libkrunfw.so.5" => "libkrunfw.so"
  end

  def create_disk_template(filename, label)
    template = libexec/filename
    File.open(template, "wb") { |file| file.truncate(512 * 1024 * 1024) }
    system Formula["e2fsprogs"].opt_sbin/"mkfs.ext4", "-F", "-q", "-m", "0", "-L", label, template
  end
end
