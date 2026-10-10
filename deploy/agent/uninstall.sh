#!/bin/sh
# Safe uninstall: stops the service and removes the binary, unit and local identity.
# The agent record stays in Skywatch (marked silent) until an administrator revokes it
# in Settings → Agents, so history is preserved.
set -eu
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
systemctl disable --now skywatch-agent 2>/dev/null || true
rm -f /etc/systemd/system/skywatch-agent.service /usr/local/bin/skywatch-agent
systemctl daemon-reload
rm -rf /etc/skywatch-agent
userdel skywatch-agent 2>/dev/null || true
echo "Skywatch agent removed. Revoke the agent in the Skywatch UI to stop expecting heartbeats."
