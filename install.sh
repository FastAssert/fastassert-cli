#!/bin/sh
# FastAssert runner CLI installer.
#
#   curl -fsSL https://raw.githubusercontent.com/FastAssert/fastassert-cli/main/install.sh | sh
#
# (get.fastassert.ai will redirect here once its DNS exists; the raw URL is what resolves today.)
#
# Everything lives inside main(), called on the LAST line. That is the single most important
# defence in a `curl | sh` installer: if the connection drops mid-transfer, the shell executes
# whatever bytes arrived — and a half-downloaded script that has only defined functions does
# nothing, whereas a half-downloaded sequence of top-level commands does something arbitrary.
#
# POSIX sh, no bashisms: this runs on whatever /bin/sh the machine has, including dash and busybox.
set -eu

REPO="FastAssert/fastassert-cli"

log()  { printf '%s\n' "$*"; }
err()  { printf 'error: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# require_downloader fails EARLY and specifically when HTTPS cannot be enforced, rather than
# letting every request fail later and be misreported as a network problem. busybox wget rejects
# --https-only outright, which is a real and common case (alpine, many container images).
require_downloader() {
  command -v curl >/dev/null 2>&1 && return 0
  if command -v wget >/dev/null 2>&1; then
    if wget --help 2>&1 | grep -q -- "--https-only"; then
      return 0
    fi
    die "this wget does not support --https-only (busybox?), so HTTPS cannot be enforced for the download. Install curl and re-run."
  fi
  die "neither curl nor wget is available"
}

# http_get URL DEST -> writes the body to DEST, prints a status TOKEN on stdout:
#
#   <numeric>  the HTTP status (curl only)
#   ERR        the server returned an error response, but this downloader cannot say which
#              (GNU wget exits 8 for any HTTP error without reporting the code)
#   000        transport failure — DNS, connection refused, TLS, timeout
#
# The token is the point: collapsing everything into "download failed" is what made a fresh
# install print a raw `curl: (56) ... 404` and then a vague message, when the real situation — no
# releases published yet — is specific and worth saying plainly.
#
# curl prints `000` on stdout ITSELF when the transfer fails, so a naive `|| printf '000'` appends
# a second one and yields "000000", which matches no case and reports "unexpected response (HTTP
# 000000)". Capture first, then override on a non-zero exit; that also maps a mid-body failure
# after a 200 to 000, which is the fail-closed direction.
http_get() {
  _err="${tmp:-${TMPDIR:-/tmp}}/http.err"
  if command -v curl >/dev/null 2>&1; then
    _code="$(curl --proto '=https' --tlsv1.2 -sSL -o "$2" -w '%{http_code}' "$1" 2>"$_err")" || _code=000
    printf '%s' "${_code:-000}"
    return 0
  fi
  # Capture the exit code explicitly. Under `set -e` an unprotected non-zero wget exits the whole
  # script before the case is ever reached — so on a wget machine an HTTP error killed the
  # installer silently, with no message at all. The curl arm is protected by its `||`; this arm
  # was not, and no test executed it.
  _rc=0
  wget --https-only -qO "$2" "$1" 2>"$_err" || _rc=$?
  case "$_rc" in
    0) printf '200' ;;
    # GNU wget: 8 = "server issued an error response". It does NOT say which, so claiming the
    # network is unreachable here would be a false diagnosis of the most common case.
    8) printf 'ERR' ;;
    *) printf '000' ;;
  esac
}

# transport_detail returns the downloader's own last error line, if any. A TLS failure (corporate
# MITM) is otherwise indistinguishable from being offline, and it is the one diagnostic worth not
# swallowing on a `curl | sh` installer.
transport_detail() {
  _err="${tmp:-${TMPDIR:-/tmp}}/http.err"
  [ -s "$_err" ] || return 0
  printf '\n  %s' "$(tail -n 1 "$_err")"
}

detect_platform() {
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    *)
      die "unsupported operating system: $os. FastAssert ships macOS and Linux binaries; Windows is not supported."
      ;;
  esac
  case "$arch" in
    x86_64|amd64)  arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) die "unsupported architecture: $arch (supported: x86_64/amd64, arm64/aarch64)" ;;
  esac
  printf '%s %s' "$os" "$arch"
}

# Refuse early and clearly if we cannot verify at all, rather than discovering it after a download
# and reporting it as a checksum mismatch.
require_sha_tool() {
  command -v sha256sum >/dev/null 2>&1 && return 0
  command -v shasum >/dev/null 2>&1 && return 0
  die "no sha256 tool found (need sha256sum or shasum). Refusing to install unverified binaries."
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Compute the digest and STRING-COMPARE it. Deliberately not `sha256sum -c`, whose behaviour on
# input containing no checksum lines is implementation-defined and dangerous here: on stock macOS
# /sbin/sha256sum exits 0 for EMPTY input (verified), so the natural
# `grep " $archive$" sums | sha256sum -c -` silently SUCCEEDS when SHA256SUMS has no entry for the
# archive — a truncated or wrong sums file would install unverified bytes and report success. GNU
# coreutils fails closed; Darwin's does not, and macOS is the primary target. Comparing hex strings
# is immune to every implementation's quirks.
verify_checksum() {
  archive="$1"; sums="$2"
  expected="$(awk -v want="$archive" '$2 == want { print $1; exit }' "$sums")"
  if [ -z "$expected" ]; then
    die "SHA256SUMS has no entry for ${archive}. Nothing was installed — refusing to install an artifact the checksum file does not cover."
  fi
  actual="$(sha256_of "$archive")"
  [ "$expected" = "$actual" ]
}

choose_bindir() {
  if [ -n "${FASTASSERT_INSTALL_DIR:-}" ]; then
    printf '%s' "$FASTASSERT_INSTALL_DIR"
  elif [ -w /usr/local/bin ] 2>/dev/null; then
    printf '%s' /usr/local/bin
  else
    printf '%s' "$HOME/.local/bin"
  fi
}

on_path() {
  case ":${PATH}:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  platform="$(detect_platform)"
  os="${platform% *}"
  arch="${platform#* }"

  tmp="$(mktemp -d)"
  # INT/TERM listed explicitly: not every shell runs an EXIT trap on an untrapped signal (dash),
  # which would leak the temp dir.
  trap 'rm -rf "$tmp" "${stage:-}"' EXIT INT TERM

  version="${FASTASSERT_VERSION:-}"
  if [ -z "$version" ]; then
    log "resolving latest release..."
    # /releases/latest excludes drafts and prereleases, so a rehearsal tag is never installed.
    code="$(http_get "https://api.github.com/repos/${REPO}/releases/latest" "${tmp}/latest.json")"
    case "$code" in
      200) ;;
      404)
        die "no releases have been published for ${REPO} yet, so there is nothing to install.
  If you are expecting a specific version, set FASTASSERT_VERSION=vX.Y.Z.
  Otherwise check https://github.com/${REPO}/releases for the current state."
        ;;
      403|429)
        die "GitHub rate-limited this request (HTTP ${code}). Wait a few minutes, or set FASTASSERT_VERSION=vX.Y.Z to skip the lookup."
        ;;
      ERR)
        die "api.github.com returned an error response while resolving the latest release.
  If you are expecting a specific version, set FASTASSERT_VERSION=vX.Y.Z."
        ;;
      000)
        die "could not reach api.github.com — check network access, a proxy, or DNS.$(transport_detail)"
        ;;
      *)
        die "unexpected response from api.github.com (HTTP ${code}) while resolving the latest release."
        ;;
    esac
    version="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${tmp}/latest.json" | head -n 1)"
    [ -n "$version" ] || die "api.github.com returned a release with no tag_name. Set FASTASSERT_VERSION=vX.Y.Z to install a specific tag."
  fi

  archive="fastassert_${version}_${os}_${arch}.tar.gz"
  base="https://github.com/${REPO}/releases/download/${version}"

  require_sha_tool

  log "downloading ${archive}"
  code="$(http_get "${base}/${archive}" "${tmp}/${archive}")"
  case "$code" in
    200) ;;
    404) die "${version} has no build for ${os}/${arch}.
  Published assets for that tag: https://github.com/${REPO}/releases/tag/${version}" ;;
    ERR) die "github.com returned an error response for ${archive}. Published assets for ${version}: https://github.com/${REPO}/releases/tag/${version}" ;;
    000) die "could not reach github.com to download ${archive} — check network access, a proxy, or DNS.$(transport_detail)" ;;
    *)   die "downloading ${archive} failed (HTTP ${code})." ;;
  esac
  code="$(http_get "${base}/SHA256SUMS" "${tmp}/SHA256SUMS")"
  [ "$code" = "200" ] || die "could not download SHA256SUMS for ${version} (HTTP ${code}). Refusing to install an unverified binary."

  log "verifying checksum"
  ( cd "$tmp" && verify_checksum "$archive" SHA256SUMS ) \
    || die "CHECKSUM MISMATCH for ${archive}. Nothing was installed. This may mean a corrupted download or a tampered artifact — do not retry blindly; report it."

  tar -xzf "${tmp}/${archive}" -C "$tmp" || die "could not extract ${archive}"
  [ -f "${tmp}/fastassert" ] || die "archive did not contain a 'fastassert' binary"
  chmod +x "${tmp}/fastassert"

  bindir="$(choose_bindir)"
  mkdir -p "$bindir" 2>/dev/null || true
  if [ ! -w "$bindir" ]; then
    die "cannot write to ${bindir}. Re-run with FASTASSERT_INSTALL_DIR=<a writable dir>, or move ${tmp}/fastassert there yourself. This installer never calls sudo for you."
  fi

  target="${bindir}/fastassert"
  if [ -d "$target" ]; then
    die "${target} is a directory. Refusing to continue — mv would move the binary INSIDE it and report success."
  fi
  # Stat the TARGET, not whatever `fastassert` resolves to on PATH — reporting the version of some
  # other copy elsewhere would make an upgrade look like a no-op.
  if [ -x "$target" ]; then
    current="$("$target" --version 2>/dev/null || printf 'unknown')"
    log "replacing existing install (${current} -> ${version})"
  fi

  # Stage INSIDE bindir first. mv is only atomic within one filesystem, and $tmp is usually tmpfs
  # on Linux while $bindir is on the root fs — that cross-device mv degrades to copy+unlink, so an
  # interrupt mid-copy would leave a PARTIAL EXECUTABLE on PATH, the very thing this avoids. Same
  # directory guarantees same filesystem. (cp over the target is also wrong: replacing a running
  # binary that way is ETXTBSY on Linux.)
  stage="${bindir}/.fastassert.install.$$"
  cp "${tmp}/fastassert" "$stage" || die "could not stage into ${bindir}"
  chmod +x "$stage"
  mv "$stage" "$target" || die "could not install to ${target}"
  stage=""

  log ""
  log "installed fastassert ${version} to ${target}"

  if ! on_path "$bindir"; then
    log ""
    log "${bindir} is not on your PATH. Add it:"
    log "    export PATH=\"${bindir}:\$PATH\""
  fi

  # The runner is a daemon. Replacing the binary does not restart it, so without this the operator
  # believes they upgraded while the old process keeps running until the next reload.
  log ""
  log "If a runner daemon is already registered, restart it to pick this up:"
  log "    fastassert runner install"
  log ""
  log "Next: write config.toml with your api_url and runner_key, then run 'fastassert runner install'."
  log "Daemon registration is macOS-only for now; on Linux the CLI works and 'fastassert runner run' runs in the foreground."
}

main "$@"
