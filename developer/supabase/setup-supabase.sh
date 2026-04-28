#!/usr/bin/env bash
set -euo pipefail

# DialTone Supabase setup helper.
# This script configures local env files and Cloudflare Worker secrets.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
ENV_FILE=".env.supabase"

SKIP_CONFIRM=false
for arg in "$@"; do
  [[ "$arg" == "--yes" || "$arg" == "-y" ]] && SKIP_CONFIRM=true
done

print_intro_banner() {
  echo
  echo "=============================================="
  echo "🚀 DialTone Supabase Setup Assistant"
  echo "=============================================="
  echo "✨ Modes supported:"
  echo "   1) Interactive prompts (default)"
  echo "   2) Non-interactive via env vars"
  echo
  echo "📁 Project root: $ROOT_DIR"
  echo
}

print_exit_banner() {
  local status="$1"
  echo
  if [[ "$status" -eq 0 ]]; then
    echo "=============================================="
    echo "✅ Supabase setup finished successfully"
    echo "=============================================="
    echo "Next: run SQL schema and submit a form test."
  elif [[ "$status" -eq 130 ]]; then
    echo "=============================================="
    echo "🛑 Setup canceled by user"
    echo "=============================================="
    echo "No problem — rerun when ready: ./developer/supabase/setup-supabase.sh"
  else
    echo "=============================================="
    echo "❌ Supabase setup exited with errors"
    echo "=============================================="
    echo "Check the error above, fix it, and rerun the script."
  fi
  echo
}

on_exit() {
  local status=$?
  print_exit_banner "$status"
}

trap on_exit EXIT
print_intro_banner

prompt_value() {
  local var_name="$1"
  local prompt_label="$2"
  local default_value="${3:-}"
  local is_secret="${4:-false}"
  local input=""

  if [[ "$is_secret" == "true" ]]; then
    if [[ -n "$default_value" ]]; then
      read -r -s -p "$prompt_label [press Enter to keep existing]: " input
    else
      read -r -s -p "$prompt_label: " input
    fi
    echo

    # Some terminals can fail to paste hidden input reliably.
    # If nothing was captured and no default exists, retry visibly.
    if [[ -z "$input" && -z "$default_value" ]]; then
      read -r -p "$prompt_label (visible fallback): " input
    fi
  else
    if [[ -n "$default_value" ]]; then
      read -r -p "$prompt_label [$default_value]: " input
    else
      read -r -p "$prompt_label: " input
    fi
  fi

  if [[ -z "$input" ]]; then
    input="$default_value"
  fi

  # Strip carriage returns and surrounding quotes from clipboard pastes.
  input="${input//$'\r'/}"
  input="${input#\"}"; input="${input%\"}"
  input="${input#\'}"; input="${input%\'}"

  printf -v "$var_name" '%s' "$input"
  export "$var_name"
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
  else
    printf '%s' "${value:0:4}...${value:len-4:4}"
  fi
}

confirm_inputs() {
  local anon_masked
  local service_masked
  anon_masked="$(mask_value "$SUPABASE_ANON_KEY")"
  service_masked="$(mask_value "${SUPABASE_SERVICE_ROLE_KEY:-}")"

  echo
  echo "🧾 Confirm Setup Values"
  echo "----------------------------------------------"
  echo "SUPABASE_URL:               $SUPABASE_URL"
  echo "SUPABASE_PROJECT_REF:       $SUPABASE_PROJECT_REF"
  echo "SUPABASE_ANON_KEY:          $anon_masked"
  echo "SUPABASE_SERVICE_ROLE_KEY:  $service_masked"
  echo "----------------------------------------------"

  if [[ "$SKIP_CONFIRM" == "true" ]]; then
    echo "--yes flag set, proceeding automatically."
    return 0
  fi

  local confirm
  read -r -p "Proceed with these values? (y/N): " confirm
  case "${confirm,,}" in
    y|yes) return 0 ;;
    *)
      echo "Setup canceled before making changes."
      exit 130
      ;;
  esac
}

derive_project_ref_from_url() {
  local url="$1"
  if [[ "$url" =~ ^https?://([a-zA-Z0-9-]+)\.supabase\.co/?$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

if ! command -v supabase >/dev/null 2>&1; then
  echo "Error: supabase CLI is not installed or not in PATH."
  exit 1
fi

if command -v wrangler >/dev/null 2>&1; then
  WRANGLER_CMD=(wrangler)
elif npx --yes wrangler --version >/dev/null 2>&1; then
  WRANGLER_CMD=(npx --yes wrangler)
else
  echo "Error: wrangler is not available. Install it globally or in this repo (devDependency)."
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

echo "Enter Supabase values for this project (press Enter to keep existing values)."
prompt_value "SUPABASE_URL" "Supabase URL (https://<project-ref>.supabase.co)" "${SUPABASE_URL:-}"

if [[ -z "${SUPABASE_URL:-}" ]]; then
  echo "Error: Supabase URL is required."
  exit 1
fi

derived_ref="${SUPABASE_PROJECT_REF:-}"
if [[ -z "$derived_ref" ]] && derive_project_ref_from_url "$SUPABASE_URL" >/dev/null; then
  derived_ref="$(derive_project_ref_from_url "$SUPABASE_URL")"
fi

prompt_value "SUPABASE_PROJECT_REF" "Supabase project ref" "$derived_ref"
while [[ -z "${SUPABASE_PROJECT_REF:-}" ]]; do
  echo "❗ Supabase project ref is required."
  prompt_value "SUPABASE_PROJECT_REF" "Supabase project ref" ""
done

# Publishable/anon key is safe to input visibly and avoids hidden-paste terminal issues.
prompt_value "SUPABASE_ANON_KEY" "Supabase publishable/anon key (visible)" "${SUPABASE_ANON_KEY:-}"
while [[ -z "${SUPABASE_ANON_KEY:-}" ]]; do
  echo "❗ Supabase publishable/anon key is required."
  prompt_value "SUPABASE_ANON_KEY" "Supabase publishable/anon key (visible)" ""
done

if [[ "$SUPABASE_ANON_KEY" != sb_publishable_* && "$SUPABASE_ANON_KEY" != eyJ* ]]; then
  echo "⚠️  Key format looks unusual. Expected sb_publishable_... (or legacy eyJ... JWT)."
fi

prompt_value "SUPABASE_SERVICE_ROLE_KEY" "Supabase service role key (visible, recommended, optional)" "${SUPABASE_SERVICE_ROLE_KEY:-}"

confirm_inputs

echo "[1/5] Writing local .env.supabase"
cat > .env.supabase <<EOF
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
SUPABASE_PROJECT_REF=${SUPABASE_PROJECT_REF}
EOF

echo "[2/5] Linking supabase project"
supabase link --project-ref "$SUPABASE_PROJECT_REF"

echo "[3/5] Apply schema"
echo "Open Supabase SQL Editor and run: developer/supabase/01_waitlist_schema.sql"

echo "[4/5] Setting Cloudflare Worker secret SUPABASE_KEY"
printf '%s' "$SUPABASE_ANON_KEY" | "${WRANGLER_CMD[@]}" secret put SUPABASE_KEY

if [[ -n "${SUPABASE_SERVICE_ROLE_KEY:-}" ]]; then
  echo "[4b/5] Setting Cloudflare Worker secret SUPABASE_SERVICE_ROLE_KEY"
  printf '%s' "$SUPABASE_SERVICE_ROLE_KEY" | "${WRANGLER_CMD[@]}" secret put SUPABASE_SERVICE_ROLE_KEY
fi

echo "[5/5] Update wrangler.toml SUPABASE_URL if needed"
echo "Set SUPABASE_URL in wrangler.toml [vars] to: $SUPABASE_URL"

echo "Done. Next: run 'npx wrangler dev --port 8787' and submit the waitlist form."
