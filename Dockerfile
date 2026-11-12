# Optional container image for the web UI. The systemd install (install.sh)
# is the main path; use this only if you prefer containers.
FROM golang:1.24 AS build
WORKDIR /src
COPY webui/go.mod webui/go.sum ./
RUN go mod download
COPY webui/ ./
ARG VERSION=dev
RUN CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /logs-webui .

FROM scratch
COPY --from=build /logs-webui /logs-webui
USER 65534:65534
ENV LOGS_DATA_DIR=/data LOGS_LISTEN=0.0.0.0:8484 GOMEMLIMIT=48MiB
EXPOSE 8484
ENTRYPOINT ["/logs-webui"]
