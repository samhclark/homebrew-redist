class Smolvm < Formula
  desc "OCI-native microVM runtime for hardware-isolated local execution"
  homepage "https://github.com/smol-machines/smolvm"
  version "1.0.0"
  license "Apache-2.0"

  on_macos do
    on_arm do
      url "https://github.com/smol-machines/smolvm/releases/download/v#{version}/smolvm-#{version}-darwin-arm64.tar.gz"
      sha256 "da649d7ddd5ab7d0efe6d8d9a083fa5ca42294c2ce890691488e660518da9fab"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/smol-machines/smolvm/releases/download/v#{version}/smolvm-#{version}-linux-arm64.tar.gz"
      sha256 "518722798536170cadd87c4ed541e918c69f9e411da551c44da65e67e5425b30"
    end
    on_intel do
      url "https://github.com/smol-machines/smolvm/releases/download/v#{version}/smolvm-#{version}-linux-x86_64.tar.gz"
      sha256 "c7ceeaeb8d8d38c48a3e56040343988eec093b71c806c01d2f8f4bb537cfc70f"
    end
  end

  def install
    libexec.install Dir["*"]
    bin.install_symlink libexec/"smolvm"
  end

  def caveats
    on_linux do
      <<~EOS
        smolvm requires KVM to run guests:
          * /dev/kvm must exist
          * your user must be in the "kvm" group (or have read/write access)
      EOS
    end
  end

  test do
    assert_match "smolvm", shell_output("#{bin}/smolvm --help")
  end
end
