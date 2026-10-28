#!/usr/bin/env bash
# Install Ansible collections, retrying on transient Galaxy errors
set -euo pipefail

for attempt in 1 2 3 4 5; do
  if ansible-galaxy collection install -r requirements.yml; then
    exit 0
  fi
  echo "Galaxy install failed (attempt ${attempt}/5), retrying in $((attempt * 15))s" >&2
  sleep $((attempt * 15))
done
exit 1
