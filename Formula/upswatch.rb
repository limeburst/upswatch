class Upswatch < Formula
  desc "Shut a Mac down when its Megatec / Voltronic USB UPS runs out of time"
  homepage "https://github.com/limeburst/upswatch"
  url "https://github.com/limeburst/upswatch/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "faf3a28de0acee73f81c7af8bf91fedcc8e1df83e8c28fb5d2a99e757cb45e6f"
  license "MIT"
  head "https://github.com/limeburst/upswatch.git", branch: "main"

  depends_on :macos

  def install
    # swiftc, not swift build: the Command Line Tools are enough.
    system "swiftc", "-O", "-o", "upswatch", *Dir["Sources/upswatch/*.swift"]
    bin.install "upswatch"
  end

  service do
    run [opt_bin/"upswatch"]
    require_root true
    keep_alive true
    log_path var/"log/upswatch.log"
    error_log_path var/"log/upswatch.log"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/upswatch --version")
  end
end
