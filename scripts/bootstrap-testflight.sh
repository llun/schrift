#!/usr/bin/env bash
#
# One-time TestFlight bootstrap. Automates everything downstream of the App
# Store Connect API key:
#   1. creates the private `match` certificates repo (if missing)
#   2. generates a read-only SSH deploy key so CI can read that repo
#   3. registers the App ID + generates the signing certificate & profile
#   4. sets all GitHub Actions secrets on this repo
#
# NOTE: the App Store Connect *app record* is not created here — Apple has no
# API for it. Create it once in the web UI (Apps -> + -> New App) after this
# runs; the bundle id it needs will already be registered.
#
# You provide (from the Apple Developer site — see docs/testflight-setup.md):
#   ASC_KEY_ID          App Store Connect API key id
#   ASC_ISSUER_ID       App Store Connect API issuer id
#   ASC_KEY_P8          path to the downloaded AuthKey_XXXX.p8 file
#   DEVELOPER_TEAM_ID   10-char Developer Portal Team ID
#
# Optional overrides:
#   CERTS_REPO   name for the certificates repo (default: schrift-certificates)
#   MATCH_PASSWORD   passphrase to encrypt the certs (default: generated)
#
# Usage:
#   ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_KEY_P8=~/Downloads/AuthKey_XXXX.p8 \
#   DEVELOPER_TEAM_ID=... ./scripts/bootstrap-testflight.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# --- validate inputs -------------------------------------------------------
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_P8:?set ASC_KEY_P8 (path to the .p8 file)}"
: "${DEVELOPER_TEAM_ID:?set DEVELOPER_TEAM_ID}"
[ -f "$ASC_KEY_P8" ] || { echo "error: no such file: $ASC_KEY_P8" >&2; exit 1; }

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

GH_OWNER="$(gh api user --jq .login)"
CERTS_REPO="${CERTS_REPO:-schrift-certificates}"
TARGET_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
MATCH_GIT_URL="git@github.com:${GH_OWNER}/${CERTS_REPO}.git"

SECRETS_FILE="$HOME/.schrift-testflight-secrets.txt"
GENERATED_PW=""
if [ -z "${MATCH_PASSWORD:-}" ]; then
  MATCH_PASSWORD="$(openssl rand -base64 24)"
  GENERATED_PW="yes"
  # Persist the passphrase to a private local file immediately (never printed),
  # so it survives even if a later step fails. You save it, then delete the file.
  umask 077
  printf 'Schrift TestFlight — match passphrase\nSave to your password manager, then delete this file.\nMATCH_PASSWORD=%s\n' "$MATCH_PASSWORD" > "$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE"
fi

# temp workspace for the deploy keypair, cleaned up on exit
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> owner=$GH_OWNER  certs=$GH_OWNER/$CERTS_REPO  target=$TARGET_REPO"

# --- 1. certificates repo --------------------------------------------------
if gh repo view "$GH_OWNER/$CERTS_REPO" >/dev/null 2>&1; then
  echo "==> certs repo already exists, reusing"
else
  echo "==> creating private certs repo"
  gh repo create "$GH_OWNER/$CERTS_REPO" --private --description "Encrypted iOS signing assets (fastlane match)"
fi

# --- 2. read-only deploy key for CI ---------------------------------------
echo "==> generating CI deploy key"
ssh-keygen -t ed25519 -N "" -C "ci-match@schrift" -f "$TMP/match_ed25519" >/dev/null
# read-only (no --allow-write): CI only fetches certs, never pushes
gh repo deploy-key add "$TMP/match_ed25519.pub" \
  --repo "$GH_OWNER/$CERTS_REPO" --title "ci-match-readonly" >/dev/null || \
  echo "    (deploy key may already exist — continuing)"

# --- 3. register App ID + seed signing certs -------------------------------
echo "==> registering App ID + generating signing certificate (fastlane)"
ASC_KEY_CONTENT="$(base64 < "$ASC_KEY_P8")"
export ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_CONTENT ASC_KEY_P8 DEVELOPER_TEAM_ID
export MATCH_GIT_URL MATCH_PASSWORD
bundle exec fastlane bootstrap

# --- 4. GitHub Actions secrets --------------------------------------------
echo "==> setting GitHub Actions secrets on $TARGET_REPO"
# Pass values via stdin (not --body) so they never land in the process argv.
printf '%s' "$ASC_KEY_ID"        | gh secret set ASC_KEY_ID        --repo "$TARGET_REPO"
printf '%s' "$ASC_ISSUER_ID"     | gh secret set ASC_ISSUER_ID     --repo "$TARGET_REPO"
printf '%s' "$ASC_KEY_CONTENT"   | gh secret set ASC_KEY_CONTENT   --repo "$TARGET_REPO"
printf '%s' "$DEVELOPER_TEAM_ID" | gh secret set DEVELOPER_TEAM_ID --repo "$TARGET_REPO"
printf '%s' "$MATCH_GIT_URL"     | gh secret set MATCH_GIT_URL      --repo "$TARGET_REPO"
printf '%s' "$MATCH_PASSWORD"    | gh secret set MATCH_PASSWORD     --repo "$TARGET_REPO"
gh secret set MATCH_SSH_PRIVATE_KEY --repo "$TARGET_REPO" < "$TMP/match_ed25519"

echo
echo "==> Done. TestFlight pipeline is ready."
if [ -n "$GENERATED_PW" ]; then
  echo
  echo "    A match passphrase was generated and saved (mode 600) to:"
  echo "      $SECRETS_FILE"
  echo "    Store it in your password manager, then delete that file."
fi
echo
echo "    Ship a build with:  merge a PR to main (or Actions -> TestFlight -> Run workflow)"
