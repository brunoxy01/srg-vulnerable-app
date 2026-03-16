# ──────────────────────────────────────────────────────────────────────────────
# SRG Vulnerable App — Dockerfile
#
# Uses node:18-alpine with the vulnerable packages from app/package.json.
# Dynatrace OneAgent (installed on the Docker host) will automatically
# discover this container and Application Security will scan the Node.js process.
# ──────────────────────────────────────────────────────────────────────────────

FROM node:18-alpine

# Dynatrace labels — used by OneAgent for service naming and auto-tagging
LABEL dt.service.name="srg-vulnerable-app" \
      dt.service.release="1.0.0" \
      com.dynatrace.monitoring="true"

# Install curl for the health-check probe
RUN apk add --no-cache curl

WORKDIR /app

# Copy package manifests first (layer-cache optimisation)
COPY app/package*.json ./

# Install deps — including the intentionally vulnerable packages
RUN npm install --legacy-peer-deps --omit=dev

# Copy application source
COPY app/ .

# Create a non-root user
RUN addgroup -g 1001 appuser && \
    adduser  -D -u 1001 -G appuser appuser && \
    chown -R appuser:appuser /app

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -sf http://localhost:3000/health || exit 1

CMD ["node", "server.js"]
