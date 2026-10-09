# Farm to Market — one container serving the whole origin:
# the portal, the REST API, and the Africa's Talking USSD/Voice webhooks.
#
# Serverless was ruled out deliberately: USSD sessions live in SQLite on disk
# (Africa's Talking posts every keypress as a separate request, so session
# state must outlive the request), the sweep loops in apps/server/src/jobs
# are setInterval timers that must keep ticking, and photos plus cached TTS
# audio are written to disk and served back by URL.

FROM node:24-slim AS build
WORKDIR /app

# Manifests first: the dependency layer then caches across source edits.
COPY package.json package-lock.json ./
COPY packages/core/package.json packages/core/
COPY apps/server/package.json apps/server/
COPY apps/web/package.json apps/web/

# better-sqlite3 and sharp resolve prebuilt binaries for this platform, so the
# ~300 MB compiler toolchain is installed only as a fallback if a prebuild is
# ever missing (keeps the build small on disk-constrained builders).
RUN npm ci || ( apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && npm ci )

COPY . .

# The portal builds to apps/web/dist, then moves in beside the USSD and IVR
# tester pages so a single @fastify/static root serves the entire origin.
RUN npm run build -w @ftm/web \
 && cp -r apps/web/dist/. apps/server/public/


FROM node:24-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production

RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# @ftm/core exports raw TypeScript ("exports": "./src/index.ts"), so tsx is a
# RUNTIME dependency, not a build-time one. This image keeps devDependencies
# on purpose — pruning them would remove the thing that starts the server.
COPY --from=build /app /app

# Mount point for the Fly volume. DATABASE_PATH and STORAGE_DIR point in here
# (fly.toml) so the database, produce photos and TTS cache survive a redeploy.
RUN mkdir -p /data

EXPOSE 3000
CMD ["npm", "run", "start", "-w", "@ftm/server"]
