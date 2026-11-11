#!/bin/bash
set -euo pipefail

NATIVE_ACTION='interactive'
if [ "${1:-}" = '--native-action' ]; then
  NATIVE_ACTION="${2:-}"
  case "$NATIVE_ACTION" in check|install) ;; *) printf '{"ok":false,"status":"error","error":"Invalid updater action."}\n'; exit 1 ;; esac
fi

FILE_ID='1vgiXozpivvcIFLpWzRQKuW-iX5h2qd60'
DOWNLOAD_URL="https://drive.google.com/uc?export=download&id=${FILE_ID}"
VERSION_FILE_ID='1eJ-ML3gG4hKhgdOolwLt-sRQGy6lD1ls'
VERSION_URL="https://drive.google.com/uc?export=download&id=${VERSION_FILE_ID}"
INSTALL_ROOT="$HOME/Library/Application Support/CredentialVault"
TARGET="$INSTALL_ROOT/Extension"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/credential-vault.XXXXXX")"
BACKUP="$INSTALL_ROOT/Extension.previous"
LOCK_DIR="$INSTALL_ROOT/.updater-lock"
LOCK_ACQUIRED=0
cleanup() { rm -rf "$WORK"; [ "$LOCK_ACQUIRED" = 0 ] || rm -rf "$LOCK_DIR"; }
trap cleanup EXIT

native_result() { printf '%s\n' "$1"; }
fail() {
  if [ "$NATIVE_ACTION" != 'interactive' ]; then
    ERROR_TEXT="$(printf '%s' "$1" | tr '\r\n' '  ' | sed 's/\\/\\\\/g; s/"/\\"/g')"
    native_result "{\"ok\":false,\"status\":\"error\",\"error\":\"$ERROR_TEXT\"}"
    exit 1
  fi
  printf '\nInstall/update failed: %s\n' "$1" >&2
  read -r -p 'Press Return to close this window. ' _ || true
  exit 1
}
run_chrome_setup() {
  local mode="$1" helper result
  helper="$(dirname "$0")/chrome-setup.applescript"
  if [ ! -f "$helper" ]; then
    printf 'Chrome setup helper is missing; follow the manual steps above.\n' >&2
    return 1
  fi
  if ! result="$(osascript "$helper" "$TARGET" "$mode" 2>&1)"; then
    printf 'Chrome setup automation could not finish: %s\n' "$result" >&2
    printf 'Complete the setup manually in Chrome.\n' >&2
    return 1
  fi
  if [ "$result" != 'true' ]; then
    printf 'Chrome setup was not completed. Complete it manually in Chrome.\n' >&2
    return 1
  fi
  return 0
}
version() { plutil -extract version raw -o - "$1" 2>/dev/null; }
valid_manifest() {
  local manifest="$1" name mv version key permissions
  name="$(plutil -extract name raw -o - "$manifest" 2>/dev/null)" || return 1
  mv="$(plutil -extract manifest_version raw -o - "$manifest" 2>/dev/null)" || return 1
  version="$(plutil -extract version raw -o - "$manifest" 2>/dev/null)" || return 1
  key="$(plutil -extract key raw -o - "$manifest" 2>/dev/null)" || return 1
  permissions="$(plutil -extract permissions json -o - "$manifest" 2>/dev/null)" || return 1
  [ "$name" = 'Credential Vault' ] && [ "$mv" = '3' ] && [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] &&
    [ "$key" = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApTJDNECo9imX3YJA19hXHASim5ldP/tgRiLM4qHhM2Vg7X4gxzL33oWl24n9tcFegyyLajEa7oc2Pm+lTF6kIkQgx0ENifxhZGUDd2wdmp0BWir8J2Y/xAE5EdeHMABV0HT4rYOoAUdgqOjkSyPBP5GGbcKPskHHrOEmfLzdNxFjGoQQmcJgoQThaKbwMB4V4pLqFQJyN2l41YnRTzcy5GUPBzxxbHd9myrOb9MnOdnPK0nq60e4hHXssiMcwawpUEp5qvIDrIfhQwtmIhGULSQk4b+mmfXMod26y1sB65bnomDxr8UKoG8+1fL5p6OeX6LiD4rxK2ch5vFdDqx2cQIDAQAB' ] &&
    printf '%s' "$permissions" | grep -q '"nativeMessaging"'
}
valid_installed_manifest() {
  local manifest="$1" name mv version
  name="$(plutil -extract name raw -o - "$manifest" 2>/dev/null)" || return 1
  mv="$(plutil -extract manifest_version raw -o - "$manifest" 2>/dev/null)" || return 1
  version="$(plutil -extract version raw -o - "$manifest" 2>/dev/null)" || return 1
  [ "$name" = 'Credential Vault' ] && [ "$mv" = '3' ] && [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]
}
compare_versions() {
  awk -v a="$1" -v b="$2" 'BEGIN { split(a,A,"."); split(b,B,"."); for (i=1;i<=4;i++) { if ((A[i]+0)>(B[i]+0)) { print 1; exit } if ((A[i]+0)<(B[i]+0)) { print 0; exit } } print 0 }'
}

mkdir -p "$INSTALL_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  LOCK_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then fail 'Another Credential Vault update is already running. Try again shortly.'; fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || fail 'Another Credential Vault update is already running. Try again shortly.'
fi
LOCK_ACQUIRED=1
printf '%s\n' "$$" > "$LOCK_DIR/pid"

if [ "$NATIVE_ACTION" = 'interactive' ]; then printf 'Downloading Credential Vault...\n'; fi
curl -fLsS --retry 2 "$VERSION_URL" -o "$WORK/version.json" || fail 'Could not read CredentialVault-version.json from Drive. Check its link-sharing access.'
RELEASE_VERSION="$(plutil -extract version raw -o - "$WORK/version.json" 2>/dev/null)" || fail 'Drive version metadata is invalid; expected JSON with a numeric version such as 1.0.10.'
[[ "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || fail 'Drive version metadata contains an invalid version.'
LOCAL_VERSION=''
if [ -f "$TARGET/manifest.json" ]; then
  valid_installed_manifest "$TARGET/manifest.json" || fail 'Installed extension manifest is invalid.'
  LOCAL_VERSION="$(version "$TARGET/manifest.json")"
fi
if [ "$NATIVE_ACTION" = 'check' ]; then
  if [ -z "$LOCAL_VERSION" ]; then native_result "{\"ok\":true,\"status\":\"extension_missing\",\"currentVersion\":null,\"availableVersion\":\"$RELEASE_VERSION\"}"; exit 0; fi
  if [ "$(compare_versions "$RELEASE_VERSION" "$LOCAL_VERSION")" = 1 ]; then STATUS='update_available'; else STATUS='up_to_date'; fi
  native_result "{\"ok\":true,\"status\":\"$STATUS\",\"currentVersion\":\"$LOCAL_VERSION\",\"availableVersion\":\"$RELEASE_VERSION\"}"
  exit 0
fi
curl -fL --retry 2 "$DOWNLOAD_URL" -o "$WORK/credential-vault.zip" || fail 'Could not download the Drive ZIP. Check its link-sharing access.'
[ "$(stat -f%z "$WORK/credential-vault.zip")" -gt 1000 ] || fail 'Drive returned a very small file; check that the ZIP is shared for anyone with the link.'
ditto -x -k "$WORK/credential-vault.zip" "$WORK/unpacked" || fail 'Downloaded file is not a valid ZIP.'
SOURCE="$WORK/unpacked/dist"
if [ ! -f "$SOURCE/manifest.json" ]; then
  [ -f "$WORK/unpacked/manifest.json" ] && SOURCE="$WORK/unpacked" || fail 'ZIP layout not recognized: expected dist/manifest.json (or manifest.json at ZIP root).'
fi
valid_manifest "$SOURCE/manifest.json" || fail 'Downloaded manifest is invalid or is not the expected Credential Vault MV3 extension.'
REMOTE_VERSION="$(version "$SOURCE/manifest.json")"
 [ "$REMOTE_VERSION" = "$RELEASE_VERSION" ] || fail "Release mismatch: Drive metadata says $RELEASE_VERSION, but ZIP manifest says $REMOTE_VERSION. No files were changed."
if [ "$NATIVE_ACTION" = 'interactive' ]; then
  mkdir -p "$INSTALL_ROOT/NativeHost"
  cp "$(dirname "$0")/native-host/macos/host.pl" "$INSTALL_ROOT/NativeHost/host.pl" || fail 'Native Messaging host source is missing. Keep the native-host folder beside the installer.'
  HOST_LAUNCHER="$INSTALL_ROOT/NativeHost/CredentialVaultNativeHost"
  printf '#!/bin/bash\nexec /usr/bin/perl "%s/NativeHost/host.pl" "$@"\n' "$INSTALL_ROOT" > "$HOST_LAUNCHER"
  chmod 700 "$HOST_LAUNCHER" "$INSTALL_ROOT/NativeHost/host.pl"
  CHROME_HOSTS="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
  mkdir -p "$CHROME_HOSTS"
  HOST_JSON_PATH="$(printf '%s' "$HOST_LAUNCHER" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"name":"com.credentialvault.updater","description":"Credential Vault updater","path":"%s","type":"stdio","allowed_origins":["chrome-extension://micgojkeebpbmhlbepmiebomdokpbcdk/"]}\n' "$HOST_JSON_PATH" > "$CHROME_HOSTS/com.credentialvault.updater.json"
  cp "$0" "$INSTALL_ROOT/dependency.sh"
fi
if [ -d "$TARGET" ]; then
  [ -f "$TARGET/manifest.json" ] || fail "Installed folder has no manifest: $TARGET"
  valid_installed_manifest "$TARGET/manifest.json" || fail 'Installed extension manifest is invalid.'
  LOCAL_VERSION="$(version "$TARGET/manifest.json")"
  if [ "$NATIVE_ACTION" = 'install' ] && [ "$(compare_versions "$REMOTE_VERSION" "$LOCAL_VERSION")" != 1 ]; then
    native_result "{\"ok\":true,\"status\":\"up_to_date\",\"currentVersion\":\"$LOCAL_VERSION\",\"availableVersion\":\"$REMOTE_VERSION\"}"
    exit 0
  fi
  if [ "$NATIVE_ACTION" = 'interactive' ] && [ "$(compare_versions "$REMOTE_VERSION" "$LOCAL_VERSION")" != 1 ]; then
    printf 'Already current (installed %s, available %s).\n' "$LOCAL_VERSION" "$REMOTE_VERSION"
    printf '\nOpening Chrome setup for the installed folder:\n%s\n' "$TARGET"
    printf 'If automation cannot complete, manually enable Developer mode, click Load unpacked, and select this Extension folder.\n'
    run_chrome_setup load || true
    read -r -p 'Press Return to close this window. ' _ || true
    exit 0
  fi
elif [ "$NATIVE_ACTION" = 'check' ]; then
  native_result "{\"ok\":true,\"status\":\"extension_missing\",\"availableVersion\":\"$REMOTE_VERSION\"}"
  exit 0
elif [ "$NATIVE_ACTION" = 'install' ]; then
  fail 'The local extension folder is missing. Run the installer and load the extension in Chrome again.'
fi

mkdir -p "$INSTALL_ROOT"
rm -rf "$BACKUP"
if [ -d "$TARGET" ]; then mv "$TARGET" "$BACKUP"; fi
if ! ditto "$SOURCE" "$TARGET"; then
  rm -rf "$TARGET"
  [ ! -d "$BACKUP" ] || mv "$BACKUP" "$TARGET"
  fail 'Could not install the update; the previous version was restored.'
fi
if [ "$NATIVE_ACTION" != 'interactive' ]; then
  native_result "{\"ok\":true,\"status\":\"installed\",\"currentVersion\":\"$REMOTE_VERSION\",\"previousVersion\":\"$LOCAL_VERSION\"}"
  exit 0
fi
printf 'Installed Credential Vault %s to:\n%s\n' "$REMOTE_VERSION" "$TARGET"
if [ -z "$LOCAL_VERSION" ]; then
  printf '\nStarting one-time Chrome setup for:\n%s\n' "$TARGET"
  printf 'If automation stops, in the selected Chrome window enable Developer mode, click Load unpacked, and select the Extension folder containing manifest.json.\n'
else
  printf '\nUpdate installed. To activate it:\n'
  printf '1. Open Chrome and enter chrome://extensions in the address bar.\n'
  printf '2. Find Credential Vault in the extensions list.\n'
  printf '3. Click its Reload icon/button. If it is not visible, refresh the extensions page.\n'
  printf '4. Return to your tabs and refresh any page where you want to use the updated extension.\n'
fi
if [ -z "$LOCAL_VERSION" ]; then run_chrome_setup load || true
else run_chrome_setup update || true
fi
read -r -p 'Press Return to close this window. ' _ || true
