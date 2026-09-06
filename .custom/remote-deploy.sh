#!/usr/bin/env bash
# GitHub runner transport. The server job survives an interrupted SSH session.
set -euo pipefail
umask 077
target=${TARGET_VERSION:?}
web_digest=${EXPECTED_WEB_DIGEST:?}
stream_digest=${EXPECTED_STREAMING_DIGEST:?}
[[ "$target" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ "$web_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
[[ "$stream_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
[[ "${SERVER_USER:?}" =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 2
[[ "${SERVER_HOST:?}" =~ ^[a-zA-Z0-9.-]+$ ]] || exit 2
port=${SERVER_PORT:-22}
[[ "$port" =~ ^[0-9]+$ ]] || exit 2
run_id="${GITHUB_RUN_ID:?}-${GITHUB_RUN_ATTEMPT:?}"
[[ "$run_id" =~ ^[0-9]+-[0-9]+$ ]] || exit 2
run_dir="/opt/mastodon/automation/$run_id"
ssh_dir=$(mktemp -d)
trap 'rm -r "$ssh_dir"' EXIT
printf '%s\n' "${SERVER_SSH_KEY:?}" > "$ssh_dir/key"
read -r host_key_type host_key < .custom/server-host-key.pub
test "$host_key_type" = ssh-ed25519
printf 'mastodon-production %s %s\n' "$host_key_type" "$host_key" > "$ssh_dir/known_hosts"
opts=(-i "$ssh_dir/key" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519 -o HostKeyAlias=mastodon-production -o "UserKnownHostsFile=$ssh_dir/known_hosts" -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
destination="$SERVER_USER@$SERVER_HOST"
ssh -n -p "$port" "${opts[@]}" "$destination" "umask 077; mkdir -p '$run_dir'; chmod 700 '$run_dir'"
scp -P "$port" "${opts[@]}" .custom/deploy-latest.sh .custom/verify-running.rb "$destination:$run_dir/"
ssh -n -p "$port" "${opts[@]}" "$destination" "set -e; test ! -e '$run_dir/phase'; nohup bash '$run_dir/deploy-latest.sh' '$target' '$web_digest' '$stream_digest' '$run_dir' > '$run_dir/output.log' 2>&1 < /dev/null &"
last_phase=''
connection_failures=0
for ((attempt=0; attempt<240; attempt++)); do
  if ! status=$(ssh -n -p "$port" "${opts[@]}" "$destination" "if test -f '$run_dir/exit-code'; then printf 'EXIT='; cat '$run_dir/exit-code'; elif test -f '$run_dir/phase'; then cat '$run_dir/phase'; else printf 'starting'; fi"); then
    ((connection_failures+=1))
    if (( connection_failures >= 3 )); then
      echo "Connection lost. The server job may still be running: $run_dir" >&2
      exit 1
    fi
    sleep 15
    continue
  fi
  connection_failures=0
  case "$status" in
    EXIT=0) echo "Deployment verified: $target. Server logs: $run_dir"; exit 0 ;;
    EXIT=*) echo "Deployment failed ($status). Inspect $run_dir/output.log on the server." >&2; exit 1 ;;
  esac
  if test "$status" != "$last_phase"; then echo "Deployment phase: $status"; last_phase=$status; fi
  sleep 15
done
echo "Timed out waiting for deployment. The server job may still be running: $run_dir" >&2
exit 1
