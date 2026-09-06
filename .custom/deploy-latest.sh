#!/usr/bin/env bash
# Runs on the server as a detached job. Compose permanently follows latest.
set -euo pipefail
umask 077
target=${1:?Stable version required}
web_digest=${2:?Web digest required}
stream_digest=${3:?Streaming digest required}
run_dir=${4:?Private run directory required}
[[ "$target" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 2
[[ "$web_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
[[ "$stream_digest" =~ ^sha256:[a-f0-9]{64}$ ]] || exit 2
[[ "$run_dir" =~ ^/opt/mastodon/automation/[a-zA-Z0-9_-]+$ ]] || exit 2
mkdir -p "$run_dir"
chmod 700 "$run_dir"
finish() {
  local rc=$?
  printf '%s\n' "$rc" > "$run_dir/exit-code"
  if (( rc != 0 )); then
    printf '%s\n' 'Deployment failed. Preserve logs and backup; do not downgrade images after migrations.' >&2
  fi
}
trap finish EXIT
phase() {
  printf '%s\n' "$1" > "$run_dir/phase"
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1"
}
cd /opt/mastodon
exec 9> /opt/mastodon/.deployment.lock
flock -n 9 || { echo 'Another deployment or maintenance task holds the lock.' >&2; exit 1; }
compose_files=(-f /opt/mastodon/docker-compose.yml)
if test -f /opt/mastodon/docker-compose.override.yml; then
  compose_files+=(-f /opt/mastodon/docker-compose.override.yml)
fi
dc() { docker compose -p mastodon --project-directory /opt/mastodon "${compose_files[@]}" "$@"; }
dclocal() { docker compose -p mastodon --project-directory /opt/mastodon "${compose_files[@]}" -f "$run_dir/compose.no-pull.json" "$@"; }
# Compose 2.27 lacks `run --pull`; this per-run policy uses only the images
# already pulled and verified. The permanent server configuration stays latest.
printf '%s\n' '{"services":{"web":{"pull_policy":"never"},"sidekiq":{"pull_policy":"never"},"streaming":{"pull_policy":"never"}}}' > "$run_dir/compose.no-pull.json"
phase preflight
dc config --format json > "$run_dir/compose.before.json"
docker inspect mastodon-web-1 mastodon-sidekiq-1 mastodon-streaming-1 > "$run_dir/containers.before.json"
python3 - "$run_dir" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
c=json.loads((p/'compose.before.json').read_text())['services']
for name in ('web','sidekiq','streaming'):
    expected='bailongctui/mastodon'+('-streaming' if name=='streaming' else '')+':latest'
    assert c[name]['image']==expected, f'{name} must follow latest before using automatic deployment'
for service in json.loads((p/'containers.before.json').read_text()):
    assert service['State']['Running'], service['Name']
PY
curl -fsS --max-time 20 -H 'Host: m.somincola.org' -H 'X-Forwarded-Proto: https' http://127.0.0.1:3000/api/v2/instance > "$run_dir/instance.before.json"
python3 - "$run_dir/instance.before.json" "$target" <<'PY'
import json,re,sys
current=json.load(open(sys.argv[1]))['version']
target=sys.argv[2][1:]
assert re.fullmatch(r'\d+\.\d+\.\d+',current), 'Unexpected live version'
a,b=tuple(map(int,current.split('.'))),tuple(map(int,target.split('.')))
assert b>=a, 'Refusing a production downgrade'
assert b[:2]==a[:2], 'Cross-minor upgrades require their reviewed migration procedure'
PY
phase pull-latest
test "$(df -B1 --output=avail /opt/mastodon | tail -1 | tr -d ' ')" -gt 5368709120
dc pull web sidekiq streaming
docker image inspect bailongctui/mastodon:latest bailongctui/mastodon-streaming:latest > "$run_dir/images.pulled.json"
python3 - "$run_dir" "$web_digest" "$stream_digest" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
images=json.loads((p/'images.pulled.json').read_text())
for image,repo,digest in zip(images,('bailongctui/mastodon','bailongctui/mastodon-streaming'),sys.argv[2:]):
    assert any(ref.removeprefix('docker.io/')==repo+'@'+digest for ref in image['RepoDigests']), 'latest moved or an image pair is incomplete'
before=json.loads((p/'containers.before.json').read_text())
changed=any(c['Image']!=images[1 if c['Name']=='/mastodon-streaming-1' else 0]['Id'] for c in before)
(p/'image-content-changed').write_text('true' if changed else 'false')
PY
docker run --rm --network none --entrypoint ruby bailongctui/mastodon:latest -r ./lib/mastodon/version -e 'abort "Wrong image version" unless Mastodon::Version.to_a.join(".") == ARGV.fetch(0)' "${target#v}"

phase inspect-migrations
dclocal run --rm --no-deps -T web env -u SKIP_POST_DEPLOYMENT_MIGRATIONS bundle exec rails db:migrate:status > "$run_dir/migration-status.before.log"
needs_migration=false
if test "$(cat "$run_dir/image-content-changed")" = true || grep -Eq '^[[:space:]]+down[[:space:]]' "$run_dir/migration-status.before.log"; then
  needs_migration=true
fi
if test "$needs_migration" = true; then
  phase backup
  backup="$run_dir/backup"
  mkdir -m 700 "$backup"
  # Refuse to start a new database backup when less than 5 GiB is free.
  test "$(df -B1 --output=avail /opt/mastodon | tail -1 | tr -d ' ')" -gt 5368709120
  cp .env.production docker-compose.yml "$backup/"
  if test -f docker-compose.override.yml; then cp docker-compose.override.yml "$backup/"; fi
  cp "$run_dir/compose.before.json" "$run_dir/containers.before.json" "$backup/"
  python3 - "$run_dir" <<'PY'
import json,pathlib,subprocess,sys
p=pathlib.Path(sys.argv[1]); rollback={'services':{}}
for c in json.loads((p/'containers.before.json').read_text()):
    service=c['Name'].removeprefix('/mastodon-').removesuffix('-1')
    tag=f'local/mastodon-{service}-rollback:{p.name}'
    subprocess.run(['docker','tag',c['Image'],tag],check=True)
    rollback['services'][service]={'image':tag}
(p/'backup'/'compose.rollback.json').write_text(json.dumps(rollback,indent=2))
PY
  docker exec mastodon-db-1 pg_dump -Fc -U mastodon -d mastodon_production > "$backup/mastodon_production.dump.partial"
  test -s "$backup/mastodon_production.dump.partial"
  mv "$backup/mastodon_production.dump.partial" "$backup/mastodon_production.dump"
  docker exec -i mastodon-db-1 pg_restore --list < "$backup/mastodon_production.dump" > "$backup/dump-toc.txt"
  grep -q 'TABLE DATA public statuses' "$backup/dump-toc.txt"
  docker exec mastodon-db-1 pg_dumpall --globals-only -U mastodon > "$backup/postgres-globals.sql"
  docker exec mastodon-redis-1 redis-cli --rdb /tmp/mastodon-before-deploy.rdb
  docker exec mastodon-redis-1 redis-check-rdb /tmp/mastodon-before-deploy.rdb
  docker cp mastodon-redis-1:/tmp/mastodon-before-deploy.rdb "$backup/redis.rdb"
  chmod 600 "$backup/redis.rdb"
  (cd "$backup" && sha256sum mastodon_production.dump redis.rdb .env.production docker-compose.yml postgres-globals.sql > SHA256SUMS && sha256sum -c SHA256SUMS)
  date -u +%FT%TZ > "$backup/COMPLETED"
  phase pre-migrations
  dclocal run --rm --no-deps -T -e SKIP_POST_DEPLOYMENT_MIGRATIONS=true web bundle exec rails db:migrate
fi

phase restart-services
dclocal up -d --no-deps --wait --wait-timeout 180 web sidekiq streaming
if test "$needs_migration" = true; then
  phase post-migrations
  dclocal run --rm --no-deps -T web env -u SKIP_POST_DEPLOYMENT_MIGRATIONS bundle exec rails db:migrate
fi
phase verify
dclocal run --rm --no-deps -T web env -u SKIP_POST_DEPLOYMENT_MIGRATIONS bundle exec rails db:migrate:status > "$run_dir/migration-status.log"
if grep -Eq '^[[:space:]]+down[[:space:]]' "$run_dir/migration-status.log"; then echo 'Pending migrations remain.' >&2; exit 1; fi
chmod 644 "$run_dir/verify-running.rb"
dclocal run --rm --no-deps -T -e EXPECTED_MASTODON_VERSION="${target#v}" -v "$run_dir/verify-running.rb:/verify-running.rb:ro" web bundle exec rails runner /verify-running.rb > "$run_dir/application-check.json"
curl -fsS --max-time 20 -H 'Host: m.somincola.org' -H 'X-Forwarded-Proto: https' http://127.0.0.1:3000/api/v2/instance > "$run_dir/instance.after.json"
curl -fsS --max-time 20 http://127.0.0.1:4000/api/v1/streaming/health > "$run_dir/streaming-health.txt"
docker inspect mastodon-web-1 mastodon-sidekiq-1 mastodon-streaming-1 > "$run_dir/containers.after.json"
python3 - "$run_dir" "$target" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); instance=json.loads((p/'instance.after.json').read_text())
assert instance['version']==sys.argv[2][1:]
assert instance['configuration']['statuses']['max_characters']==5000
images=json.loads((p/'images.pulled.json').read_text())
for c in json.loads((p/'containers.after.json').read_text()):
    streaming=c['Name']=='/mastodon-streaming-1'
    assert c['State']['Running'] and c['State']['Health']['Status']=='healthy'
    assert c['Image']==images[1 if streaming else 0]['Id']
    assert c['Config']['Image']=='bailongctui/mastodon'+('-streaming' if streaming else '')+':latest'
PY
printf '%s\n' "$target" > /opt/mastodon/.deployed-version.new
mv /opt/mastodon/.deployed-version.new /opt/mastodon/.deployed-version
phase complete
