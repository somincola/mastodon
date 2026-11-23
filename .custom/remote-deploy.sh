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
# Make a new private directory. Refuse an existing run instead of overwriting it.
ssh -n -T -p "$port" "${opts[@]}" "$destination" "sudo -n /usr/bin/mkdir -m 700 -- '$run_dir'"

# These uploads use stdin, so they must NOT use ssh -n.
ssh -T -p "$port" "${opts[@]}" "$destination" "sudo -n /usr/bin/tee -- '$run_dir/deploy-latest.sh' >/dev/null" < .custom/deploy-latest.sh
ssh -T -p "$port" "${opts[@]}" "$destination" "sudo -n /usr/bin/tee -- '$run_dir/verify-running.rb' >/dev/null" < .custom/verify-running.rb
ssh -n -T -p "$port" "${opts[@]}" "$destination" "sudo -n /usr/bin/chmod 600 -- '$run_dir/deploy-latest.sh' '$run_dir/verify-running.rb'"

read -r deploy_sha _ < <(sha256sum .custom/deploy-latest.sh)
read -r verify_sha _ < <(sha256sum .custom/verify-running.rb)
ssh -T -p "$port" "${opts[@]}" "$destination" "sudo -n /usr/bin/sha256sum -c -" <<CHECKSUMS
$deploy_sha  $run_dir/deploy-latest.sh
$verify_sha  $run_dir/verify-running.rb
CHECKSUMS
ssh -n -T -p "$port" "${opts[@]}" "$destination" "sudo -n /bin/bash -n '$run_dir/deploy-latest.sh'"

# Run as a root-owned system service, independent of the SSH/sudo session.
# Type=exec and StandardOutput=append are supported by systemd 249.
unit="mastodon-deploy-$run_id"
if ! ssh -n -T -p "$port" "${opts[@]}" "$destination" "sudo -n /usr/bin/systemd-run --unit='$unit' --uid=root --property=Type=exec --property=Restart=no --property=WorkingDirectory=/opt/mastodon --property=UMask=0077 --property='StandardOutput=append:$run_dir/output.log' --property=StandardError=inherit /usr/bin/env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin LANG=C.UTF-8 /bin/bash '$run_dir/deploy-latest.sh' '$target' '$web_digest' '$stream_digest' '$run_dir'"; then
  echo "Service start was not confirmed. Inspect $unit.service and $run_dir before retrying." >&2
  exit 1
fi

remote_status() {
  # This call also uses stdin, to pass a fixed status script to the root shell.
  ssh -T -p "$port" "${opts[@]}" "$destination" "sudo -n /bin/bash -s -- '$run_dir' '$unit'" <<'STATUS'
set -euo pipefail
run_dir=$1
unit=$2
if test -s "$run_dir/exit-code"; then
  printf 'EXIT='
  cat "$run_dir/exit-code"
elif /usr/bin/systemctl is-failed --quiet "$unit.service"; then
  printf 'EXIT=1'
elif test -f "$run_dir/phase"; then
  cat "$run_dir/phase"
else
  printf 'starting'
fi
STATUS
}
last_phase=''
connection_failures=0
for ((attempt=0; attempt<240; attempt++)); do
  if ! status=$(remote_status); then
    ((connection_failures+=1))
    if (( connection_failures >= 3 )); then
      echo "Unable to read deployment status. The server job may still be running: $run_dir" >&2
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
