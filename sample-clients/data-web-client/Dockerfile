ARG DOCKER_HUB_MIRROR=europe-west4-docker.pkg.dev/horizon-sdv-lal/docker-hub
FROM ${DOCKER_HUB_MIRROR}/node:22-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM ${DOCKER_HUB_MIRROR}/node:22-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public
COPY --from=builder /app/src/proto ./src/proto
EXPOSE 3000
CMD ["node", "server.js"]
