# Hailo-10H (Raspberry Pi AI HAT+ 2) driver for Home Assistant OS

Home Assistant OS ships only the Hailo-8 driver (`hailo_pci` 4.x). On a Raspberry Pi 5
with an AI HAT+ 2, that driver grabs the Hailo-10H, fails to load its firmware
(`hailo/hailo10h/customer_certificate.bin`, error -2) and no `/dev/hailo0` appears.
See [home-assistant/feature-requests#2980](https://github.com/orgs/home-assistant/discussions/2980).

This repo makes the Hailo-10H work on **stock HAOS**, without a custom OS image:

- **`.github/workflows/build-module.yml`** watches HAOS releases (stable and release
  candidates). For each new one it builds the `rpi5_64` kernel from that exact HAOS tag
  in HAOS's own builder container, compiles Hailo's `hailo1x_pci` driver
  ([hailo-ai/hailort-drivers](https://github.com/hailo-ai/hailort-drivers) `v5.1.1`,
  pinned by commit) against it, and publishes the module as release `haos-<version>`.
- **`addon/hailo10h_driver/`** is a local add-on that, at boot, downloads the module for
  the running HAOS release (sha256 and kernel string verified), loads the firmware and
  the driver, and creates `/dev/hailo0`. If a new HAOS release isn't built yet, it
  posts a notification in Home Assistant and retries until the module is published.

Status: working on a Raspberry Pi 5 with AI HAT+ 2 on HAOS 18.5 (kernel
`6.18.59-haos-raspi`): full firmware load, `/dev/hailo0` created.

## Why a module per HAOS release

The HAOS kernel has `CONFIG_MODVERSIONS=y`, so a module only loads on the exact kernel
it was built against. Every HAOS release changes the kernel, hence one build per release.
HAOS doesn't require signed modules, which is what makes this possible at all.

## Install (local add-on)

1. Copy `addon/hailo10h_driver/` to the HAOS local add-ons folder (`/addons` or
   `/local_apps`, depending on your SSH add-on).
2. Put the Hailo-10H **5.1.1** firmware into `addon/hailo10h_driver/firmware/`
   (see [firmware/README.md](addon/hailo10h_driver/firmware/README.md); it is not
   redistributable, so it is not in this repo).
3. In Home Assistant: Settings → Add-ons → Add-on store → ⋮ → Check for updates, then
   install **Hailo-10H Driver**, turn **Protection mode off**, and start it.
4. Optional: set `notify_service` (e.g. `mobile_app_my_phone`) to also get status on your phone.

## What the add-on is allowed to do, and why

It loads a kernel module, so it is necessarily privileged:

- `SYS_MODULE`: `insmod` / `rmmod`.
- `SYS_ADMIN` and AppArmor off: the supervisor mounts `/sys` read-only for every
  add-on; it remounts `/sys` to set the kernel's firmware search path
  (`firmware_class.path`) to the firmware it publishes under `/share`.
- It unloads the stock `hailo_pci` (Hailo-8 driver), which claims the Hailo-10H but
  can't drive it.

It refuses any module not built for the running kernel. Stopping the add-on leaves the
driver loaded; a reboot fully reverts.

## Manual build (fallback)

`tools/gcp_infra.sh up` creates a temporary build VM (no public IP, IAP SSH, Cloud NAT),
`tools/build_on_vm.sh <haos-tag>` builds the module there, `tools/gcp_infra.sh down`
removes everything.

## License

The workflow, add-on and scripts are GPL-2.0 (see `LICENSE`). The module is built from
Hailo's GPL-2.0 driver source; each release attaches the exact source it was built
from. Hailo firmware is not included. Unofficial project, not affiliated with Hailo,
Raspberry Pi, or the Open Home Foundation.
