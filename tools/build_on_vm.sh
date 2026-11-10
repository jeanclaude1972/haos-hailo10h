#!/usr/bin/env bash
# Manual fallback to the GitHub Actions workflow: runs ON a Linux x86-64 build VM
# (e.g. from tools/gcp_infra.sh). Usage: build_on_vm.sh <haos-tag>
# Expects ~/inner_build.sh copied up. Output lands in ~/haos/out/.
set -euo pipefail
TAG="${1:?usage: build_on_vm.sh <haos-tag, e.g. 18.5>}"
DRIVER_TAG=v5.1.1
DRIVER_COMMIT=0f7b9cac89e6b559ce825e04b5b017c820a7b080
cd ~

if ! command -v docker >/dev/null; then
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker.io git
fi
sudo usermod -aG docker "$USER"

if [ ! -d haos ]; then
  git clone --depth 1 --branch "$TAG" --recurse-submodules --shallow-submodules \
    https://github.com/home-assistant/operating-system.git haos
fi
rm -rf driver haos/hailo-driver-src
git clone --depth 1 --branch "$DRIVER_TAG" https://github.com/hailo-ai/hailort-drivers.git driver
[ "$(git -C driver rev-parse HEAD)" = "$DRIVER_COMMIT" ] || { echo "driver tag moved"; exit 1; }
mkdir -p haos/hailo-driver-src
cp -r driver/common driver/linux haos/hailo-driver-src/
cp ~/inner_build.sh haos/inner_build.sh
chmod +x haos/inner_build.sh

cd haos
sg docker -c "scripts/enter.sh bash /build/inner_build.sh"
