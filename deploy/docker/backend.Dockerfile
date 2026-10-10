# Skywatch backend (all roles) and agent build. Context: repository root.
FROM golang:1.26-alpine AS build
WORKDIR /src/go
COPY go/go.mod go/go.sum ./
RUN go mod download
COPY go/ ./
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/skywatch ./cmd/skywatch \
 && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w -X github.com/harsundeepwathan/az400/go/internal/agent.Version=${VERSION}" -o /out/agents/skywatch-agent-linux-amd64 ./cmd/skywatch-agent \
 && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w -X github.com/harsundeepwathan/az400/go/internal/agent.Version=${VERSION}" -o /out/agents/skywatch-agent-windows-amd64.exe ./cmd/skywatch-agent

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/skywatch /usr/local/bin/skywatch
COPY --from=build /out/agents /opt/skywatch/agents
COPY db/migrations /opt/skywatch/migrations
ENV SKYWATCH_MIGRATIONS_DIR=/opt/skywatch/migrations
USER nonroot:nonroot
EXPOSE 8443 9090
ENTRYPOINT ["/usr/local/bin/skywatch"]
CMD ["serve"]
