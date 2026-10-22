#!/bin/sh
# First-time backup setup. Management authorization stays in the official CLI.
set -eu
umask 077
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo 'Usage: sh connector/setup-cloud.sh PROJECT_REF AUTH_USER_UUID [PRIVATE_DIRECTORY]' >&2
  exit 2
fi
task_ref=$1
task_owner=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
case "$task_ref" in ''|*[!a-z0-9]*) echo 'Invalid project reference.' >&2; exit 2;; esac
test "${#task_ref}" -eq 20 || { echo 'Project reference must contain 20 characters.' >&2; exit 2; }
printf '%s\n' "$task_owner" | LC_ALL=C awk '/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/ { valid=1 } END { exit !valid }' || {
  echo 'Use the UUID from Authentication > Users.' >&2; exit 2;
}
command -v supabase >/dev/null 2>&1 || { echo 'Install the official Supabase CLI and run supabase login first.' >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo 'OpenSSL is required to generate random access tokens.' >&2; exit 1; }
task_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$task_root"
task_directory=${3:-"$HOME/.config/tincall/cloud/$task_ref"}
case "$task_directory" in /*) ;; *) echo 'Use an absolute private directory outside the source checkout.' >&2; exit 2;; esac
test ! -L "$task_directory" || { echo 'The private directory must not be a symbolic link.' >&2; exit 2; }
mkdir -p "$(dirname -- "$task_directory")"
task_parent=$(CDPATH= cd -- "$(dirname -- "$task_directory")" && pwd -P)
task_directory="$task_parent/$(basename -- "$task_directory")"
case "$task_directory/" in "$task_root/"*) echo 'Keep deployment credentials outside the source checkout.' >&2; exit 2;; esac

task_staging=''
trap 'if [ -n "$task_staging" ]; then rm -rf "$task_staging"; fi' EXIT HUP INT TERM
if [ -e "$task_directory" ]; then
  test -f "$task_directory/owner.txt" && test -f "$task_directory/secrets.env" && test -f "$task_directory/tincall-cloud.json" || {
    echo 'The destination is not a complete setup. Keep its files and choose another private directory.' >&2; exit 1;
  }
  test "$(cat "$task_directory/owner.txt")" = "$task_ref:$task_owner" || {
    echo 'This directory belongs to a different project or user. Nothing was changed.' >&2; exit 1;
  }
  echo 'Reusing the saved configuration. Existing phone tokens will be preserved.'
else
  # Inspect secret names only. Do not inspect or compare secret digests.
  task_remote_secrets=$(supabase secrets list --project-ref "$task_ref" --output json)
  if printf '%s\n' "$task_remote_secrets" | awk '/"name"[[:space:]]*:[[:space:]]*"TINCALL_/ { found=1 } END { exit !found }'; then
    echo 'This project already has Tincall configuration. Use the original private secrets file with connector/deploy.sh; no credentials were replaced.' >&2
    exit 1
  fi
  unset task_remote_secrets
  printf 'Install Tincall backup tables, private storage and service in project %s? [y/N] ' "$task_ref"
  read -r task_confirm
  case "$task_confirm" in y|Y|yes|YES) ;; *) echo 'Cancelled. No deployment was performed.'; exit 1;; esac
  task_staging=$(mktemp -d "$task_parent/.tincall-setup.XXXXXX")
  task_phone_token=$(openssl rand -hex 32)
  task_worker_token=$(openssl rand -hex 32)
  printf '%s:%s\n' "$task_ref" "$task_owner" > "$task_staging/owner.txt"
  cat > "$task_staging/secrets.env" <<EOF
TINCALL_CLIENTS=[{"token":"$task_phone_token","owner_id":"$task_owner"}]
TINCALL_WORKER_TOKEN=$task_worker_token
TINCALL_BINDINGS=[]
TINCALL_ALLOWED_ORIGINS=[]
EOF
  cat > "$task_staging/tincall-cloud.json" <<EOF
{"type":"tincall-cloud-connection","version":1,"endpoint":"https://$task_ref.supabase.co/functions/v1/tincall","token":"$task_phone_token"}
EOF
  unset task_phone_token task_worker_token
  mv "$task_staging" "$task_directory"
  task_staging=''
fi
sh connector/deploy.sh "$task_ref" "$task_directory/secrets.env"
printf '\nDeployment commands completed. Import this private connection file in Tincall > 云端同步 > 开始配置:\n%s/tincall-cloud.json\n' "$task_directory"
echo 'Then save and check the connection in the app. No call records have been uploaded.'
echo 'Keep this private directory for retries and updates. Do not share the connection file with others.'
