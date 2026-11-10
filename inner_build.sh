#!/bin/bash
# Runs INSIDE the official HAOS builder container (scripts/enter.sh), cwd /build.
# Builds only the rpi5_64 kernel for the checked-out HAOS tag, then compiles the
# Hailo-10H driver (hailo1x_pci) out-of-tree against that exact kernel tree.
set -euo pipefail
cd /build

make rpi5_64-config
make linux

KDIR=$(ls -d /build/output/build/linux-custom 2>/dev/null || ls -d /build/output/build/linux-[0-9a-f]* | grep -v headers | head -1)
CROSS=/build/output/host/bin/aarch64-buildroot-linux-gnu-
echo "KDIR=$KDIR"

make -C "$KDIR" ARCH=arm64 CROSS_COMPILE="$CROSS" M=/build/hailo-driver-src/linux/pcie modules

KO=/build/hailo-driver-src/linux/pcie/hailo1x_pci.ko
mkdir -p /build/out
cp "$KO" /build/out/
cp "$KDIR/Module.symvers" /build/out/
cat "$KDIR/include/config/kernel.release" > /build/out/kernel.release
strings "$KO" | grep '^vermagic=' > /build/out/vermagic.txt
sha256sum /build/out/hailo1x_pci.ko > /build/out/sha256.txt
echo "=== BUILD OK ==="
echo "kernel.release: $(cat /build/out/kernel.release)"
cat /build/out/vermagic.txt
