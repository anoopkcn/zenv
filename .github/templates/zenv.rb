class Zenv < Formula
  desc "Python virtual environment manager for HPC and development systems"
  homepage "https://github.com/anoopkcn/zenv"
  version "{{VERSION}}"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/anoopkcn/zenv/releases/download/v{{VERSION}}/zenv-aarch64-macos-small.tar.gz"
      sha256 "{{SHA_MACOS_ARM64}}"
    end
    on_intel do
      url "https://github.com/anoopkcn/zenv/releases/download/v{{VERSION}}/zenv-x86_64-macos-small.tar.gz"
      sha256 "{{SHA_MACOS_X64}}"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/anoopkcn/zenv/releases/download/v{{VERSION}}/zenv-aarch64-linux-musl-small.tar.gz"
      sha256 "{{SHA_LINUX_ARM64}}"
    end
    on_intel do
      url "https://github.com/anoopkcn/zenv/releases/download/v{{VERSION}}/zenv-x86_64-linux-musl-small.tar.gz"
      sha256 "{{SHA_LINUX_X64}}"
    end
  end

  def install
    bin.install "zenv"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/zenv --version")
  end
end
