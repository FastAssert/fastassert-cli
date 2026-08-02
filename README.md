# FastAssert CLI — releases

Release artifacts and the install script for the `fastassert` runner CLI.

**There is no source code here, and that is deliberate.** The runner is developed in a private
repository; this repo exists so the binaries and `install.sh` are anonymously downloadable, which a
private repo's release assets are not. An empty repo under a company name usually means an
abandoned project — this one means the opposite.

## Install

```sh
curl -fsSL https://get.fastassert.ai | sh
```

The script detects your platform, downloads the matching archive from this repo's Releases,
**verifies it against `SHA256SUMS` before extracting**, and installs to `/usr/local/bin` if
writable, otherwise `~/.local/bin`. It never calls `sudo` for you.

- `FASTASSERT_VERSION=v0.1.0` installs a specific tag instead of the latest release.
- `FASTASSERT_INSTALL_DIR=/some/dir` overrides where the binary lands.

## Verifying a download by hand

```sh
curl -fsSLO https://github.com/FastAssert/fastassert-cli/releases/download/<tag>/SHA256SUMS
curl -fsSLO https://github.com/FastAssert/fastassert-cli/releases/download/<tag>/fastassert_<tag>_<os>_<arch>.tar.gz
sha256sum -c SHA256SUMS      # or: shasum -a 256 -c SHA256SUMS
```

Platforms: macOS (arm64, amd64) and Linux (arm64, amd64). Windows is not supported.

Daemon registration (`fastassert runner install`) works on macOS via launchd and on Linux via a
systemd user unit. On Linux, remember `loginctl enable-linger $USER` — without it the daemon stops
when you log out.
