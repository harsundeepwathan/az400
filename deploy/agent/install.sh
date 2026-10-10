#!/bin/sh
# Unattended Linux install for the Skywatch agent (Ubuntu, Debian, RHEL-compatible).
#   sudo SKYWATCH_SERVER=https://ingest.example.com SKYWATCH_ENROLLMENT_TOKEN=swe_... ./install.sh ./skywatch-agent
set -eu
BIN="${1:-./skywatch-agent}"
: "${SKYWATCH_SERVER:?set SKYWATCH_SERVER}"
: "${SKYWATCH_ENROLLMENT_TOKEN:?set SKYWATCH_ENROLLMENT_TOKEN}"
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

if ! id skywatch-agent >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin skywatch-agent
fi
install -m 0755 "$BIN" /usr/local/bin/skywatch-agent
install -d -m 0750 -o skywatch-agent -g skywatch-agent /etc/skywatch-agent
# Enroll as the service user so state.json (0600) is owned by it. The token is passed
# through the environment, not argv, so it does not appear in the process list.
su -s /bin/sh skywatch-agent -c "/usr/local/bin/skywatch-agent enroll --server '$SKYWATCH_SERVER'"
install -m 0644 "$(dirname "$0")/skywatch-agent.service" /etc/systemd/system/skywatch-agent.service
systemctl daemon-reload
systemctl enable --now skywatch-agent
echo "Skywatch agent installed and running."
