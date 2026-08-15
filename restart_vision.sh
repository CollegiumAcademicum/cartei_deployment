#!/usr/bin/env bash
set -euo pipefail
# Run vision once on the newest image, leaving the DB untouched. The quadlet's
# Pull=newer pulls a fresh image before the run; it's a oneshot, so "restart"
# is just starting it again.
systemctl start cartei-vision.service
