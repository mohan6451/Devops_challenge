#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: ./deploy_airgap.sh release_v1.4.2.tar.gz [dest_dir]}"
DEST="${2:-./deployed}"

for tool in docker sha256sum tar; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found"; exit 1; }
done

echo "[1/6] Checking outer tarball checksum (if sidecar present)"
if [ -f "${BUNDLE}.sha256" ]; then
  ( cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256" )
else
  echo "WARN: no ${BUNDLE}.sha256 found, skipping outer check"
fi

echo "[2/6] Extracting"
mkdir -p "$DEST"
tar -xzf "$BUNDLE" -C "$DEST"
cd "$DEST"/release_v*/

echo "[3/6] Verifying SHA256SUMS BEFORE loading anything"
sha256sum -c SHA256SUMS --quiet || { echo "ERROR: checksum mismatch, aborting"; exit 1; }

listed=$(sed -E 's/^[0-9a-f]{64} [ *]//; s#^\./##' SHA256SUMS | sort)
actual=$(find . -type f ! -name SHA256SUMS | sed 's#^\./##' | sort)
[ "$listed" = "$actual" ] || { echo "ERROR: files in bundle differ from SHA256SUMS"; exit 1; }
echo "All files verified."

echo "[4/6] Loading images (offline)"
docker load -i images/eoir-stack.tar
docker load -i images/postgres.tar

echo "[5/6] Checking .env"
if [ ! -f .env ]; then
  cp .env.example .env
  echo "Created .env from template. Set POSTGRES_PASSWORD in .env, then re-run."
  exit 1
fi
if grep -q 'change_me' .env; then
  echo "ERROR: .env still has the placeholder password"; exit 1
fi

echo "[6/6] Starting stack (no build, no pull)"
export RELEASE_VERSION="$(cat VERSION)"
docker compose up -d --no-build --pull never

for i in $(seq 1 30); do
  if curl -fsS http://localhost:8000/health >/dev/null 2>&1; then
    echo "Stack healthy."; exit 0
  fi
  sleep 2
done
echo "ERROR: stack did not become healthy"; docker compose ps; exit 1