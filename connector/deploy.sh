#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
# SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

set -eu
if [ "$#" -ne 2 ]; then
  echo 'Usage: sh connector/deploy.sh PROJECT_REF /absolute/path/to/private-secrets.env' >&2
  exit 2
fi
command -v supabase >/dev/null 2>&1 || { echo 'Install and sign in to the official Supabase CLI first.' >&2; exit 1; }
test -f "$2" || { echo 'The private secrets file does not exist.' >&2; exit 1; }
# Run from this repository root. Management credentials stay in the local CLI.
supabase link --project-ref "$1"
supabase db push
task_secret_file=$(mktemp "${TMPDIR:-/tmp}/tincall-secrets.XXXXXX")
chmod 600 "$task_secret_file"
trap 'rm -f "$task_secret_file"' EXIT HUP INT TERM
# Supabase injects its reserved SUPABASE_* values. APNs credentials belong only
# to the separate sender process and are never uploaded to the Edge function.
awk '/^[[:space:]]*(SUPABASE_|TINCALL_APNS_|TINCALL_STORAGE=|TINCALL_SQLITE_PATH=|PORT=)/ { next } { print }' "$2" > "$task_secret_file"
supabase secrets set --env-file "$task_secret_file"
supabase functions deploy tincall --use-api
echo 'Deployment commands completed. Configure the two documented Vault entries to enable Cron.'
