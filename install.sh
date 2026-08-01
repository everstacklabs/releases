#!/usr/bin/env bash
# Install the Everstack CLI (evs).
#
# Usage:
#   curl -fsSL https://get.everstack.ai/install.sh | bash
#   curl -fsSL https://get.everstack.ai/install.sh | bash -s -- --version v0.1.22
#   curl -fsSL https://get.everstack.ai/install.sh | bash -s -- --bin-dir ~/.local/bin
#
# Flags:
#   --version <vX.Y.Z|latest>    Version to install (default: latest)
#   --bin-dir <path>             Install directory (default: /usr/local/bin)
#   --no-verify                  Skip SHA256 checksum verification
#   -h, --help                   Show this message

set -euo pipefail

VERSION=""
BIN_DIR="/usr/local/bin"
VERIFY=1
RELEASES_REPO="everstacklabs/releases"

die() { echo "error: $*" >&2; exit 1; }

# Printed inline rather than scraped out of "$0" with sed: under the documented
# `curl ... | bash` invocation "$0" is "bash" and the script only exists on
# stdin, so reading the file back is guaranteed to come up empty.
usage() {
  cat <<'EOF'
Install the Everstack CLI (evs).

Usage:
  curl -fsSL https://get.everstack.ai/install.sh | bash
  curl -fsSL https://get.everstack.ai/install.sh | bash -s -- --version v0.1.22
  curl -fsSL https://get.everstack.ai/install.sh | bash -s -- --bin-dir ~/.local/bin

Flags:
  --version <vX.Y.Z|latest>    Version to install (default: latest)
  --bin-dir <path>             Install directory (default: /usr/local/bin)
  --no-verify                  Skip SHA256 checksum verification
  -h, --help                   Show this message
EOF
}

# Parse flags. Each value-taking flag checks for its argument explicitly: a bare
# `shift 2` with nothing left would trip `set -e` and abort with no explanation.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 && -n "${2:-}" ]] || die "--version requires a value (e.g. --version v0.1.22)"
      VERSION="$2"; shift 2 ;;
    --bin-dir)
      [[ $# -ge 2 && -n "${2:-}" ]] || die "--bin-dir requires a value (e.g. --bin-dir ~/.local/bin)"
      BIN_DIR="$2"; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; echo >&2; usage >&2; exit 1 ;;
  esac
done

fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
  else
    die "neither curl nor wget is available"
  fi
}

fetch_stdout() { # fetch_stdout <url>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    die "neither curl nor wget is available"
  fi
}

# Resolve the latest version from the /releases/latest redirect, which points at
# /releases/tag/<version>. Preferred over api.github.com because the REST API is
# rate limited to 60 requests/hour for unauthenticated callers *per IP* — enough
# to make this installer fail with an opaque 403 on shared CI egress addresses.
resolve_latest_via_redirect() {
  local location
  if command -v curl >/dev/null 2>&1; then
    location=$(curl -fsSI "https://github.com/${RELEASES_REPO}/releases/latest" 2>/dev/null \
      | tr -d '\r' | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tail -1)
  else
    location=$(wget -qS --max-redirect=0 -O /dev/null \
      "https://github.com/${RELEASES_REPO}/releases/latest" 2>&1 \
      | tr -d '\r' | sed -n 's/^[[:space:]]*[Ll]ocation:[[:space:]]*//p' | tail -1)
  fi
  [[ -n "$location" ]] || return 1
  printf '%s\n' "${location##*/releases/tag/}"
}

# Fallback for the (unlikely) case the redirect shape changes.
resolve_latest_via_api() {
  local tag
  tag=$(fetch_stdout "https://api.github.com/repos/${RELEASES_REPO}/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1) || return 1
  [[ -n "$tag" ]] || return 1
  printf '%s\n' "$tag"
}

if [[ -z "$VERSION" || "$VERSION" == "latest" ]]; then
  echo "Fetching latest version..."
  VERSION=$(resolve_latest_via_redirect || resolve_latest_via_api || true)
  if [[ -z "$VERSION" || "$VERSION" == "null" || "$VERSION" != v* ]]; then
    echo "error: could not determine the latest evs version." >&2
    echo "Check https://github.com/${RELEASES_REPO}/releases and pin one explicitly:" >&2
    echo "  curl -fsSL https://get.everstack.ai/install.sh | bash -s -- --version vX.Y.Z" >&2
    exit 1
  fi
fi

# Detect OS and architecture
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$os" in
  linux)   ;;
  darwin)  ;;
  *) die "unsupported OS: $os (evs ships linux and darwin builds)" ;;
esac
case "$arch" in
  x86_64|amd64)  arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) die "unsupported architecture: $arch" ;;
esac

ARCHIVE="everstack-${os}-${arch}.gz"
BASE_URL="https://github.com/${RELEASES_REPO}/releases/download/${VERSION}"

echo "Installing evs ${VERSION} (${os}/${arch}) to ${BIN_DIR}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Download binary archive
echo "Downloading ${ARCHIVE}..."
fetch "${BASE_URL}/${ARCHIVE}" "${tmpdir}/${ARCHIVE}" \
  || die "download failed: ${BASE_URL}/${ARCHIVE}"

# Verify checksum. A mismatch, a missing checksum file, or an unusable line all
# abort the install: this is the only thing standing between a hijacked release
# asset and /usr/local/bin, so "warn and continue" would make it decorative.
# Use --no-verify to opt out deliberately.
if [[ "$VERIFY" -eq 1 ]]; then
  if ! fetch "${BASE_URL}/SHA256SUMS.txt" "${tmpdir}/SHA256SUMS.txt" 2>/dev/null \
     || [[ ! -s "${tmpdir}/SHA256SUMS.txt" ]]; then
    die "could not download ${BASE_URL}/SHA256SUMS.txt (re-run with --no-verify to skip verification)"
  fi

  if command -v shasum >/dev/null 2>&1; then
    checksum_cmd=(shasum -a 256)
  elif command -v sha256sum >/dev/null 2>&1; then
    checksum_cmd=(sha256sum)
  else
    die "no shasum or sha256sum available to verify the download (re-run with --no-verify to skip verification)"
  fi

  # Anchor on the exact filename. An unanchored grep can pull sibling entries
  # (everstack-ee-*, everstack-services-*) and a zero-match grep would feed
  # empty stdin to the checker, which is not a pass.
  expected=$(awk -v want="$ARCHIVE" '$2 == want || $2 == "*" want { print $1; found++ } END { exit(found == 1 ? 0 : 1) }' \
    "${tmpdir}/SHA256SUMS.txt") \
    || die "expected exactly one checksum entry for ${ARCHIVE} in SHA256SUMS.txt"

  echo "Verifying checksum..."
  actual=$(cd "$tmpdir" && "${checksum_cmd[@]}" "$ARCHIVE" | awk '{print $1}')
  if [[ "$actual" != "$expected" ]]; then
    echo "error: checksum mismatch for ${ARCHIVE}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    die "refusing to install a binary that does not match the published checksum"
  fi
  echo "Checksum verified."
fi

# Extract and install
gunzip -c "${tmpdir}/${ARCHIVE}" > "${tmpdir}/evs"
chmod +x "${tmpdir}/evs"

# Create the target dir as the current user first. A not-yet-existing but
# creatable dir (e.g. ~/.local/bin) would otherwise fail the -w test below
# and needlessly escalate to sudo.
mkdir -p "$BIN_DIR" 2>/dev/null || true

# Fall back to sudo only if the dir still isn't writable (e.g. the default
# /usr/local/bin, which is root-owned on macOS).
SUDO=""
if [[ ! -w "$BIN_DIR" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    echo "Requesting sudo to install to ${BIN_DIR}..."
  else
    echo "error: ${BIN_DIR} is not writable and sudo is not available" >&2
    echo "Re-run with --bin-dir pointing to a writable directory, e.g.:" >&2
    echo "  curl -fsSL https://get.everstack.ai/install.sh | bash -s -- --bin-dir ~/.local/bin" >&2
    exit 1
  fi
fi

$SUDO mkdir -p "$BIN_DIR"
$SUDO install -m 0755 "${tmpdir}/evs" "${BIN_DIR}/evs"

# Refresh the backward-compatible 'everstack' alias unconditionally. Installs
# predating the evs rename wrote a full ~127MB *binary* to this path, so a
# "create only if absent" guard would leave those users silently running a
# stale copy forever. Only skip if it already points where we want.
if [[ "$($SUDO readlink "${BIN_DIR}/everstack" 2>/dev/null || true)" != "${BIN_DIR}/evs" ]]; then
  $SUDO rm -f "${BIN_DIR}/everstack" 2>/dev/null || true
  $SUDO ln -sf "${BIN_DIR}/evs" "${BIN_DIR}/everstack" 2>/dev/null || true
fi

echo ""
"${BIN_DIR}/evs" --version 2>/dev/null || echo "Installed ${VERSION} to ${BIN_DIR}/evs"

# Warn when the install won't actually be reachable as `evs`. Note that
# `command -v "${BIN_DIR}/evs"` cannot answer this: an absolute path to any
# executable file always succeeds, so it never catches the broken case.
resolved=$(command -v evs 2>/dev/null || true)
if [[ -z "$resolved" ]]; then
  echo ""
  echo "warning: ${BIN_DIR} is not on your PATH, so 'evs' won't resolve yet."
  echo "Add it to your shell profile:"
  echo "  export PATH=\"${BIN_DIR}:\$PATH\""
elif [[ "$resolved" != "${BIN_DIR}/evs" ]]; then
  echo ""
  echo "warning: another evs earlier on your PATH will shadow this install:"
  echo "  in use:    ${resolved}"
  echo "  installed: ${BIN_DIR}/evs"
  echo "Remove the other copy, or put ${BIN_DIR} ahead of it on your PATH."
fi

echo ""
echo "Get started:"
echo "  evs login"
echo "  evs --help"
