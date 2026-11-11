# RUNBOOK - EO/IR stack v1.4.2 (flaws fixed, field rollback, CUDA/TensorRT drift)

Line numbers refer to the **original** repository. Before/after code and proof for every item: `FIX_LOG.md`. Root theme: *components claimed to be healthy without proving it.*

## 1. Flaws found and fixed

| # | File:line | Root cause | Fix |
|---|---|---|---|
| 1 | compose:22 | Healthcheck `echo worker_alive \|\| exit 0` can never fail, so `docker ps` said healthy while the engine was invalid | Python `urlopen('/status')`; worker returns HTTP 500 on bad checksum, so check fails; 3 s x 2 retries = unhealthy in <10 s |
| 2 | compose:34, app.py:6 | `WORKER_URL=http://localhost:9001`: localhost is the container itself, and the worker listens on 9000 | `http://inference_worker:9000` in both places |
| 3 | compose:43 | `vision_api` only on `edge_dmz`; worker and DB are on the internal `sensor_backplane` | `vision_api` joins both networks (the only bridge) |
| 4 | compose:39-41 | List-form `depends_on` orders start only, not readiness | `condition: service_healthy`; Postgres healthcheck added |
| 5 | app.py:9,34,39,48 | `STARTUP_SESSION_VALID` set once at boot; `flag and check_worker()` short-circuits, so one early failure meant 503 forever | Flag removed; worker checked live on every request (recovers with no restart) |
| 6 | compose:6,20,36 | DB password and AWS key hardcoded in VCS | `${POSTGRES_PASSWORD:?}` from uncommitted `.env`; `.env.example` template; unused AWS key deleted. **Old values remain in git history: treat as compromised, rotate** |
| 7 | compose:8-9 | Postgres published on host `5432` | Port removed; reachable only on `sensor_backplane` |
| 8 | Dockerfile:1,5 | Full `python:3.11` (~1 GB) plus build-essential, git, vim, curl | `python:3.11-slim`, nothing extra; 187 MB (limit 220) |
| 9 | Dockerfile:7 | `COPY . /app` shipped `.git`, tests, `.env`, models | Copy two code dirs only; `.dockerignore` (also excludes release bundles) |
| 10 | Dockerfile (no USER) | Runs as root | uid/gid 10001; `read_only`, `tmpfs /tmp`, `cap_drop: ALL`, `no-new-privileges` |
| 11 | Dockerfile:8; engine mode 770 | `chmod` on directories only; engine unreadable by a non-root user on Linux (invisible on Docker Desktop) | Models bind-mounted `:ro`; code `COPY --chmod=0755`; `deploy_airgap.sh` runs `chmod a+r models/*` |
| 12 | worker.py:9 | Cache dir defaulted inside `/app/models`, which breaks once non-root and read-only | Default `/tmp/trt_cache`; compose sets `TRT_CACHE_DIR` on a tmpfs |
| 13 | Dockerfile:10 | `EXPOSE 9000` on the API image | `EXPOSE 8000` |
| 14 | models/manifest.json | `sha256` 8f4b2c91a7e3... did not match the engine 0aaf46816a95... (hidden by flaw 15) | Manifest set to the engine as shipped. **The authoritative hash source is unconfirmed: verify against the model build pipeline before trusting this release.** Old hash kept here for audit |
| 15 | ci.yml:18 | `\|\| true` made failing tests pass | Removed |
| 16 | ci.yml:20-22 | Build job had no `needs:` | `needs: test` |
| 17 | ci.yml:26 | Mutable `:latest` | Tag `<manifest version>-<git sha>` |
| 18 | ci.yml:27-29 | "Promote" was an `echo`; no model check | Model sha256 gate, size/non-root gates, real push on `main` only, `permissions: contents: read` |
| 19 | repo | No `.gitignore`; CRLF risk for scripts and manifest | `.gitignore`; `.gitattributes` keeps the engine binary and scripts LF |

## 2. Field rollback: bad engine promoted, 15-minute window

**Before the window:** keep the previous release extracted (`release_v1.4.1/`) and its image loaded (`docker images eoir-stack` shows `1.4.1`). Versioned tags are never deleted, so rollback needs no registry. Run `sha256sum -c SHA256SUMS` in the old release dir.

| Time | Action |
|---|---|
| 0-2 | **Detect:** `docker compose ps` shows worker `unhealthy`; API returns 503. **Confirm:** `sha256sum models/eo_detector_fp16.engine` versus `grep sha256 models/manifest.json`; a mismatch means a bad or replaced engine. `docker compose logs --tail 20 inference_worker` shows any other error |
| 2-5 | **Decide:** if the cause is not obvious at minute 5, roll back. Do not debug inside the window |
| 5-9 | **Path A, engine only (fastest).** In the new release dir: `mkdir -p ../quarantine && cp models/* ../quarantine/` then `cp ../release_v1.4.1/models/eo_detector_fp16.engine ../release_v1.4.1/models/manifest.json models/`. The worker re-hashes on every probe, so it turns healthy in about 6 s with **no restart** |
| 5-9 | **Path B, whole release** (if the image or compose changed): `docker compose down`, then `cd ../release_v1.4.1 && RELEASE_VERSION=1.4.1 docker compose up -d --no-build --pull never` |
| 9-12 | **Verify:** `docker compose ps` worker healthy; `curl -fsS localhost:8000/health` returns `{"status": "healthy", "worker_ready": true}`; `curl -fsS localhost:8000/api/v1/detect` returns 200 |
| 12-15 | **Record:** failed engine stays in `quarantine/` (never deleted); note its sha256 and the incident time; report to the release owner |

No restart policy is set on purpose: an unhealthy worker stays visible instead of flapping.

## 3. CUDA / TensorRT drift: x86_64 lab GPU vs aarch64 Jetson Orin

A `.engine` is **not portable**: it is tied to the GPU architecture (compute capability), TensorRT version, CUDA/cuDNN version and, on Jetson, the JetPack/L4T release. The manifest's `target_arch: x86_64_and_aarch64_jetpack5` is therefore wrong: one engine cannot serve both.

1. **One engine per target.** `models/<arch>/` each with its own manifest (arch, GPU SM, TensorRT, CUDA, JetPack/L4T, source ONNX sha256). The ONNX is the portable source of truth.
2. **Build the engine on, or in a container matching, the exact target stack.** Pin base images **by digest**: an NVIDIA CUDA/TensorRT image for x86_64, an L4T/JetPack-matched image for Orin. Build per platform (`docker buildx --platform linux/amd64,linux/arm64`).
3. **Gate on load, not just on build.** Implemented: `deploy_airgap.sh` aborts if the image architecture differs from the host. Proposed (not implemented, the engine here is a placeholder): the worker compares manifest `arch` / TensorRT / CUDA against the runtime and refuses to load on mismatch.
4. **CI matrix** with real x86 GPU and Jetson runners; golden-input regression per architecture (same frames, detections within FP16 tolerance) before promotion.
5. **Pin and record** driver, CUDA, TensorRT and JetPack versions in `BUILD_INFO`; upgrade them only together with an engine rebuild.

## 4. Known limits (not verified)

- Developed and run on Docker Desktop (Windows); the CUDA/Jetson section is a design, not tested on hardware.
- `SHA256SUMS` proves integrity, **not authenticity**: someone who alters a bundle can regenerate it. Sign it (GPG/cosign) and deliver the signature over a separate channel.
- Postgres has no persistent volume; the worker re-hashes the whole engine per probe (cache by size+mtime for GB-scale engines).
