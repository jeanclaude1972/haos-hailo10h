#!/usr/bin/env bash
# Temporary GCP build host for the Hailo-10H HAOS kernel module.
# Usage: ./gcp_infra.sh up | down | ssh
# Works inside the "nonprod" landing-zone project: no external IP (org policy),
# egress via Cloud NAT, SSH only through IAP (35.235.240.0/20), OS Login enforced.
set -euo pipefail

P="$(cat "$(dirname "$0")/../.gcp_project")"
REGION=me-central1
ZONE=me-central1-a
NET=hailo-build-vpc
SUBNET=hailo-build-subnet
VM=hailo-build
TAG=hailo-build
LABELS=purpose=hailo-build

g() { gcloud --project "$P" "$@"; }

up() {
  g services enable compute.googleapis.com iap.googleapis.com
  g compute networks describe "$NET" >/dev/null 2>&1 || \
    g compute networks create "$NET" --subnet-mode=custom
  g compute networks subnets describe "$SUBNET" --region "$REGION" >/dev/null 2>&1 || \
    g compute networks subnets create "$SUBNET" --network "$NET" --region "$REGION" \
      --range 10.99.0.0/24 --enable-private-ip-google-access
  g compute firewall-rules describe hailo-build-allow-iap-ssh >/dev/null 2>&1 || \
    g compute firewall-rules create hailo-build-allow-iap-ssh --network "$NET" \
      --direction INGRESS --allow tcp:22 --source-ranges 35.235.240.0/20 --target-tags "$TAG"
  g compute routers describe hailo-build-router --region "$REGION" >/dev/null 2>&1 || \
    g compute routers create hailo-build-router --network "$NET" --region "$REGION"
  g compute routers nats describe hailo-build-nat --router hailo-build-router --region "$REGION" >/dev/null 2>&1 || \
    g compute routers nats create hailo-build-nat --router hailo-build-router --region "$REGION" \
      --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges
  g compute instances describe "$VM" --zone "$ZONE" >/dev/null 2>&1 || \
    g compute instances create "$VM" --zone "$ZONE" \
      --machine-type e2-standard-16 --network-interface "subnet=$SUBNET,no-address" \
      --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
      --boot-disk-size 200GB --boot-disk-type pd-balanced \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
      --tags "$TAG" --labels "$LABELS"
}

down() {
  g compute instances delete "$VM" --zone "$ZONE" --quiet || true
  g compute routers nats delete hailo-build-nat --router hailo-build-router --region "$REGION" --quiet || true
  g compute routers delete hailo-build-router --region "$REGION" --quiet || true
  g compute firewall-rules delete hailo-build-allow-iap-ssh --quiet || true
  g compute networks subnets delete "$SUBNET" --region "$REGION" --quiet || true
  g compute networks delete "$NET" --quiet || true
}

ssh_() { g compute ssh "$VM" --zone "$ZONE" --tunnel-through-iap -- "$@"; }

case "${1:-}" in
  up) up ;;
  down) down ;;
  ssh) shift; ssh_ "$@" ;;
  *) echo "usage: $0 up|down|ssh [cmd]"; exit 1 ;;
esac
