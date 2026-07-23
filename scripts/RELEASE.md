# Releasing Tessera

Releases are **fully automated** by `.github/workflows/release.yml`. To cut a
release, just push a tag:

```sh
git tag -a v0.1.2 -m "Tessera v0.1.2"
git push origin v0.1.2
```

That triggers CI, which (on an arm64 Sequoia runner):

1. Points the formula at the new tag's source tarball + checksum.
2. Creates the GitHub Release (auto-generated notes).
3. Builds a prebuilt **bottle** and uploads it to the release.
4. Commits the updated formula (source url+sha **and** the bottle block) to the
   tap repo `pa/homebrew-tessera` and mirrors it into this repo.

Users then get a fast, no-compile install: `brew install tessera`.

## One-time setup: the `TAP_TOKEN` secret

CI needs to push the formula to the **separate** tap repo, which the default
workflow token can't do. Create a token and add it as a secret:

1. GitHub → Settings → Developer settings → **Fine-grained personal access
   tokens** → Generate new token.
   - Resource owner: your account.
   - Repository access: **only** `pa/homebrew-tessera`.
   - Permissions: **Contents → Read and write**.
2. Copy the token.
3. In `pa/tessera` → Settings → Secrets and variables → Actions → **New
   repository secret** → name `TAP_TOKEN`, paste the token.

That's it — every future `git push origin vX.Y.Z` releases itself.
