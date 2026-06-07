#!/usr/bin/env bash
# uninstall.sh — completely back Sleepless out: restore normal sleep, remove the app,
# the login item, AND the passwordless grant. Ends by PROVING the privilege is gone.
set -uo pipefail   # not -e: we want to attempt every cleanup step even if one is absent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Sleepless"
APP="/Applications/$APP_NAME.app"
BUNDLE_ID="com.aboudjem.Sleepless"
SUDOERS_DST="/etc/sudoers.d/sleepless-disablesleep"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
RESET_AGENT_SETUP="$SCRIPT_DIR/reset-agent-setup.sh"

echo "Sleepless uninstaller"
echo "============================"

# 1. Restore normal sleep BEFORE removing the grant (a reboot would also reset it to 0).
echo "==> Restoring normal sleep (disablesleep 0)"
sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null || sudo /usr/bin/pmset -a disablesleep 0 || true

# 2. Quit the app + remove the login item.
echo "==> Quitting app + removing login item"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -f "$LAUNCH_AGENT"

# 3. Remove the app.
echo "==> Removing $APP"
rm -rf "$APP"
rm -rf "/Applications/Sleepless.app"

# 4. Remove the passwordless grant (password required, by design — you're touching sudo).
echo "==> Removing passwordless grant (you may be asked for your password)"
sudo rm -f "$SUDOERS_DST"
sudo visudo -c >/dev/null && echo "    sudoers still parses cleanly"

# 5. Remove Sleepless' per-user agent detector hooks/state so reinstall starts from setup.
if [ -x "$RESET_AGENT_SETUP" ]; then
  "$RESET_AGENT_SETUP"
else
  echo "==> Resetting Sleepless agent detector setup"
  rm -rf "$HOME/.sleepless/agents"
  rmdir "$HOME/.sleepless" 2>/dev/null || true
  /usr/bin/defaults delete "$BUNDLE_ID" agentAutoOffEnabled 2>/dev/null || true
  echo "    reset helper state; hook JSON cleanup unavailable ($RESET_AGENT_SETUP missing)"
fi

# 6. Proof of revocation: the previously-passwordless command must now PROMPT.
echo "==> Verifying the grant is gone"
sudo -k
if sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null; then
  echo "    ⚠️  unexpected: pmset still ran without a password — check $SUDOERS_DST"
else
  echo "    ✅ revoked: 'sudo -n pmset …' now requires a password again."
fi

echo ""
echo "Done. Sleepless, its grant, login item, and agent detector setup are removed."
echo "UserDefaults (such as the battery-floor value) can be cleared with: defaults delete $BUNDLE_ID 2>/dev/null || true"
