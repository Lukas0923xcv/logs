#!/usr/bin/env bash
# Build the release files into dist/:
#   logs-webui-linux-amd64, logs-webui-linux-arm64, logs-bundle.tar.gz, SHA256SUMS
#
#   scripts/build-release.sh v1.2.3
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-dev}
rm -rf dist
mkdir -p dist/bundle

for arch in amd64 arm64; do
    (cd webui && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath \
        -ldflags "-s -w -X main.version=$version" -o "../dist/logs-webui-linux-$arch" .)
done

printf '%s\n' "$version" > dist/bundle/VERSION
cp -R ansible systemd helpers config.example.env install.example.conf install.sh LICENSE README.md dist/bundle/
find dist/bundle -name '__pycache__' -prune -exec rm -rf {} +
# Site files must never end up in a release, even when they exist locally.
rm -f dist/bundle/ansible/inventory.yml dist/bundle/ansible/group_vars/all.yml
find dist/bundle/ansible -name host_vars -prune -exec rm -rf {} +
tar -C dist/bundle --sort=name --owner=0 --group=0 --numeric-owner --mtime='2020-01-01 00:00:00Z' \
    -czf dist/logs-bundle.tar.gz .
rm -rf dist/bundle

(cd dist && sha256sum logs-webui-linux-amd64 logs-webui-linux-arm64 logs-bundle.tar.gz > SHA256SUMS)
ls -l dist
