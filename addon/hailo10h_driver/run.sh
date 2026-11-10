#!/usr/bin/with-contenv bash
# (with-contenv: the base image's s6 init hands CMD a scrubbed environment; this restores
#  the container env, including SUPERVISOR_TOKEN for the Supervisor/Core API calls.)
# Hailo-10H (Raspberry Pi AI HAT+ 2) driver loader for Home Assistant OS.
#
# HAOS has no Hailo-10H driver, and a kernel module only loads on the exact kernel it
# was built for, so every HAOS release needs its own build of hailo1x_pci. This add-on:
#   1. works out the running HAOS version and kernel;
#   2. picks a module: cached download for this HAOS version -> fresh download from the
#      GitHub release "haos-<version>" (sha256 + kernel string verified) -> bundled module;
#   3. points the kernel's firmware search path at the firmware it publishes to /share,
#      swaps out the stock hailo_pci (Hailo-8 driver that grabs the device and fails),
#      and loads hailo1x_pci, which creates /dev/hailo0;
#   4. if no module fits yet (new HAOS release not built), tells you in Home Assistant
#      and retries until one is published.
# Stopping the add-on leaves the driver loaded; a reboot fully reverts.

set -uo pipefail

OPTS=/data/options.json
REPO=$(jq -r '.repo // "jeanclaude1972/haos-hailo10h"' "$OPTS" 2>/dev/null || echo jeanclaude1972/haos-hailo10h)
RETRY_MIN=$(jq -r '.retry_minutes // 30' "$OPTS" 2>/dev/null || echo 30)
NOTIFY_SERVICE=$(jq -r '.notify_service // ""' "$OPTS" 2>/dev/null || echo "")
NOTIFY_SERVICE=${NOTIFY_SERVICE#notify.}

CACHE=/data/modules
BUNDLED=/opt/hailo/bundled
SUP=http://supervisor
AUTH="Authorization: Bearer ${SUPERVISOR_TOKEN:-}"

log() { echo "[hailo10h] $*"; }

# Status goes to one rolling persistent notification (and optionally a notify service).
# Core may not be up yet at system startup, so retry in the background.
notify() {
  local title="$1" msg="$2"
  (
    for _ in $(seq 1 40); do
      if curl -sf -m 10 -X POST -H "$AUTH" -H "Content-Type: application/json" \
          -d "$(jq -nc --arg t "$title" --arg m "$msg" '{title:$t, message:$m, notification_id:"hailo10h_driver"}')" \
          "$SUP/core/api/services/persistent_notification/create" >/dev/null; then
        if [ -n "$NOTIFY_SERVICE" ]; then
          curl -sf -m 10 -X POST -H "$AUTH" -H "Content-Type: application/json" \
            -d "$(jq -nc --arg t "$title" --arg m "$msg" '{title:$t, message:$m}')" \
            "$SUP/core/api/services/notify/$NOTIFY_SERVICE" >/dev/null || true
        fi
        exit 0
      fi
      sleep 30
    done
  ) &
}

haos_version() {
  local v
  v=$(curl -sf -m 10 -H "$AUTH" "$SUP/os/info" | jq -r '.data.version // empty')
  [ -n "$v" ] || v=$(curl -sf -m 10 -H "$AUTH" "$SUP/info" | jq -r '.data.operating_system // empty' | awk '{print $NF}')
  echo "$v"
}

loaded() { grep -q '^hailo1x_pci ' /proc/modules && [ -e /dev/hailo0 ]; }

# Download haos-<ver>/{manifest.json,hailo1x_pci.ko} into the cache, verifying the
# checksum and that the module was built for the running kernel.
fetch() {
  local ver="$1" kr="$2" dir="$CACHE/haos-$1" tmp="$CACHE/.haos-$1.tmp"
  local base="https://github.com/$REPO/releases/download/haos-$ver"
  rm -rf "$tmp"; mkdir -p "$tmp"
  curl -sfL -m 120 -o "$tmp/manifest.json" "$base/manifest.json" || { rm -rf "$tmp"; return 1; }
  curl -sfL -m 300 -o "$tmp/hailo1x_pci.ko" "$base/hailo1x_pci.ko" || { rm -rf "$tmp"; return 1; }
  local want_sha want_kr got_sha
  want_sha=$(jq -r .sha256 "$tmp/manifest.json"); want_kr=$(jq -r .kernel_release "$tmp/manifest.json")
  got_sha=$(sha256sum "$tmp/hailo1x_pci.ko" | cut -d' ' -f1)
  if [ "$want_sha" != "$got_sha" ]; then log "haos-$ver: checksum mismatch, ignoring"; rm -rf "$tmp"; return 1; fi
  if [ "$want_kr" != "$kr" ]; then log "haos-$ver: built for kernel $want_kr, running $kr"; rm -rf "$tmp"; return 1; fi
  touch "$tmp/.fresh"   # marks "downloaded, not yet loaded" -> worth telling the user once
  rm -rf "$dir"; mv "$tmp" "$dir"
  log "downloaded module for HAOS $ver (sha256 ${got_sha:0:12})"
}

# Module candidates for this HAOS version + kernel, best first.
candidates() {
  local ver="$1" kr="$2"
  [ -n "$ver" ] && [ ! -f "$CACHE/haos-$ver/hailo1x_pci.ko" ] && fetch "$ver" "$kr" >&2
  [ -n "$ver" ] && [ -f "$CACHE/haos-$ver/hailo1x_pci.ko" ] && echo "$CACHE/haos-$ver/hailo1x_pci.ko"
  [ -f "$BUNDLED/hailo1x_pci.ko" ] && [ "$(cat "$BUNDLED/kernel.release" 2>/dev/null)" = "$kr" ] && echo "$BUNDLED/hailo1x_pci.ko"
}

# Firmware search path must be the HOST path of /share (the kernel resolves it in the
# host mount namespace). The supervisor mounts /sys read-only, so remount it first.
prepare_firmware() {
  [ -f /opt/hailo/firmware/hailo/hailo10h/customer_certificate.bin ] || {
    log "firmware missing from the add-on image (see firmware/README.md)"; return 1; }
  mkdir -p /share/hailo-firmware
  diff -rq /opt/hailo/firmware /share/hailo-firmware >/dev/null 2>&1 || cp -a /opt/hailo/firmware/. /share/hailo-firmware/
  local root host
  root=$(awk '$5=="/share"{print $4}' /proc/self/mountinfo | head -1)
  host="/mnt/data${root:-/supervisor/share}/hailo-firmware"
  touch /sys/module/firmware_class/parameters/path 2>/dev/null || mount -o remount,rw /sys || return 1
  echo -n "$host" > /sys/module/firmware_class/parameters/path
  log "firmware search path: $host"
}

load() {
  local ko="$1" err
  grep -q '^hailo_pci ' /proc/modules && rmmod hailo_pci && log "unloaded stock hailo_pci"
  if ! err=$(insmod "$ko" 2>&1); then
    log "insmod $ko failed: $err"; LAST_ERR="$err"; return 1
  fi
  for _ in $(seq 1 30); do [ -e /dev/hailo0 ] && return 0; sleep 1; done
  LAST_ERR="module loaded but /dev/hailo0 did not appear"; log "$LAST_ERR"
  rmmod hailo1x_pci 2>/dev/null   # so the next candidate can load
  return 1
}

STATE=""        # last state we notified about: waiting | failed | online
LAST_ERR=""
log "starting: HAOS $(haos_version), kernel $(uname -r), modules from github.com/$REPO"
if [ ! -f /data/.autoupdate_announced ]; then
  notify "AI HAT+2 driver: auto-update enabled" "The Hailo-10H Driver add-on now fetches the module built for each HAOS release, so OS updates need no manual rebuild. You'll be told here if the HAT is ever waiting for a new build."
  touch /data/.autoupdate_announced
fi
while true; do
  KR=$(uname -r); VER=$(haos_version)

  if loaded; then
    if [ "$STATE" = waiting ] || [ "$STATE" = failed ]; then
      notify "AI HAT+2 online" "Hailo-10H driver loaded for HAOS $VER (kernel $KR). /dev/hailo0 is up."
    fi
    STATE=online
    # Keep the module for this release cached, so a later reboot needs no download.
    # (Not "fresh": it isn't the one running, so loading it later is routine.)
    if [ -n "$VER" ] && [ ! -f "$CACHE/haos-$VER/hailo1x_pci.ko" ] && fetch "$VER" "$KR"; then
      rm -f "$CACHE/haos-$VER/.fresh"
    fi
    sleep 3600; continue
  fi

  log "HAOS $VER, kernel $KR: looking for a matching hailo1x_pci"
  OK=""
  if prepare_firmware; then
    for ko in $(candidates "$VER" "$KR"); do
      log "trying $ko"
      if load "$ko"; then OK="$ko"; break; fi
      [[ "$ko" == "$CACHE"/* ]] && rm -rf "$(dirname "$ko")"   # bad cached module: refetch next time
    done
  else
    LAST_ERR="could not set the firmware search path"
  fi

  if [ -n "$OK" ]; then
    log "OK: /dev/hailo0 is up ($OK)"
    dmesg | grep -iE 'hailo1x' | tail -4
    FRESH="$(dirname "$OK")/.fresh"
    if [ "$STATE" = waiting ] || [ "$STATE" = failed ] || [ -f "$FRESH" ]; then
      notify "AI HAT+2 online" "Hailo-10H driver loaded for HAOS $VER (kernel $KR). /dev/hailo0 is up."
    fi
    rm -f "$FRESH"
    STATE=online
    continue
  fi

  if [ -z "$LAST_ERR" ]; then
    log "no module published yet for HAOS $VER (kernel $KR); retrying in $RETRY_MIN min"
    if [ "$STATE" != waiting ]; then
      notify "AI HAT+2 waiting for driver" "HAOS $VER (kernel $KR) is new. The Hailo-10H module for it is being built at github.com/$REPO and will load automatically when published (checking every $RETRY_MIN min)."
    fi
    STATE=waiting
  else
    log "load failed: $LAST_ERR; retrying in $RETRY_MIN min"
    if [ "$STATE" != failed ]; then
      notify "AI HAT+2 driver failed" "Could not load the Hailo-10H driver on HAOS $VER (kernel $KR): $LAST_ERR. Retrying every $RETRY_MIN min."
    fi
    STATE=failed
  fi
  LAST_ERR=""
  sleep $((RETRY_MIN * 60))
done
