FROM oven/bun:1.1.38-alpine

WORKDIR /app

# Install git, docker CLI, openssh for git operations, and docker-compose
RUN apk add --no-cache git docker-cli openssh-client docker-cli-compose

# Copy webhook handler
COPY package.json bun.lockb* ./
COPY webhook-server.ts ./

# Install dependencies
RUN bun install --frozen-lockfile || bun install

# Create non-root user (but don't use it - need root for docker)
RUN addgroup -g 1001 -S webhook && \
    adduser -S webhook -u 1001 -G webhook

# Run as root to access docker socket
# USER webhook

# Configure git to trust the repository directories
# These will be customized during deployment
RUN git config --global --add safe.directory '*'

EXPOSE 9000

CMD ["bun", "run", "webhook-server.ts"]