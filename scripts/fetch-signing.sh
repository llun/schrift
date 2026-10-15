#!/usr/bin/env bash
#
# Fetch signing material + App Store Connect credentials from the 1Password
# `Schrift` vault into <dir> and export them as environment variables.
#
#   CI:     bash scripts/fetch-signing.sh "$RUNNER_TEMP/signing"   (writes $GITHUB_ENV)
#   local:  eval "$(scripts/fetch-signing.sh "$(mktemp -d)")"      (prints exports)
#
# Needs the `op` CLI, signed in (locally) or OP_SERVICE_ACCOUNT_TOKEN (CI).
# Item names are fixed; see docs/testflight-setup.md. Values are never echoed.

set -euo pipefail
umask 077

dir="${1:?usage: fetch-signing.sh <dir>}"
vault="${OP_VAULT:-Schrift}"
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"

op document get "Schrift Distribution Certificate" --vault "$vault" --out-file "$dir/distribution.p12" --force >/dev/null
op document get "Schrift App Store Profile" --vault "$vault" --out-file "$dir/appstore.mobileprovision" --force >/dev/null
op read --force --out-file "$dir/AuthKey.p8" "op://$vault/Schrift App Store Connect API Key/AuthKey.p8" >/dev/null

key="Schrift App Store Connect API Key"
ASC_KEY_ID="$(op read "op://$vault/$key/key_id")"
ASC_ISSUER_ID="$(op read "op://$vault/$key/issuer_id")"
DEVELOPER_TEAM_ID="$(op read "op://$vault/$key/team_id")"
# The .p12 password may legitimately be empty, and `op read` fails on an empty field.
DIST_CERT_PASSWORD="$(op read "op://$vault/Schrift Distribution Certificate Password/password" 2>/dev/null || true)"

DIST_CERT_P12="$dir/distribution.p12"
PROVISIONING_PROFILE="$dir/appstore.mobileprovision"
ASC_KEY_P8="$dir/AuthKey.p8"

for name in DIST_CERT_P12 DIST_CERT_PASSWORD PROVISIONING_PROFILE ASC_KEY_P8 ASC_KEY_ID ASC_ISSUER_ID DEVELOPER_TEAM_ID; do
  value="${!name}"
  if [ -n "${GITHUB_ENV:-}" ]; then
    case "$name" in
      DIST_CERT_P12 | PROVISIONING_PROFILE | ASC_KEY_P8) ;;
      *) [ -z "$value" ] || echo "::add-mask::$value" ;;
    esac
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_ENV"
  else
    printf 'export %s=%q\n' "$name" "$value"
  fi
done
