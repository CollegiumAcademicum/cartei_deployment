#!/usr/bin/env bash
set -euo pipefail
podman compose pull
systemctl start cartei.service
