# Build stage -- compiles a static Go binary, nothing else ships from here.
# Pinned from golang:1.23-bookworm -- see fmt/docker/dockerfile.md.
FROM golang@sha256:167053a2bb901972bf2c1611f8f52c44d5fe7e762e5cab213708d82c421614db AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /admin .

# Final stage -- not scratch/distroless: this binary shells out to bash, the
# docker CLI + compose plugin, standard Unix tools (lscpu/free/nproc) for
# scripts/detect-hardware.sh, and python3 (scripts/benchmark.sh uses it for
# JSON parsing/averaging) -- so a real base OS is unavoidable regardless of
# the app itself being a single static binary.
# Pinned from debian:bookworm-slim -- see fmt/docker/dockerfile.md.
FROM debian@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash procps util-linux ca-certificates curl gnupg python3 \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
      docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /admin ./admin
COPY templates ./templates

EXPOSE 8080
ENTRYPOINT ["/app/admin"]
