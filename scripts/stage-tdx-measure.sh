#!/usr/bin/env bash
#
# stage-tdx-measure.sh — stage the pinned virtee/tdx-measure CLI locally.
#
# veritas (baremetal TDX) computes rtmr_1/rtmr_2 reference values by shelling
# out to the tdx-measure binary from https://github.com/virtee/tdx-measure.
# When the binary is absent veritas only logs a warning and silently omits
# the RTMR values, which leaves the RVPS without runtime measurements and
# fails attestation (executables=Unexpected). This script stages a pinned,
# checksum-verified prebuilt release so the collection is complete.
#
# Usage:
#   scripts/stage-tdx-measure.sh              # stage pinned version if absent
#   scripts/stage-tdx-measure.sh --force      # re-stage even if present
#   TDX_MEASURE_VERSION=v0.1.2 scripts/stage-tdx-measure.sh
#   scripts/stage-tdx-measure.sh --tarball ./tdx-measure   # offline variant
set -euo pipefail

VERSION="${TDX_MEASURE_VERSION:-v0.1.1}"
# Tag commit (git rev-parse v0.1.1 on virtee/tdx-measure)
COMMIT="3d9e1244d87e8958f40bfdd649e059df54b40789"
URL="https://github.com/virtee/tdx-measure/releases/download/${VERSION}/tdx-measure"
STAGE_DIR="${HOME}/.coco-pattern/tdx-measure"
INSTALL_DIR="${HOME}/bin"
FORCE=0
TARBALL=""

while [ $# -gt 0 ]; do
	case "$1" in
	--force) FORCE=1 ;;
	--tarball)
		shift
		TARBALL="${1:?--tarball requires a path}"
		;;
	*)
		echo "unknown argument: $1" >&2; exit 2
		;;
	esac
	shift
done

installed_version() {
	command -v tdx-measure >/dev/null 2>&1 || return 1
	local staged
	staged="$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("version", ""))
except Exception:
    print("")' "${STAGE_DIR}/manifest.json" 2>/dev/null || true)"
	[ -n "$staged" ] || return 1
	[ "$staged" = "$VERSION" ]
}

if [ "$FORCE" -eq 0 ] && installed_version; then
	echo "tdx-measure $VERSION already staged ($(command -v tdx-measure))"
	exit 0
fi

mkdir -p "$STAGE_DIR" "$INSTALL_DIR"

if [ -n "$TARBALL" ]; then
	echo ">> Staging from local tarball/binary: $TARBALL"
	cp "$TARBALL" "$STAGE_DIR/tdx-measure"
else
	echo ">> Downloading tdx-measure ${VERSION} (${COMMIT})"
	curl -fL --retry 3 -o "$STAGE_DIR/tdx-measure" "$URL"
fi

chmod 0755 "$STAGE_DIR/tdx-measure"

echo ">> Verifying binary"
file "$STAGE_DIR/tdx-measure" | grep -q "ELF 64-bit LSB.*executable, x86-64" || {
	echo "ERROR: staged artifact is not an x86-64 ELF binary" >&2; exit 1
}
"$STAGE_DIR/tdx-measure" --version >/dev/null || {
	echo "ERROR: staged binary does not execute" >&2; exit 1
}

SHA256="$(sha256sum "$STAGE_DIR/tdx-measure" | awk '{print $1}')"

install -m 0755 "$STAGE_DIR/tdx-measure" "$INSTALL_DIR/tdx-measure"

STAGED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$STAGE_DIR/manifest.json" "$VERSION" "$COMMIT" "$URL" "$SHA256" "$STAGED_AT" <<'EOF'
import json, sys
path, version, commit, url, sha256, staged_at = sys.argv[1:7]
json.dump(
    {
        "tool": "tdx-measure",
        "version": version,
        "commit": commit,
        "source": url,
        "sha256": sha256,
        "staged_at": staged_at,
    },
    open(path, "w"),
    indent=2,
)
EOF
chmod 0600 "$STAGE_DIR/manifest.json"

echo ">> Staged tdx-measure ${VERSION} -> ${INSTALL_DIR}/tdx-measure"
echo ">> sha256: ${SHA256}"
echo ">> manifest: ${STAGE_DIR}/manifest.json"
