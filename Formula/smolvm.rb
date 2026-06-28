class Smolvm < Formula
  desc "OCI-native microVM runtime for hardware-isolated local execution"
  homepage "https://github.com/smol-machines/smolvm"
  url "https://github.com/smol-machines/smolvm/archive/refs/tags/v1.2.5.tar.gz"
  sha256 "766c17d00cbf1de6cf79c0c43bbd13661db375c052cc466cc297b8b3db982f28"
  license all_of: ["Apache-2.0", "LGPL-2.1-only", "GPL-2.0-only"]

  bottle do
    root_url "https://github.com/samhclark/homebrew-redist/releases/download/smolvm-1.2.5"
    rebuild 1
    sha256               arm64_tahoe:  "12879aa48c5ee2d412554b3ee6081040429cb125d31fc9a1951eac5ae6741fa6"
    sha256 cellar: :any, arm64_linux:  "306d40665ff8c00afd490802599a6a5026e8eb6dde3d6a3d3002ad321fc87016"
    sha256 cellar: :any, x86_64_linux: "6b2d584cd34746a106ff924d7f640d089a37774d5b0798728bda4045c906fe6b"
  end

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
    url "https://github.com/smol-machines/libkrun/archive/bd6ba6588e35d15471f07c0ba6b5386f277e0023.tar.gz"
    sha256 "02449d8f5c66dd28b9500c39c2b66ee2a26bee10ff998eaf40d4d62a1d5a4f1a"
  end

  resource "runtime" do
    on_macos do
      # The v1.2.5 Darwin archive has a truncated tar stream. This Formula only
      # consumes the arm64 Linux guest rootfs from the runtime archive on macOS.
      url "https://github.com/smol-machines/smolvm/releases/download/v1.2.5/smolvm-1.2.5-linux-arm64.tar.gz"
      sha256 "c963d4f13e9c17950896ecf4fea368dd4d3dfadbbed3f0b58a4b802774be686b"
    end
    on_linux do
      on_arm do
        url "https://github.com/smol-machines/smolvm/releases/download/v1.2.5/smolvm-1.2.5-linux-arm64.tar.gz"
        sha256 "c963d4f13e9c17950896ecf4fea368dd4d3dfadbbed3f0b58a4b802774be686b"
      end
      on_intel do
        url "https://github.com/smol-machines/smolvm/releases/download/v1.2.5/smolvm-1.2.5-linux-x86_64.tar.gz"
        sha256 "b7f6240ca3d97b42e6f6fe6ee87cac3744ee52f9517847ae06b65f7d29e9df81"
      end
    end
  end

  def install
    resource_root = buildpath.parent
    resource("libkrun").stage resource_root/"libkrun"
    resource("runtime").stage resource_root/"runtime"

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
    assert_path_exists libexec/"init.krun"
    assert_match "./init.krun", shell_output("tar -tf #{libexec}/agent-rootfs.tar")
    if OS.linux?
      assert_path_exists libexec/"lib/libepoxy.so.0"
      assert_path_exists libexec/"lib/libvirglrenderer.so.1"
      assert_predicate libexec/"lib/virgl_render_server", :executable?
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
      libdir.install_symlink "libkrun.so" => "libkrun.so.1"
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

  def create_disk_template(filename, label)
    template = libexec/filename
    File.open(template, "wb") { |file| file.truncate(512 * 1024 * 1024) }
    system Formula["e2fsprogs"].opt_sbin/"mkfs.ext4", "-F", "-q", "-m", "0", "-L", label, template
  end
end
