#!/usr/bin/env bash
set -euo pipefail

# DialTone production secret deployment helper.
#
# Prompts for required Cloudflare Worker secrets and uploads each one via
# `wrangler secret put`. Values are never written to disk. Run this once
# after initial setup or any time a secret needs to be rotated.
#
# Required secrets for production:
#   RESEND_API_KEY            — Resend API key for sending contact emails
#   SUPABASE_SERVICE_ROLE_KEY — Supabase service-role key for DB inserts (preferred)
#   SUPABASE_KEY              — Supabase anon/publishable key (fallback)
#
# Usage:
#   bash developer/ci/deploy-prod-secrets.sh
#   bash developer/ci/deploy-prod-secrets.sh --yes   # skip confirmation
#   RESEND_API_KEY=... SUPABASE_SERVICE_ROLE_KEY=... SUPABASE_KEY=... \
#     bash developer/ci/deploy-prod-secrets.sh --yes
#   bash developer/ci/deploy-prod-secrets.sh --yes \
#     --resend-api-key "..." --supabase-service-role-key "..." --supabase-key "..."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

SKIP_CONFIRM=false
COMPLETED=false
TERMINATED_BY_SIGNAL=false
HIDE_INPUT=false
RESEND_API_KEY_INPUT="${RESEND_API_KEY:-}"
SUPABASE_SERVICE_ROLE_KEY_INPUT="${SUPABASE_SERVICE_ROLE_KEY:-}"
SUPABASE_KEY_INPUT="${SUPABASE_KEY:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)
      SKIP_CONFIRM=true
      shift
      ;;
    --resend-api-key)
      RESEND_API_KEY_INPUT="${2:-}"
      shift 2
      ;;
    --supabase-service-role-key)
      SUPABASE_SERVICE_ROLE_KEY_INPUT="${2:-}"
      shift 2
      ;;
    --supabase-key)
      SUPABASE_KEY_INPUT="${2:-}"
      shift 2
      ;;
    --help|-h)
      echo "Usage:"
      echo "  bash developer/ci/deploy-prod-secrets.sh [--yes]"
      echo "  bash developer/ci/deploy-prod-secrets.sh --yes --resend-api-key <value> --supabase-service-role-key <value> --supabase-key <value>"
      echo "  bash developer/ci/deploy-prod-secrets.sh --hide-input"
      echo "  RESEND_API_KEY=<value> SUPABASE_SERVICE_ROLE_KEY=<value> SUPABASE_KEY=<value> bash developer/ci/deploy-prod-secrets.sh --yes"
      exit 0
      ;;
    --hide-input)
      HIDE_INPUT=true
      shift
      ;;
    *)
      echo "Error: unknown argument: $1"
      echo "Try: bash developer/ci/deploy-prod-secrets.sh --help"
      exit 1
      ;;
  esac
done

if command -v wrangler >/dev/null 2>&1; then
  WRANGLER_CMD=(wrangler)
elif npx --yes wrangler --version >/dev/null 2>&1; then
  WRANGLER_CMD=(npx --yes wrangler)
else
  echo "Error: wrangler is not available. Install it globally or use npx."
  exit 1
fi

print_banner() {
  echo
  echo "=============================================="
  echo "🔐 DialTone Production Secret Deployment"
  echo "=============================================="
  echo "Secrets are uploaded encrypted to Cloudflare."
  echo "Values are never stored on disk by this script."
  echo
  echo "Required secrets:"
  echo "  1) RESEND_API_KEY"
  echo "  2) SUPABASE_SERVICE_ROLE_KEY"
  echo "  3) SUPABASE_KEY"
  if [[ "$HIDE_INPUT" == "true" ]]; then
    echo
    echo "Input mode: hidden (characters will not be shown)."
  else
    echo
    echo "Input mode: visible (recommended for terminal reliability)."
  fi
  echo
}

print_exit_banner() {
  local status="$1"
  echo
  if [[ "$COMPLETED" == "true" && "$status" -eq 0 ]]; then
    echo "=============================================="
    echo "✅ Production secrets deployed successfully"
    echo "=============================================="
    echo "Verify with: npx wrangler secret list"
    echo "Then deploy: push to main or run pnpm deploy"
  elif [[ "$TERMINATED_BY_SIGNAL" == "true" ]]; then
    echo "=============================================="
    echo "⚠️  Process terminated without completion"
    echo "=============================================="
    echo "The script was interrupted before finishing."
    echo "Rerun when ready: bash developer/ci/deploy-prod-secrets.sh"
  elif [[ "$status" -eq 130 ]]; then
    echo "=============================================="
    echo "🛑 Secret deployment canceled"
    echo "=============================================="
    echo "Rerun when ready: bash developer/ci/deploy-prod-secrets.sh"
  else
    echo "=============================================="
    echo "❌ Secret deployment failed"
    echo "=============================================="
    echo "Check the error above and rerun the script."
  fi
  echo
}

on_exit() {
  local status=$?
  print_exit_banner "$status"
}

on_signal() {
  TERMINATED_BY_SIGNAL=true
  exit 130
}

trap on_exit EXIT
trap on_signal INT TERM HUP

print_banner

# Collect secrets into memory-only variables (no temp files, no history).
prompt_secret() {
  local var_name="$1"
  local label="$2"
  local preset_value="${3:-}"
  local value=""

  if [[ -n "$preset_value" ]]; then
    value="$preset_value"
  else
    if [[ "$HIDE_INPUT" == "true" ]]; then
      read -r -s -p "${label}: " value
      echo
      if [[ -z "$value" ]]; then
        # Visible fallback for terminals that drop hidden paste.
        read -r -p "${label} (visible fallback): " value
      fi
    else
      read -r -p "${label}: " value
    fi
  fi

  # Strip carriage returns and surrounding quotes from clipboard pastes.
  value="${value//$'\r'/}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"

  printf -v "$var_name" '%s' "$value"

  # Immediate operator feedback without exposing full secret values.
  echo "${label}: Value Entered ($(mask_value "$value"))"
}

mask_value() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s' '<empty>'
    return
  fi
  local len=${#value}
  if (( len <= 8 )); then
    printf '%s' '********'
    return
  fi
  printf '%s' "${value:0:4}...${value:len-4:4}"
}

prompt_secret RESEND_API_KEY             "RESEND_API_KEY"             "$RESEND_API_KEY_INPUT"
prompt_secret SUPABASE_SERVICE_ROLE_KEY  "SUPABASE_SERVICE_ROLE_KEY"  "$SUPABASE_SERVICE_ROLE_KEY_INPUT"
prompt_secret SUPABASE_KEY               "SUPABASE_KEY"               "$SUPABASE_KEY_INPUT"

# Validate nothing critical is blank.
if [[ -z "$RESEND_API_KEY" ]]; then
  echo "Error: RESEND_API_KEY cannot be empty."
  exit 1
fi

if [[ -z "$SUPABASE_SERVICE_ROLE_KEY" && -z "$SUPABASE_KEY" ]]; then
  echo "Error: at least one Supabase DB key is required (SUPABASE_SERVICE_ROLE_KEY or SUPABASE_KEY)."
  exit 1
fi

# Summary before applying.
echo
echo "🧾 Confirm Secrets"
echo "----------------------------------------------"
echo "RESEND_API_KEY:             $(mask_value "$RESEND_API_KEY")"
echo "SUPABASE_SERVICE_ROLE_KEY:  $(mask_value "${SUPABASE_SERVICE_ROLE_KEY:-}")"
echo "SUPABASE_KEY:               $(mask_value "${SUPABASE_KEY:-}")"
echo "----------------------------------------------"

if [[ "$SKIP_CONFIRM" != "true" ]]; then
  read -r -p "Upload these secrets to Cloudflare? (y/N): " confirm
  case "${confirm,,}" in
    y|yes) ;;
    *)
      echo "Canceled."
      exit 130
      ;;
  esac
fi

echo
echo "[1/3] Uploading RESEND_API_KEY"
printf '%s' "$RESEND_API_KEY" | "${WRANGLER_CMD[@]}" secret put RESEND_API_KEY

if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "[2/3] Uploading SUPABASE_SERVICE_ROLE_KEY"
  printf '%s' "$SUPABASE_SERVICE_ROLE_KEY" | "${WRANGLER_CMD[@]}" secret put SUPABASE_SERVICE_ROLE_KEY
else
  echo "[2/3] Skipping SUPABASE_SERVICE_ROLE_KEY (not provided)"
fi

if [[ -n "${SUPABASE_KEY:-}" ]]; then
  echo "[3/3] Uploading SUPABASE_KEY"
  printf '%s' "$SUPABASE_KEY" | "${WRANGLER_CMD[@]}" secret put SUPABASE_KEY
else
  echo "[3/3] Skipping SUPABASE_KEY (not provided)"
fi

echo
echo "Verifying uploaded secrets:"
"${WRANGLER_CMD[@]}" secret list

COMPLETED=true
