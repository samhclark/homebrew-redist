class SmolvmVirglrenderer < Formula
  desc "VirGL renderer with Venus support for smolvm"
  homepage "https://gitlab.freedesktop.org/virgl/virglrenderer"
  url "https://gitlab.freedesktop.org/virgl/virglrenderer/-/archive/1.3.0/virglrenderer-1.3.0.tar.gz"
  sha256 "065bc56e89e6f631f96101cd62eba0748e48eb888b434edc86e89d05395e76f3"
  license "MIT"

  bottle do
    root_url "https://github.com/samhclark/homebrew-redist/releases/download/smolvm-virglrenderer-1.3.0"
    rebuild 2
    sha256 arm64_linux:  "d8a10d7e8a70b902db0846aa2945e261d3fea0cf76365c3eecabeedb54c1fc59"
    sha256 x86_64_linux: "0f634c4f6db21bd53c171eb378c6668a2a083f56df138fb0fc5aabe0f3c9e078"
  end

  depends_on "libyaml" => :build
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => [:build, :test]
  depends_on "python@3.14" => :build
  depends_on "libdrm"
  depends_on "libepoxy"
  depends_on :linux
  depends_on "mesa"
  depends_on "vulkan-loader"

  resource "pyyaml" do
    url "https://files.pythonhosted.org/packages/05/8e/961c0007c59b8dd7729d542c61a4d537767a59645b82a0b521206e1e25c2/pyyaml-6.0.3.tar.gz"
    sha256 "d76623373421df22fb4cf8817020cbb7ef15c725b9d5e45f17e189bfc384190f"
  end

  def install
    pythonpath = buildpath/"pythonpath"
    resource("pyyaml").stage { pythonpath.install "lib/yaml" }
    ENV.prepend_path "PYTHONPATH", pythonpath

    args = %w[
      -Dcheck-gl-errors=true
      -Dplatforms=egl
      -Drender-server-worker=process
      -Dtests=false
      -Dtracing=none
      -Dunstable-apis=true
      -Dvenus=true
      -Dvideo=false
      -Dvulkan-dload=true
    ]

    system "meson", "setup", "build", *args, *std_meson_args
    system "meson", "compile", "-C", "build", "--verbose"
    system "meson", "install", "-C", "build"
  end

  test do
    assert_path_exists lib/"libvirglrenderer.so.1"
    assert_path_exists libexec/"virgl_render_server"
    assert_equal version.to_s, shell_output("pkg-config --modversion virglrenderer").chomp

    symbols = shell_output("nm -D #{lib}/libvirglrenderer.so.1")
    assert_match "virgl_renderer_context_get_poll_fd", symbols
    assert_match "virgl_renderer_context_poll", symbols
  end
end
