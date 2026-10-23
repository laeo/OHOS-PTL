#!/bin/bash
# gen_sb_keys.sh - generate the UEFI Secure Boot signing key used by
# make_partition_disk.sh (SECURE_BOOT=1).
#
# Chain this key participates in:
#
#   firmware db (Microsoft UEFI CA 2011)
#       -> shimx64.efi            (Microsoft-signed, from shim-signed package)
#       -> MOK                    (OUR certificate, enrolled once via MokManager)
#       -> grubx64.efi            (signed with OUR key)
#       -> bzImage                (signed with OUR key) + ramdisk
#
# So this one certificate is BOTH the MOK trust anchor and the artifact signer.
# It therefore must carry CA:TRUE (to be a trust anchor) as well as the
# codeSigning EKU (so sbsign can use it).  That combination is what
# sbsigncert / MokManager expect.
#
# IDEMPOTENT: existing files are never overwritten.  Only the derived files
# (.cer/.pub) are regenerated when missing, so re-running is safe.
#
# Usage:  bash gen_sb_keys.sh            # creates ./sb_keys/ next to this script
#         SB_KEYS_DIR=/path bash gen_sb_keys.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEYDIR="${SB_KEYS_DIR:-$SCRIPT_DIR/sb_keys}"
CN="${SB_CN:-OpenHarmony UEFI Secure Boot Signer}"
DAYS="${SB_DAYS:-3650}"
BASE=ohos-uefi

mkdir -p "$KEYDIR"
chmod 700 "$KEYDIR"

KEY="$KEYDIR/$BASE.key"
CRT="$KEYDIR/$BASE.crt"
CER="$KEYDIR/$BASE.cer"
PUB="$KEYDIR/$BASE.pub"

# ---------------------------------------------------------------- generate
if [ -f "$KEY" ] && [ -f "$CRT" ]; then
    echo "gen_sb_keys: reusing existing key pair in $KEYDIR"
else
    if [ -f "$KEY" ] || [ -f "$CRT" ]; then
        # half-present state: refuse rather than silently mixing a new key with
        # an old cert, which would produce unbootable (unverifiable) images.
        echo "ERROR: $KEYDIR is half-populated (key without cert or vice versa)." >&2
        echo "       Remove the stale file(s) and re-run." >&2
        exit 1
    fi
    echo "== generating RSA2048 UEFI Secure Boot key pair (CN=$CN, ${DAYS}d) =="
    openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days "$DAYS" \
        -keyout "$KEY" -out "$CRT" \
        -subj "/O=OpenHarmony/OU=pc_ptl/CN=$CN" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,digitalSignature,keyCertSign" \
        -addext "extendedKeyUsage=codeSigning" \
        > "$KEYDIR/gen_openssl.log" 2>&1 \
        || { echo "ERROR: openssl failed"; cat "$KEYDIR/gen_openssl.log"; exit 1; }
fi

# ---------------------------------------------------------------- derived files
[ -f "$CER" ] || openssl x509 -in "$CRT" -outform DER -out "$CER"
[ -f "$PUB" ] || openssl x509 -in "$CRT" -pubkey -noout > "$PUB"

# ---------------------------------------------------------------- permissions
chmod 600 "$KEY" "$CRT" "$CER" "$PUB"

# ---------------------------------------------------------------- report
echo "gen_sb_keys: OK"
echo "  dir        : $KEYDIR"
for f in "$KEY" "$CRT" "$CER" "$PUB"; do
    echo "  $(basename "$f"): $(stat -c'%a %s bytes' "$f")"
done
echo "  subject    : $(openssl x509 -in "$CRT" -noout -subject | sed 's/^subject= *//')"
echo "  DER sha256 : $(openssl x509 -inform DER -in "$CER" -noout -fingerprint -sha256 \
                          | sed 's/.*= *//; s/://g' | tr 'A-Z' 'a-z')"
echo "  MOK import : sudo mokutil --import $CER"