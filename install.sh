#!/usr/bin/env bash
# Install the Everstack CLI (evs).
#
# Usage:
#   curl -fsSL https://get.everstack.ai/install.sh | bash
#   curl -fsSL https://get.everstack.ai/install.sh | bash -s -- --version v0.2.1
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

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)   VERSION="${2:-}"; shift 2 ;;
    --bin-dir)   BIN_DIR="${2:-}"; shift 2 ;;
    --no-verify) VERIFY=0; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Resolve latest version if not pinned
if [[ -z "$VERSION" || "$VERSION" == "latest" ]]; then
  echo "Fetching latest version..."
  VERSION=$(
    curl -fsSL "https://api.github.com/repos/${RELEASES_REPO}/releases/latest" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  )
  if [[ -z "$VERSION" || "$VERSION" == "null" ]]; then
    echo "error: could not fetch latest version from GitHub" >&2
    exit 1
  fi
fi

# Detect OS and architecture
os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m)
case "$os" in
  linux)   ;;
  darwin)  ;;
  *) echo "error: unsupported OS: $os" >&2; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64)  arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) echo "error: unsupported architecture: $arch" >&2; exit 1 ;;
esac

ARCHIVE="everstack-${os}-${arch}.gz"
BASE_URL="https://github.com/${RELEASES_REPO}/releases/download/${VERSION}"

echo "Installing evs ${VERSION} (${os}/${arch}) to ${BIN_DIR}"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Download binary archive
echo "Downloading ${ARCHIVE}..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --retry 3 -o "${tmpdir}/${ARCHIVE}" "${BASE_URL}/${ARCHIVE}"
else
  wget -qO "${tmpdir}/${ARCHIVE}" "${BASE_URL}/${ARCHIVE}"
fi

# Verify checksum
if [[ "$VERIFY" -eq 1 ]]; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "${tmpdir}/SHA256SUMS.txt" "${BASE_URL}/SHA256SUMS.txt" 2>/dev/null || true
  else
    wget -qO "${tmpdir}/SHA256SUMS.txt" "${BASE_URL}/SHA256SUMS.txt" 2>/dev/null || true
  fi

  if [[ -s "${tmpdir}/SHA256SUMS.txt" ]]; then
    echo "Verifying checksum..."
    if command -v shasum >/dev/null 2>&1; then
      (cd "$tmpdir" && grep "${ARCHIVE}" SHA256SUMS.txt | shasum -a 256 -c --status) \
        && echo "Checksum verified." \
        || { echo "warning: checksum mismatch - proceeding anyway" >&2; }
    elif command -v sha256sum >/dev/null 2>&1; then
      (cd "$tmpdir" && grep "${ARCHIVE}" SHA256SUMS.txt | sha256sum -c --status) \
        && echo "Checksum verified." \
        || { echo "warning: checksum mismatch - proceeding anyway" >&2; }
    fi
  else
    echo "Checksums not available for this release; skipping verification."
  fi
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

# Keep 'everstack' as a backward-compatible alias
if [[ ! -e "${BIN_DIR}/everstack" ]]; then
  $SUDO ln -sf "${BIN_DIR}/evs" "${BIN_DIR}/everstack" 2>/dev/null || true
fi

# Confirm installed version
echo ""
if command -v "${BIN_DIR}/evs" >/dev/null 2>&1; then
  "${BIN_DIR}/evs" --version 2>/dev/null || echo "Installed ${VERSION}"
else
  echo "Installed ${VERSION} to ${BIN_DIR}/evs"
  echo "Make sure ${BIN_DIR} is in your PATH."
fi

echo ""
echo "Get started:"
echo "  evs login"
echo "  evs --help"
