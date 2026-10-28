#!/bin/zsh
# One explicitly authorized installation. No sudoers, setuid, firewall or VPN changes.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 022
[[ $# == 4 ]] || { print -u2 'Usage: install-bridge-service.sh --check|--install SOURCE SHA256 OWNER_UID'; exit 2; }
ACTION="$1"
SOURCE="$2"
EXPECTED="$3"
OWNER_UID="$4"
[[ "$ACTION" == --check || "$ACTION" == --install ]] || exit 2
[[ "$EXPECTED" =~ '^[a-f0-9]{64}$' && "$OWNER_UID" =~ '^[0-9]+$' && "$OWNER_UID" -gt 0 && -f "$SOURCE" ]] || exit 2
ACTUAL="$(/usr/bin/shasum -a 256 "$SOURCE")"
[[ "${ACTUAL%% *}" == "$EXPECTED" ]] || { print -u2 'Helper checksum mismatch.'; exit 1; }
/usr/bin/codesign --verify --strict "$SOURCE"
BASE=/Library/PrivilegedHelperTools/dev.radminvpn.mac.bridge
DEST="$BASE/versions/$EXPECTED/radmin-bridge"
PLIST=/Library/LaunchDaemons/dev.radminvpn.mac.bridge.plist
if [[ "$ACTION" == --install && "$EUID" != 0 ]]; then print -u2 'Administrator authorization is required for initial installation.'; exit 1; fi
# Fail closed if an unexpected symlink or writable directory occupies the path.
for DIR in /Library/PrivilegedHelperTools "$BASE" "$BASE/versions" "$BASE/versions/$EXPECTED" /Library/LaunchDaemons; do
    [[ ! -L "$DIR" ]] || { print -u2 'Unsafe installation directory.'; exit 1; }
    if [[ ! -e "$DIR" ]]; then
        if [[ "$ACTION" == --check ]]; then continue; fi
        /usr/bin/install -d -o root -g wheel -m 755 "$DIR"
    fi
    RADMIN_MODE="$(/usr/bin/stat -f %Lp "$DIR")"
    [[ -d "$DIR" && "$(/usr/bin/stat -f %u "$DIR")" == 0 ]] && (( (8#$RADMIN_MODE & 8#22) == 0 )) || { print -u2 'Installation directory must be root-owned and not writable by other users.'; exit 1; }
done
if [[ "$ACTION" == --check ]]; then
    print -r -- "Install root-owned helper: $DEST"
    print -r -- "Register service: $PLIST (allowed UID $OWNER_UID)"
    exit 0
fi
if [[ -e "$DEST" || -L "$DEST" ]]; then
    [[ -f "$DEST" && ! -L "$DEST" && "$(/usr/bin/stat -f %u "$DEST")" == 0 && "$(/usr/bin/stat -f %Lp "$DEST")" == 755 ]] || exit 1
else
    /usr/bin/install -o root -g wheel -m 755 "$SOURCE" "$DEST"
fi
ACTUAL="$(/usr/bin/shasum -a 256 "$DEST")"
[[ "${ACTUAL%% *}" == "$EXPECTED" ]] || { print -u2 'Installed helper checksum mismatch.'; exit 1; }
/usr/bin/codesign --verify --strict "$DEST"
[[ ! -L "$PLIST" ]] || exit 1
if [[ -e "$PLIST" ]]; then
    [[ -f "$PLIST" && "$(/usr/bin/stat -f %u "$PLIST")" == 0 ]] || exit 1
    RADMIN_OLD_OWNER="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:3' "$PLIST")"
    [[ "$RADMIN_OLD_OWNER" == "$OWNER_UID" ]] || { print -u2 'Adapter service belongs to another user. No replacement performed.'; exit 1; }
    /bin/cp -p "$PLIST" "$BASE/previous-$(/bin/date +%Y%m%d-%H%M%S)-$$.plist"
fi
# The generated plist contains only fixed paths, a verified hexadecimal digest,
# and the numeric UID. Never embed user-supplied XML or an executable command.
STAGED="$BASE/service-$(/bin/date +%Y%m%d-%H%M%S)-$$.plist"
cat > "$STAGED" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>dev.radminvpn.mac.bridge</string>
<key>ProgramArguments</key><array><string>$DEST</string><string>--daemon</string><string>--owner</string><string>$OWNER_UID</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>AssociatedBundleIdentifiers</key><array><string>dev.radminvpn.mac.native</string></array>
<key>ThrottleInterval</key><integer>5</integer>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict></plist>
EOF
/usr/bin/plutil -lint "$STAGED"
if /bin/launchctl print system/dev.radminvpn.mac.bridge >/dev/null 2>&1; then
    /bin/launchctl bootout system/dev.radminvpn.mac.bridge
fi
/usr/bin/install -o root -g wheel -m 644 "$STAGED" "$PLIST"
/bin/launchctl enable system/dev.radminvpn.mac.bridge
/bin/launchctl bootstrap system "$PLIST"
print 'Adapter service installed. Reconnect Radmin; repeated administrator prompts are no longer needed for the adapter.'
