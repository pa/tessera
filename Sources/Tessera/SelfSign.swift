import Foundation

/// Makes the Accessibility grant survive `brew upgrade` without an Apple
/// Developer ID.
///
/// A Homebrew source build (and each upgrade) produces an **ad-hoc** signature,
/// whose Designated Requirement is the exact code hash — so TCC drops the
/// Accessibility grant on every update. To fix that for free, on launch we
/// re-sign the binary with a **per-user self-signed cert** (created once on this
/// machine). Every version then shares the same DR
/// (`identifier "cloud.facets.tessera" and certificate leaf = H"<user cert>"`),
/// and TCC — which matches on the DR, not the path — keeps the grant.
///
/// Flow: if already signed with the cert, do nothing. Otherwise create the cert
/// if missing, `codesign` this binary, and re-exec once (guarded against loops).
enum SelfSign {
    static let identity = "Tessera Code Signing"
    private static let loopGuardEnv = "TESSERA_SELFSIGN_DONE"

    static func ensureSignedAndRelaunch() {
        guard let path = executablePath() else { return }
        if isSigned(path, with: identity) { return } // already stable-signed

        // Don't loop if a prior attempt didn't take.
        if ProcessInfo.processInfo.environment[loopGuardEnv] == "1" {
            NSLog("Tessera: still not signed with '\(identity)' after self-sign; running ad-hoc.")
            return
        }

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
        relaunch(path)
    }

    // MARK: - Steps

    private static func executablePath() -> String? {
        if let path = Bundle.main.executablePath { return path }
        return CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
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

    private static func relaunch(_ path: String) {
        setenv(loopGuardEnv, "1", 1)
        var cArgs = CommandLine.arguments.map { strdup($0) }
        cArgs.append(nil)
        execv(path, &cArgs)
        NSLog("Tessera: re-exec after self-sign failed (errno \(errno)).") // execv only returns on failure
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
