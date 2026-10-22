#!/usr/bin/env bash
# Creates, or brings up to date, the database Secrets for step 5:
#   data/pg-<svc>                login Secret read by CloudNativePG (basic-auth)
#   ticketdrop/<svc>-db          DATABASE_URL for the service
# Each password is made once in secrets/<svc>.password (gitignored) and reused,
# so a rerun changes nothing and a rebuilt cluster gets the same passwords.
# The commands are written out one by one in ticketdrop/docs/guide/phase-2-commands.md.
set -euo pipefail

cd "$(dirname "$0")/.."

SVCS="catalog orders inventory payments fulfillment scheduler"
HOST="pg-rw.data.svc.cluster.local:5432"

mkdir -p secrets
for svc in $SVCS; do
  pwfile="secrets/$svc.password"
  [ -f "$pwfile" ] || openssl rand -hex 24 | tr -d '\n' > "$pwfile"

  kubectl create secret generic "pg-$svc" -n data \
    --type=kubernetes.io/basic-auth \
    --from-literal=username="$svc" \
    --from-file=password="$pwfile" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label secret "pg-$svc" -n data cnpg.io/reload=true --overwrite

  # The URL is built into a file so the password never appears on a command line.
  urlfile="$(mktemp)"
  printf 'postgres://%s:%s@%s/%s?sslmode=require' "$svc" "$(cat "$pwfile")" "$HOST" "$svc" > "$urlfile"
  kubectl create secret generic "$svc-db" -n ticketdrop \
    --from-file=DATABASE_URL="$urlfile" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$urlfile"
done
