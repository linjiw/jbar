#!/bin/bash
# Download and install the latest JBar developer preview from GitHub Releases.
#
# Usage from a clean macOS machine:
#   curl -fsSL https://raw.githubusercontent.com/linjiw/jbar/main/scripts/install-from-github.sh | bash
#
# A release ZIP and its SHA-256 file are downloaded separately. The ZIP is
# never installed until its checksum and Universal 2 bundle validation pass.
set -Eeuo pipefail

REPOSITORY="${JBAR_GITHUB_REPOSITORY:-linjiw/jbar}"
VERSION_REQUEST="latest"
NO_LAUNCH=0

usage() {
  cat <<'EOF'
Usage: install-from-github.sh [latest|vMAJOR.MINOR.PATCH] [--no-launch]

Downloads the matching Universal 2 JBar developer preview from GitHub and
installs it without Homebrew, Xcode, Swift, or a separate runtime. The preview
is ad-hoc signed but not notarized, so macOS may ask the user to approve its
first launch.
EOF
}

for argument in "$@"; do
  case "$argument" in
    --no-launch) NO_LAUNCH=1 ;;
    --help|-h) usage; exit 0 ;;
    latest|v[0-9]*|[0-9]*)
      [ "$VERSION_REQUEST" = latest ] || {
        echo "error: only one release selector may be provided" >&2
        exit 2
      }
      VERSION_REQUEST="$argument"
      ;;
    *)
      echo "error: unknown argument '$argument'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || {
  echo "error: JBar's prebuilt installer only supports macOS" >&2
  exit 1
}
[[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "error: JBAR_GITHUB_REPOSITORY must be owner/name" >&2
  exit 2
}

case "$VERSION_REQUEST" in
  latest)
    releases_json="$(curl --fail --silent --show-error --location \
      --proto '=https' --tlsv1.2 --retry 3 --retry-delay 1 \
      --max-filesize 1048576 \
      "https://api.github.com/repos/$REPOSITORY/releases?per_page=1")" || {
      echo "error: could not list published GitHub releases" >&2
      exit 1
    }
    tag="$(printf '%s' "$releases_json" | \
      /usr/bin/plutil -extract 0.tag_name raw - 2>/dev/null)" || {
      echo "error: GitHub returned no published release tag" >&2
      exit 1
    }
    ;;
  v[0-9]*.[0-9]*.[0-9]*) tag="$VERSION_REQUEST" ;;
  [0-9]*.[0-9]*.[0-9]*) tag="v$VERSION_REQUEST" ;;
  *)
    echo "error: release must be latest or vMAJOR.MINOR.PATCH" >&2
    exit 2
    ;;
esac

version="${tag#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: resolved release tag is not vMAJOR.MINOR.PATCH: $tag" >&2
  exit 1
}

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/jbar-github-install.XXXXXX")"
chmod 700 "$tmp_dir"
cleanup() {
  local status="$1"
  trap - EXIT INT TERM HUP
  rm -rf -- "$tmp_dir"
  exit "$status"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

archive_name="JBar-${version}-universal.zip"
archive="$tmp_dir/$archive_name"
checksum="$archive.sha256"
installer_name="JBar-install-prebuilt-${version}.sh"
installer="$tmp_dir/$installer_name"
installer_checksum="$installer.sha256"
base_url="https://github.com/$REPOSITORY/releases/download/$tag"

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 3 --retry-delay 1 --max-filesize 104857600 \
  --output "$archive" "$base_url/$archive_name"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 3 --retry-delay 1 --max-filesize 4096 \
  --output "$checksum" "$base_url/$archive_name.sha256"

expected="$(awk -v name="$archive_name" '$2 == name || $2 == "*" name { print $1 }' "$checksum")"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "error: release checksum file is malformed" >&2
  exit 1
}
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ] || {
  echo "error: downloaded release checksum does not match" >&2
  exit 1
}

curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 3 --retry-delay 1 --max-filesize 262144 --output "$installer" \
  "$base_url/$installer_name"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --retry 3 --retry-delay 1 --max-filesize 4096 --output "$installer_checksum" \
  "$base_url/$installer_name.sha256"
installer_expected="$(awk -v name="$installer_name" '$2 == name || $2 == "*" name { print $1 }' "$installer_checksum")"
[[ "$installer_expected" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "error: release installer checksum file is malformed" >&2
  exit 1
}
installer_actual="$(shasum -a 256 "$installer" | awk '{print $1}')"
[ "$(printf '%s' "$installer_actual" | tr '[:upper:]' '[:lower:]')" = \
  "$(printf '%s' "$installer_expected" | tr '[:upper:]' '[:lower:]')" ] || {
  echo "error: downloaded release installer checksum does not match" >&2
  exit 1
}
chmod 700 "$installer"

/bin/bash "$installer" --validate-archive "$archive"
extract_dir="$tmp_dir/extracted"
mkdir -m 700 "$extract_dir"
ditto -x -k --rsrc --extattr --qtn --noacl "$archive" "$extract_dir"
app="$extract_dir/JBar.app"
[ -d "$app" ] && [ ! -L "$app" ] || {
  echo "error: release archive does not contain JBar.app at its top level" >&2
  exit 1
}

if [ "$NO_LAUNCH" -eq 1 ]; then
  bash "$installer" "$app" --no-launch
else
  bash "$installer" "$app"
fi
