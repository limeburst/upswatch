class Upswatch < Formula
  desc "Shut a Mac down when its Megatec / Voltronic USB UPS runs out of time"
  homepage "https://github.com/limeburst/upswatch"
  url "https://github.com/limeburst/upswatch/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "b747625ec15d78dcb5bded63575287a957f4c24e6d38a0af63ba4f8d9ad3424c"
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
