# Skywatch web UI (Next.js standalone). Context: repository root.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY apps/api/package.json apps/api/
COPY apps/web/package.json apps/web/
RUN npm ci --workspace apps/web --include-workspace-root=false
COPY apps/web apps/web
ARG SKYWATCH_API_ORIGIN=http://api:4000
ENV SKYWATCH_API_ORIGIN=${SKYWATCH_API_ORIGIN} NEXT_TELEMETRY_DISABLED=1
RUN npm run build --workspace apps/web

FROM node:22-alpine
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0 NEXT_TELEMETRY_DISABLED=1
WORKDIR /app
COPY --from=build /app/apps/web/.next/standalone ./
COPY --from=build /app/apps/web/.next/static ./apps/web/.next/static
USER node
EXPOSE 3000
CMD ["node", "apps/web/server.js"]
