# Homebrew formula for Tessera.
#
# Install via a tap:
#   brew tap facetscloud/tessera https://github.com/facetscloud/tessera
#   brew install tessera
#
# Or straight from this file in a checkout:
#   brew install --HEAD ./Formula/tessera.rb
#
# Tessera ships as a single Swift binary (no .app wrapper): Info.plist is
# embedded into the Mach-O `__TEXT,__info_plist` section at link time, so the
# bare executable is a proper menu-bar agent (LSUIElement + bundle id). On first
# launch it re-signs itself with a per-user self-signed cert so the macOS
# Accessibility grant survives `brew upgrade` — no Apple Developer ID needed.
class Tessera < Formula
  desc "Menu-bar tiling window manager that puppets GUI apps via Accessibility"
  homepage "https://github.com/facetscloud/tessera"
  license "MIT"
  head "https://github.com/facetscloud/tessera.git", branch: "main"

  # For tagged releases, point at the source tarball and its checksum:
  #   url "https://github.com/facetscloud/tessera/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "..."
  #   version "0.1.0"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/Tessera" => "tessera"
  end

  # Run Tessera as a background menu-bar agent: `brew services start tessera`.
  service do
    run [opt_bin/"tessera"]
    keep_alive true
    log_path var/"log/tessera.log"
    error_log_path var/"log/tessera.log"
  end

  def caveats
    <<~EOS
      Tessera is a menu-bar agent — look for the ▚ glyph after it starts.

      Start it now, and again at login:
        brew services start tessera

      First launch re-signs the binary with a per-user code-signing cert (created
      automatically in a dedicated keychain) and relaunches once. This is what
      keeps your Accessibility grant across `brew upgrade`.

      Then grant Accessibility once:
        System Settings → Privacy & Security → Accessibility → enable Tessera

      Keep Stage Manager OFF (it hides inactive apps' windows and fights tiling).
    EOS
  end

  test do
    assert_predicate bin/"tessera", :executable?
  end
end
