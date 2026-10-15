#!/usr/bin/env bash
#
# stage-attestation-key.sh — pin a validated attestation-token signing key.
#
# The Red Hat build of Trustee (v1.2.1) was observed minting internally
# inconsistent attestation tokens for one cert-manager-issued P-256 key: the
# JWK embedded in the token header did not match the signing key, so every
# resource request failed with TokenVerifierError(InvalidSignature) even
# though the secret's key/cert pair matched (see
# coco-gsd/specs/001-automate-baremetal-testing/CONNECTED-CYCLE-2026-10-15-AAR.md).
# The exact mechanism is unconfirmed; re-issuing the key fixed it.
#
# Rather than accepting a random per-deploy signing key (a trust anchor!) and
# hoping it is good, this script:
#   1. generates a P-256 keypair + self-signed cert matching the
#      attestation-token Certificate spec (CN, organization, duration)
#   2. deterministically validates it by reproducing the exact token flow:
#      signs a JWT the way the AS ear-token broker does and verifies it the
#      way the KBS jsonwebtoken verifier does
#   3. applies it as the attestation-cert secret and restarts the KBS
#
# cert-manager adopts a pre-existing secret whose certificate matches the
# Certificate spec and is outside its renewal window, so the pinned key
# persists until the normal renewal horizon.
#
# Usage:
#   scripts/stage-attestation-key.sh                 # stage if absent/invalid
#   scripts/stage-attestation-key.sh --force         # re-stage a fresh key
#   scripts/stage-attestation-key.sh --key ./k.pem   # pin a provided key
set -euo pipefail

NS="${NS:-trustee-operator-system}"
SECRET="${SECRET:-attestation-cert}"
DEPLOY="${DEPLOY:-trustee-deployment}"
CN="${CN:-kbs-trustee-operator-system}"
ORG="${ORG:-Red Hat}"
DAYS="${DAYS:-365}"
FORCE=0
KEYFILE=""
STAGE_DIR="${HOME}/.coco-pattern/attestation-key"

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1 ;;
        --key) shift; KEYFILE="${1:?--key requires a PEM path}" ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Round-trip validator: sign exactly as the AS ear-token broker does, verify
# exactly as the KBS jsonwebtoken verifier does. Any failure => the keypair
# must not be used as an attestation signing key.
# ---------------------------------------------------------------------------
validate_key() {
    python3 - "$1" <<'EOF'
import base64, json, sys
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.exceptions import InvalidSignature
from pathlib import Path

key = serialization.load_pem_private_key(Path(sys.argv[1]).read_bytes(), password=None)
if not isinstance(key, ec.EllipticCurvePrivateKey) or key.curve.name != "secp256r1":
    sys.exit("not a P-256 key")

def b64url(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

# AS side (attestation-service ear_token/broker.rs pubkey_jwk + sign)
nums = key.public_key().public_numbers()
jwk = {
    "kty": "EC", "crv": "P-256", "alg": "ES256",
    "x": b64url(nums.x.to_bytes(32, "big")),
    "y": b64url(nums.y.to_bytes(32, "big")),
}
header = {"alg": "ES256", "typ": "JWT", "jwk": jwk}
h = b64url(json.dumps(header, separators=(",", ":")).encode())
p = b64url(json.dumps({"iss": "CoCo-Attestation-Service", "exp": 2**31}).encode())
der = key.sign((h + "." + p).encode(), ec.ECDSA(hashes.SHA256()))
r, s = asym_utils.decode_dss_signature(der)
token = h + "." + p + "." + b64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))

# KBS side (jsonwebtoken 10.4 DecodingKey::from_jwk + decode)
hh, pp, ss = token.split(".")
parsed = json.loads(base64.urlsafe_b64decode(hh + "=" * (-len(hh) % 4)))
jwkc = parsed["jwk"]
xb = base64.urlsafe_b64decode(jwkc["x"] + "=" * (-len(jwkc["x"]) % 4))
yb = base64.urlsafe_b64decode(jwkc["y"] + "=" * (-len(jwkc["y"]) % 4))
pub = ec.EllipticCurvePublicNumbers(
    int.from_bytes(xb, "big"), int.from_bytes(yb, "big"), ec.SECP256R1()
).public_key()
raw = base64.urlsafe_b64decode(ss + "=" * (-len(ss) % 4))
der2 = asym_utils.encode_dss_signature(
    int.from_bytes(raw[:32], "big"), int.from_bytes(raw[32:], "big")
)
try:
    pub.verify(der2, (hh + "." + pp).encode(), ec.ECDSA(hashes.SHA256()))
except InvalidSignature:
    sys.exit("round-trip FAILED: JWK does not match signing key")
print("round-trip OK")
EOF
}

command -v oc >/dev/null || { echo "oc is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 (cryptography) is required" >&2; exit 1; }

mkdir -p "$STAGE_DIR"

if [ "$FORCE" -eq 0 ] && [ -z "$KEYFILE" ]; then
    # idempotent: if the live secret's key round-trips, nothing to do
    if oc get secret "$SECRET" -n "$NS" >/dev/null 2>&1; then
        oc get secret "$SECRET" -n "$NS" -o jsonpath='{.data.tls\.key}' \
            | base64 -d > "$STAGE_DIR/current.key" 2>/dev/null || true
        if [ -s "$STAGE_DIR/current.key" ] && validate_key "$STAGE_DIR/current.key" >/dev/null 2>&1; then
            echo "attestation-cert already carries a round-trip-valid key; nothing to do"
            rm -f "$STAGE_DIR/current.key"
            exit 0
        fi
        echo ">> live attestation key FAILED round-trip validation; re-staging"
        rm -f "$STAGE_DIR/current.key"
    fi
fi

if [ -n "$KEYFILE" ]; then
    echo ">> Using provided key: $KEYFILE"
    cp "$KEYFILE" "$STAGE_DIR/attestation.key"
else
    echo ">> Generating pinned P-256 attestation key"
    openssl ecparam -name prime256v1 -genkey -noout -out "$STAGE_DIR/attestation.key" 2>/dev/null
fi
chmod 0600 "$STAGE_DIR/attestation.key"

echo ">> Validating key (AS sign -> KBS verify round-trip)"
validate_key "$STAGE_DIR/attestation.key"

echo ">> Generating self-signed certificate (CN=$CN, O=$ORG, ${DAYS}d)"
openssl req -new -x509 -key "$STAGE_DIR/attestation.key" -out "$STAGE_DIR/attestation.crt" \
    -days "$DAYS" -subj "/O=$ORG/CN=$CN" 2>/dev/null

echo ">> Applying secret $SECRET in $NS"
oc create secret tls "$SECRET" -n "$NS" \
    --cert="$STAGE_DIR/attestation.crt" --key="$STAGE_DIR/attestation.key" \
    --dry-run=client -o json | python3 -c "
import json, sys
d = json.load(sys.stdin)
d['stringData'] = d.pop('data')  # keep values as-is
json.dump(d, sys.stdout)
" | oc apply -f - >/dev/null

# ca.crt must mirror the self-signed leaf for chain verification
oc patch secret "$SECRET" -n "$NS" --type merge -p \
    "{\"stringData\":{\"ca.crt\":$(python3 -c "import json,sys; print(json.dumps(open('$STAGE_DIR/attestation.crt').read()))")}}" \
    >/dev/null

SHA256="$(sha256sum "$STAGE_DIR/attestation.key" | awk '{print $1}')"
echo ">> Pinned attestation key applied (sha256: ${SHA256:0:16}...)"

echo ">> Restarting $DEPLOY to load the pinned key"
oc rollout restart deploy/"$DEPLOY" -n "$NS"
oc rollout status deploy/"$DEPLOY" -n "$NS" --timeout=300s

echo ">> Done. Verify with:"
echo "   oc delete pod -n hello-openshift --all && oc delete pod -n kbs-access --all"
echo "   oc logs -n $NS deploy/$DEPLOY | grep -cE 'resource.*HTTP/1.1\" 200'"
