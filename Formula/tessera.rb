# Homebrew formula for Tessera.
#
# Canonical copy lives in the tap repo github.com/pa/homebrew-tessera, so users
# install cleanly with:
#   brew tap pa/tessera          # infers github.com/pa/homebrew-tessera
#   brew trust pa/tessera        # one-time; Homebrew requires trusting 3rd-party taps
#   brew install tessera
#
# (This copy in the main repo is kept in sync as a reference.)
#
# Tessera ships as a single Swift binary (no .app wrapper): Info.plist is
# embedded into the Mach-O `__TEXT,__info_plist` section at link time, so the
# bare executable is a proper menu-bar agent (LSUIElement + bundle id). On first
# launch it re-signs itself with a per-user self-signed cert so the macOS
# Accessibility grant survives `brew upgrade` — no Apple Developer ID needed.
class Tessera < Formula
  desc "Menu-bar tiling window manager that puppets GUI apps via Accessibility"
  homepage "https://github.com/pa/tessera"
  license "MIT"

  # Stable release (so `brew install tessera` works without --HEAD). To ship a
  # new version: push a new tag, then bump `url` + `sha256` (the checksum of the
  # tag's source tarball: `curl -sL <url> | shasum -a 256`).
  url "https://github.com/pa/tessera/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "e0e2ec3229c34dfab55b91ddb2b3c3a93d26a91d49d694c07448d77cba836e38"
  head "https://github.com/pa/tessera.git", branch: "main"

  bottle do
    root_url "https://github.com/pa/tessera/releases/download/v0.1.2"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "4455e57ae97767b1d5f3f0fadeac8d2cf9f57285c6d9400f2248b3a7cc93c49f"
  end

  # Prebuilt binaries — so `brew install tessera` downloads in seconds instead of
  # compiling. Built by .github/workflows/bottle.yml and uploaded to the release.

  # Needs only the Swift toolchain from the Xcode Command Line Tools, which
  # Homebrew itself installs — so no extra tools beyond `brew`. (Deliberately
  # NOT `depends_on xcode`: this is a pure SwiftPM build and doesn't need the
  # full ~10 GB Xcode.app; requiring it also makes brew reject a merely-outdated
  # Xcode.) macOS 15+ matches Package.swift's platform floor.
  depends_on macos: :sequoia

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
