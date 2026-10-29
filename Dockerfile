FROM node:26.12-alpine AS base

FROM base AS builder

WORKDIR /app

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts --prefer-offline --no-audit --no-fund

COPY tsconfig.json ./
COPY src ./src
COPY scripts ./scripts

# Formatting and test type checks run in CI via npm run build.
RUN npm run build:compile

# Install independently of Chromium/fonts so these steps can run in parallel.
FROM base AS production-deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --ignore-scripts --omit=dev --prefer-offline --no-audit --no-fund

# --- Release Stage ---
FROM base AS release

# Install necessary tools and base fonts
RUN apk add --no-cache \
    fontconfig \
    font-noto-cjk \
    ttf-freefont \
    curl \
    unzip \
    chromium \
    nss

# Noto CJK (including Japanese) is already provided by font-noto-cjk above.
# Keep IPAex fallback fonts; bound network waits and fail on HTTP errors.
RUN mkdir -p /usr/share/fonts/truetype/google && \
    curl --fail --location --show-error \
      --connect-timeout 10 --max-time 120 --retry 2 --retry-max-time 180 \
      "https://moji.or.jp/wp-content/ipafont/IPAexfont/IPAexfont00401.zip" -o ipaex.zip && \
    unzip ipaex.zip && \
    cp IPAexfont00401/*.ttf /usr/share/fonts/truetype/google/ && \
    rm -rf IPAexfont00401 ipaex.zip

# Update font cache
RUN fc-cache -f -v

# Set Puppeteer to use system Chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

# Set up a non-root user ('appuser'/'appgroup') to avoid running as root - good security practice!
# (-S is the Alpine option for a system user/group, suitable here)
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Copy the built code and necessary package files from our builder stage
WORKDIR /app

# Keep production dependencies cached when only application code changes.
COPY package.json package-lock.json ./
COPY --from=production-deps /app/node_modules ./node_modules

COPY --from=builder --chown=appuser:appgroup /app/dist /app/dist
COPY --chown=appuser:appgroup richmenu-template /app/richmenu-template

ENV NODE_ENV=production
ENV MCP_TRANSPORT=http HOST=0.0.0.0 PORT=8000

EXPOSE 8000

# Now, switch to running as our non-root user for the actual app process
USER appuser

# Define how to start the application
ENTRYPOINT ["node", "dist/index.js"]
