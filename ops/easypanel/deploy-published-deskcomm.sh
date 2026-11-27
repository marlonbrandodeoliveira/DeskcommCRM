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
revision=${2:-}
if [[ $# -ne 2 || ( "$mode" != --check && "$mode" != --apply ) || ! "$revision" =~ ^[a-f0-9]{40}$ ]]; then
  echo "Uso: $0 {--check|--apply} SHA_COMPLETO_DE_MAIN" >&2
  exit 2
fi
mkdir -p "$state"
exec 9>"$state/lock"
flock -n 9 || { echo 'Já existe uma implantação em andamento.' >&2; exit 1; }

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
  echo 'Há uma implantação pendente. Siga a recuperação em DEPLOYMENT.md.' >&2
  exit 1
fi

main=$(github 'branches/main' | python3 -c 'import json,sys; print(json.load(sys.stdin)["commit"]["sha"])')
[[ "$main" == "$revision" ]] || { echo 'O SHA aprovado não é mais o topo de main.' >&2; exit 1; }
published=$(github "actions/workflows/publish-image.yml/runs?branch=main&head_sha=$revision&status=success&per_page=20" |
  python3 -c 'import json,sys; print(any(run["head_sha"] == sys.argv[1] and run["event"] in ("push", "workflow_dispatch") and run["conclusion"] == "success" for run in json.load(sys.stdin)["workflow_runs"]))' "$revision")
[[ "$published" == True ]] || { echo 'A publicação desse SHA em GHCR ainda não foi aprovada pelo CI de imagens.' >&2; exit 1; }
running=$(docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${services[0]}")
[[ "$running" =~ ^[a-f0-9]{40}$ ]]
if [[ "$running" == "$revision" ]]; then
  check_running "$revision"
  echo "Já instalado: $revision"
  exit 0
fi

comparison=$(github "compare/$running...$revision" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')
[[ "$comparison" == ahead ]] || { echo "A revisão publicada não é sucessora da instalação. Nenhuma mudança aplicada."; exit 1; }
token=$(<"$state/panel.token")
[[ "$token" =~ ^[A-Za-z0-9._~+/-]+=*$ ]]

folder=$(mktemp -d "$state/upgrade.XXXXXXXX")
cd "$folder"
panel "$source_url" | python3 -c '
import json
import sys

source = json.load(sys.stdin)["source"]
if source["type"] != "inline":
    sys.exit("O Compose precisa usar a fonte inline.")
content = source["content"]
config = json.loads(content) if isinstance(content, str) else content
if not isinstance(config, dict) or not isinstance(config.get("services"), dict):
    sys.exit("A fonte inline não contém um Compose JSON válido.")
print(json.dumps(config))
' > original.json
curl -fsS --max-time 60 "https://raw.githubusercontent.com/$repo/$revision/supabase/baseline.sql" -o baseline.sql
curl -fsS --max-time 60 "https://raw.githubusercontent.com/$repo/$running/supabase/baseline.sql" -o baseline-anterior.sql
schema_changed=false
if ! cmp -s baseline-anterior.sql baseline.sql; then
  schema_changed=true
  grep -q 'fn_conferir_modulos_instalados' baseline.sql
fi

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
if [[ "$mode" == --check ]]; then
  printf 'Candidato validado: %s (mudança no schema: %s)\n' "$revision" "$schema_changed"
  exit 0
fi
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

if [[ "$schema_changed" == true ]]; then
  phase=stopped
  docker stop -t 25 "${services[@]}" >/dev/null
fi
docker exec "$db" pg_dump -U supabase_admin -d postgres -Fc > db.tmp
docker exec -i "$db" pg_restore --file=/dev/null < db.tmp
mv db.tmp db.dump

# Bloqueia novas tentativas enquanto o operador verifica uma implantação interrompida.
if [[ "$schema_changed" != true ]]; then phase=saving; fi
save_source candidate.json
printf '%s\n' "$revision" > "$state/pending.tmp"
mv "$state/pending.tmp" "$state/pending"
if [[ "$schema_changed" == true ]]; then
  if ! {
    printf "SET lock_timeout='10s';\nSET statement_timeout='180s';\n"
    cat baseline.sql
    printf "\nDO \$\$ BEGIN PERFORM public.fn_conferir_modulos_instalados(); END \$\$;\n"
  } | docker exec -i "$db" psql -X -U postgres -d postgres --single-transaction -v ON_ERROR_STOP=1 -q -f - > migration.log 2>&1; then
    phase=migration-uncertain
    exit 1
  fi
fi
phase=deploying
deploy
check_running "$revision"
rm -f "$state/pending"
printf 'Deploy verificado: %s\n' "$revision"
