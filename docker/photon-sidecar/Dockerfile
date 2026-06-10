# Minimal Node sidecar for Photon (Spectrum) in LuminaVault.
# Uses the official spectrum-ts SDK.
# Keep this image small and focused — the sidecar only bridges Photon <-> Lumina API.

FROM node:20-alpine

WORKDIR /app

# Copy manifests first for better layer caching
COPY package.json package-lock.json* ./

# Install only production deps
RUN npm ci --omit=dev --no-audit --no-fund

# Copy the sidecar code
COPY . .

# Default command
CMD ["node", "index.mjs"]

# Healthcheck (the sidecar serves /healthz)
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8789/healthz || exit 1
