#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

state="$HOME/.local/state/deskcomm-deploy"
repo=marlonbrandodeoliveira/DeskcommCRM
registry=ghcr.io/marlonbrandodeoliveira
api=http://127.0.0.1:3000/api
db=deskcommcrm_crm-supabase-db-1
services=(deskcommcrm_crm-app-1 deskcommcrm_crm-worker-1 deskcommcrm_crm-scheduler-1)
mode=${1:-}
[[ -z "$mode" || "$mode" == --check ]] || exit 2
mkdir -p "$state"
exec 9>"$state/lock"
flock -n 9 || exit 0

github() {
  curl -fsS --retry 2 --max-time 20 "https://api.github.com/repos/$repo/$1"
}

panel() {
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - -fsS --max-time 25 "$@"
}

source_url="$api/inspectComposeService?projectName=deskcommcrm&serviceName=crm"

save_source() {
  local request
  request=$(mktemp "$folder/panel-request.XXXXXXXX")
  python3 -c 'import json,sys; print(json.dumps({"projectName":"deskcommcrm","serviceName":"crm","content":open(sys.argv[1]).read()}))' "$1" > "$request"
  local rc=0
  panel --json "@$request" "$api/updateComposeSourceInline" >/dev/null || rc=$?
  rm -f "$request"
  return "$rc"
}

deploy() {
  panel --json '{"projectName":"deskcommcrm","serviceName":"crm"}' "$api/deployComposeService" >/dev/null
}

check_running() {
  local expected="$1" status
  for _ in $(seq 1 30); do
    status=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "${services[@]}" 2>/dev/null || true)
    if [[ "$status" == "$(printf '%s running healthy\n' "$expected" "$expected" "$expected")" ]]; then return 0; fi
    sleep 4
  done
  return 1
}

if [[ -s "$state/pending" ]]; then
  [[ "$mode" != --check ]] || { echo "Deploy pendente de verificacao."; exit 1; }
  token=$(<"$state/panel.token")
  pending=$(<"$state/pending")
  [[ "$pending" =~ ^[a-f0-9]{40}$ ]]
  if ! check_running "$pending"; then
    deploy
    check_running "$pending" || { echo "Deploy pendente: $pending"; exit 1; }
  fi
  rm -f "$state/pending"
  echo "Deploy verificado: $pending"
  exit 0
fi

revision=$(github 'actions/workflows/publish-image.yml/runs?branch=main&status=success&per_page=1' |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["workflow_runs"][0]["head_sha"])')
[[ "$revision" =~ ^[a-f0-9]{40}$ ]]
running=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${services[0]}")
[[ "$running" =~ ^[a-f0-9]{40}$ ]]
[[ "$running" != "$revision" ]] || { [[ -z "$mode" ]] || echo "Já instalado: $revision"; exit 0; }

comparison=$(github "compare/$running...$revision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
[[ "$comparison" == ahead ]] || { echo "A revisão publicada não é sucessora da instalação. Nenhuma mudança aplicada."; exit 1; }
token=$(<"$state/panel.token")
[[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]]

folder=$(mktemp -d "$state/upgrade.XXXXXXXX")
cd "$folder"
panel "$source_url" | python3 -c 'import json,sys; s=json.load(sys.stdin)["source"]; assert s["type"]=="inline"; print(s["content"])' > original.json
curl -fsS --max-time 60 "https://raw.githubusercontent.com/$repo/$revision/supabase/baseline.sql" -o baseline.sql
grep -q 'fn_definir_aparencia_da_organizacao' baseline.sql

for pair in app:deskcommcrm worker:deskcomm-worker scheduler:deskcomm-scheduler; do
  service=${pair%:*}
  package=${pair#*:}
  image="$registry/$package:main"
  docker pull "$image" > "pull-$service.log" 2>&1
  actual=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")
  [[ "$actual" == "$revision" ]] || { echo "Tags ainda não publicadas para a mesma revisão."; exit 1; }
  digest=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" | grep -F "$registry/$package@sha256:" | head -1)
  [[ -n "$digest" ]]
  printf '%s %s\n' "$service" "$digest" >> images
done

python3 - <<'PY'
import json
from pathlib import Path

services_to_images = dict(line.split() for line in Path("images").read_text().splitlines())
config = json.loads(Path("original.json").read_text())
services = config["services"]
env_to_service = {"APP_IMAGE": "app", "WORKER_IMAGE": "worker", "SCHEDULER_IMAGE": "scheduler"}
for name, image in services_to_images.items():
    current = services[name]["image"]
    assert current.startswith("ghcr.io/marlonbrandodeoliveira/") and "@sha256:" in current
    services[name]["image"] = image
    services[name]["pull_policy"] = "missing"
for service in services.values():
    env = service.get("environment")
    if isinstance(env, dict):
        for variable, name in env_to_service.items():
            if variable in env:
                env[variable] = services_to_images[name]
Path("candidate.json").write_text(json.dumps(config, ensure_ascii=False))
PY

docker compose -f candidate.json config --quiet > compose-validate.log 2>&1
if [[ "$mode" == --check ]]; then printf 'Candidato validado: %s\n' "$revision"; exit 0; fi
check_running "$running"

phase=ready
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ "$rc" -ne 0 ]]; then
    printf 'Falha durante %s. Arquivos do diagnóstico: %s\n' "$phase" "$folder"
    if [[ "$phase" == saving || "$phase" == stopped ]]; then save_source original.json || true; fi
    if [[ "$phase" == stopped ]]; then docker start "${services[@]}" >/dev/null || true; fi
  fi
  exit "$rc"
}
trap cleanup EXIT

phase=saving
save_source candidate.json
phase=stopped
docker stop -t 25 "${services[@]}" >/dev/null
docker exec "$db" pg_dump -U supabase_admin -d postgres -Fc > db.tmp
docker exec -i "$db" pg_restore --file=/dev/null < db.tmp
mv db.tmp db.dump
{
  printf "SET lock_timeout='10s';\nSET statement_timeout='180s';\n"
  cat baseline.sql
  printf "\nDO \$\$ BEGIN PERFORM public.fn_conferir_modulos_instalados(); END \$\$;\n"
} | docker exec -i "$db" psql -X -U postgres -d postgres --single-transaction -v ON_ERROR_STOP=1 -q -f - > migration.log 2>&1
phase=migrated
printf '%s\n' "$revision" > "$state/pending.tmp"
mv "$state/pending.tmp" "$state/pending"
deploy
check_running "$revision"
rm -f "$state/pending"
printf 'Deploy verificado: %s\n' "$revision"
