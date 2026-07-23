import Foundation

// Private "responsibility" SPI. macOS attributes a process's TCC prompts
// (Accessibility, etc.) to its *responsible* process — for a binary launched
// from a terminal, that's the terminal (e.g. Alacritty), not us. Disclaiming it
// on a re-spawn makes Tessera its own responsible process, so the Accessibility
// grant is attributed to "Tessera". Same symbols yabai/AeroSpace-style tools use.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(
    _ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

/// Launch bootstrap that makes Tessera behave like a first-class agent from a
/// bare binary — no `.app`, no Apple Developer ID. Two jobs:
///
/// 1. **Stable signature (grant survives `brew upgrade`).** A Homebrew source
///    build (and each upgrade) is **ad-hoc** signed, whose Designated
///    Requirement is the exact code hash — so TCC would drop the Accessibility
///    grant on every update. We re-sign the binary with a **per-user self-signed
///    cert** (created once on this machine). Every version then shares one DR
///    (`identifier "pramodh.ayyappan.tessera" and certificate leaf = H"<cert>"`),
///    and TCC — which matches the DR, not the path — keeps the grant.
///
/// 2. **Correct TCC attribution (grant shows "Tessera", not the terminal).**
///    When launched from a terminal, macOS blames the terminal for our TCC
///    prompts. We disclaim that responsibility on the re-spawn so the grant is
///    attributed to Tessera itself.
///
/// If already signed *and* self-responsible, do nothing. Otherwise fix whichever
/// is wrong and re-exec once — disclaiming the terminal — guarded against loops.
enum SelfSign {
    static let identity = "Tessera Code Signing"
    private static let loopGuardEnv = "TESSERA_SELFSIGN_DONE"

    static func bootstrap() {
        guard let path = executablePath() else { return }
        let signed = isSigned(path, with: identity)
        let selfResponsible = isSelfResponsible()
        if signed && selfResponsible { return } // nothing to fix

        // Don't loop if a prior attempt didn't take.
        if ProcessInfo.processInfo.environment[loopGuardEnv] == "1" {
            if !signed { NSLog("Tessera: still not signed with '\(identity)'; running ad-hoc.") }
            if !selfResponsible { NSLog("Tessera: could not disclaim terminal responsibility.") }
            return
        }

        if !signed {
            if !certExists(identity) {
                guard createCert() else {
                    NSLog("Tessera: could not create signing cert; running ad-hoc.")
                    return
                }
            }
            guard sign(path, with: identity) else {
                NSLog("Tessera: self-sign failed; running ad-hoc.")
                return
            }
        }
        // Re-exec disclaimed: runs the freshly-signed binary AND makes us our own
        // responsible process, so TCC shows "Tessera".
        relaunchDisclaimed(path)
    }

    // MARK: - Steps

    private static func executablePath() -> String? {
        if let path = Bundle.main.executablePath { return path }
        return ProcessInfo.processInfo.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }

    private static func isSigned(_ path: String, with identity: String) -> Bool {
        // `codesign -dvvv` prints the authority chain to stderr.
        run("/usr/bin/codesign", ["-dvvv", path]).output.contains("Authority=\(identity)")
    }

    private static func certExists(_ identity: String) -> Bool {
        // NOT `-v`: a self-signed codesigning cert always reports
        // CSSMERR_TP_NOT_TRUSTED, so the valid-only listing hides it even though
        // `codesign` signs with it fine. Using `-v` here would make us think the
        // cert is missing and destructively recreate it — minting a *new* leaf,
        // changing the DR, and losing the Accessibility grant on every launch.
        run("/usr/bin/security", ["find-identity", "-p", "codesigning"]).output.contains(identity)
    }

    private static func sign(_ path: String, with identity: String) -> Bool {
        // Unlock the dedicated keychain so codesign can reach the key non-interactively.
        _ = run("/usr/bin/security", ["unlock-keychain", "-p", "tessera-signing", "tessera-signing.keychain"])
        return run("/usr/bin/codesign", ["--force", "--sign", identity, path]).status == 0
    }

    private static func createCert() -> Bool {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tessera-cert.sh")
        do { try certScript.write(to: scriptURL, atomically: true, encoding: .utf8) } catch { return false }
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        return run("/bin/bash", [scriptURL.path]).status == 0 && certExists(identity)
    }

    /// True unless macOS clearly names a *different* process as responsible for
    /// us (the terminal case). Errors/unknown are treated as self-responsible so
    /// we never relaunch needlessly (or loop).
    private static func isSelfResponsible() -> Bool {
        let me = getpid()
        let responsible = responsibility_get_pid_responsible_for_pid(me)
        return !(responsible > 0 && responsible != me)
    }

    /// Re-exec this binary in place, disclaiming the terminal's TCC
    /// responsibility so the Accessibility grant is attributed to Tessera.
    private static func relaunchDisclaimed(_ path: String) {
        setenv(loopGuardEnv, "1", 1)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        _ = responsibility_spawnattrs_setdisclaim(&attr, 1)
        // SETEXEC replaces the current image (like execv) instead of forking, so
        // launchd/the shell keeps tracking the same pid — but now disclaimed.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))
        var argv = ProcessInfo.processInfo.arguments.map { strdup($0) }
        argv.append(nil)
        let rc = posix_spawn(nil, path, nil, &attr, argv, environ)
        // With POSIX_SPAWN_SETEXEC this only returns on failure.
        NSLog("Tessera: disclaimed relaunch failed (rc \(rc)); continuing in place.")
    }

    // MARK: - Process helper

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Non-interactive per-user cert creation (mirrors scripts/create-signing-cert.sh).
    private static let certScript = """
    set -euo pipefail
    IDENTITY_NAME="Tessera Code Signing"
    KEYCHAIN_NAME="tessera-signing.keychain"
    KEYCHAIN_PATH="$HOME/Library/Keychains/${KEYCHAIN_NAME}-db"
    KEYCHAIN_PASSWORD="tessera-signing"
    if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then exit 0; fi
    OPENSSL="/usr/bin/openssl"
    P12_PASSWORD="tessera-p12"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<EOF
    [req]
    distinguished_name = dn
    x509_extensions = v3
    prompt = no
    [dn]
    CN = ${IDENTITY_NAME}
    [v3]
    basicConstraints = critical, CA:false
    keyUsage = critical, digitalSignature
    extendedKeyUsage = critical, codeSigning
    EOF
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1
    "$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY_NAME" -out "$WORK/identity.p12" -passout pass:"$P12_PASSWORD" >/dev/null 2>&1
    security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    security set-keychain-settings "$KEYCHAIN_NAME"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    security import "$WORK/identity.p12" -k "$KEYCHAIN_NAME" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME" >/dev/null 2>&1 || true
    CURRENT="$(security list-keychains -d user | sed -e 's/^[[:space:]]*//' -e 's/"//g')"
    if ! grep -q "$KEYCHAIN_NAME" <<<"$CURRENT"; then
        security list-keychains -d user -s "$KEYCHAIN_PATH" $CURRENT
    fi
    """
}
