#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-1.4.2}"
cd "$(dirname "$0")"
STAGE="release_v${VERSION}"
OUT="release_v${VERSION}.tar.gz"
export RELEASE_VERSION="$VERSION"

rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE/images" "$STAGE/models"

echo "[1/5] Building and pulling images"
docker compose build
docker pull postgres:15-alpine

echo "[2/5] Exporting images"
docker save -o "$STAGE/images/eoir-stack.tar" "eoir-stack:${VERSION}"
docker save -o "$STAGE/images/postgres.tar" postgres:15-alpine

echo "[3/5] Copying compose file, template, models and deploy script"
cp docker-compose.yml .env.example deploy_airgap.sh "$STAGE/"
cp models/eo_detector_fp16.engine models/manifest.json "$STAGE/models/"
echo "$VERSION" > "$STAGE/VERSION"

echo "[4/5] Generating SHA256SUMS"
( cd "$STAGE" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )

echo "[5/5] Creating bundle"
tar -czf "$OUT" "$STAGE"
sha256sum "$OUT" > "${OUT}.sha256"
echo "Done: $OUT"
