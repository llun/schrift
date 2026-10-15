#!/usr/bin/env bash
#
# One-time: store the 1Password service-account token as the repo's only
# TestFlight secret (OP_SERVICE_ACCOUNT_TOKEN). Signing material and ASC
# credentials live in the 1Password `Schrift` vault — see docs/testflight-setup.md.
#
# Provide the token via the environment, or a 1Password reference to it:
#   OP_SERVICE_ACCOUNT_TOKEN=...            ./scripts/bootstrap-testflight.sh
#   OP_TOKEN_REF='op://Private/Schrift CI/credential' ./scripts/bootstrap-testflight.sh

set -euo pipefail
umask 077

command -v gh >/dev/null || { echo "error: gh CLI not found" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: run 'gh auth login' first" >&2; exit 1; }

if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
  : "${OP_TOKEN_REF:?set OP_SERVICE_ACCOUNT_TOKEN or OP_TOKEN_REF}"
  OP_SERVICE_ACCOUNT_TOKEN="$(op read "$OP_TOKEN_REF")"
fi

TARGET_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
# Via stdin (not --body) so the token never lands in the process argv.
printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" | gh secret set OP_SERVICE_ACCOUNT_TOKEN --repo "$TARGET_REPO"
echo "==> OP_SERVICE_ACCOUNT_TOKEN set on $TARGET_REPO"
