#!/bin/zsh
# Sign with an existing certificate. Never silently fall back to ad-hoc signing.
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
APP_PATH="${1:?Usage: sign-app.sh APP_PATH [local|distribution]}"
SIGNING_MODE="${2:-local}"
SIGNING_IDENTITY="${AGENT_USAGE_SIGNING_IDENTITY:-}"
if [[ "$SIGNING_MODE" != local && "$SIGNING_MODE" != distribution ]]; then
    print -u2 'Signing mode must be local or distribution.'; exit 2
fi
if [[ -z "$SIGNING_IDENTITY" && "$SIGNING_MODE" == local && -f "$ROOT_DIR/.local-signing-identity" ]]; then
    SIGNING_IDENTITY="$(<"$ROOT_DIR/.local-signing-identity")"
fi
if [[ ! "$SIGNING_IDENTITY" =~ '^[[:xdigit:]]{40}$' ]]; then
    print -u2 'Set AGENT_USAGE_SIGNING_IDENTITY to the SHA-1 fingerprint of an existing signing identity. Local builds may use .local-signing-identity. Ad-hoc signing is disabled.'
    exit 2
fi
SIGNING_IDENTITY="${(U)SIGNING_IDENTITY}"
IDENTITY_RECORD="$(/usr/bin/security find-identity -v -p codesigning | /usr/bin/awk -v fingerprint="$SIGNING_IDENTITY" '$2 == fingerprint && !found++ { print }')"
if [[ -z "$IDENTITY_RECORD" && "$SIGNING_MODE" == local ]]; then
    # A self-signed local identity has no Apple trust anchor. Selecting this
    # explicitly pinned identity does not add a trust exception or change ACLs.
    LOCAL_RECORD="$(/usr/bin/security find-identity -p codesigning | /usr/bin/awk -v fingerprint="$SIGNING_IDENTITY" '$2 == fingerprint && !found++ { print }')"
    if [[ "$LOCAL_RECORD" == *'"Agent Usage Local" (CSSMERR_TP_NOT_TRUSTED)' ]]; then
        IDENTITY_RECORD="$LOCAL_RECORD"
    fi
fi
if [[ -z "$IDENTITY_RECORD" ]]; then
    print -u2 'The configured signing identity is unavailable or expired. No certificate or Keychain permission was changed.'; exit 2
fi
if [[ "$SIGNING_MODE" == distribution && "$IDENTITY_RECORD" != *'"Developer ID Application:'* ]]; then
    print -u2 'Distribution requires a Developer ID Application identity, not an Apple Development identity.'; exit 2
fi
TIMESTAMP_OPTION=--timestamp=none
if [[ "$SIGNING_MODE" == distribution ]]; then TIMESTAMP_OPTION=--timestamp; fi
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$TIMESTAMP_OPTION" --options runtime "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
REQUIREMENT="$(/usr/bin/codesign -d -r- "$APP_PATH" 2>&1)"
if [[ "$REQUIREMENT" == *'designated => cdhash '* ]]; then
    print -u2 'Refusing a build-specific hash identity; this script requires a certificate-backed designated requirement.'; exit 2
fi
print 'Certificate signing verified. Keychain approval remains under user control.'
