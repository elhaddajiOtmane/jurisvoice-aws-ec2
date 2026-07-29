#!/usr/bin/env bash
set -euo pipefail

CAPROVER_NAMESPACE='captain'
ROOT_DOMAIN='apps.jurisvoice.com'
CAPROVER_DOMAIN="captain.${ROOT_DOMAIN}"
N8N_DOMAIN='n8n.jurisvoice.com'
N8N_IMAGE='docker.n8n.io/n8nio/n8n:2.32.6'
POSTGRES_IMAGE='postgres:16'
LETSENCRYPT_EMAIL='contact@jurisvoice.com'
CAPROVER_LOCAL_API='http://127.0.0.1:3000/api/v2'
CAPROVER_PUBLIC_API="https://${CAPROVER_DOMAIN}/api/v2"

if curl --silent --fail --max-time 10 "https://${CAPROVER_DOMAIN}/" >/dev/null 2>&1; then
    CAPROVER_API="$CAPROVER_PUBLIC_API"
else
    CAPROVER_API="$CAPROVER_LOCAL_API"
fi

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "Required file is missing: $1" >&2
        exit 1
    fi
}

json_field() {
    local field="$1"
    python3 -c "import json,sys; print(json.load(sys.stdin)${field})"
}

check_response() {
    local action="$1"
    local response="$2"
    local status
    local description
    status="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))')"
    description="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("description", ""))')"
    if [[ "$status" != '100' && "$status" != '101' ]]; then
        echo "${action} failed: ${description:-unknown CapRover API error}" >&2
        exit 1
    fi
    echo "${action}: ${description}"
}

api_get() {
    local path="$1"
    curl --fail --silent --show-error \
        --retry 5 --retry-connrefused --max-time 600 \
        -H "x-namespace: ${CAPROVER_NAMESPACE}" \
        -H "x-captain-auth: ${CAPROVER_AUTH_TOKEN}" \
        "${CAPROVER_API}${path}"
}

api_post_json() {
    local action="$1"
    local path="$2"
    local body="$3"
    local response
    response="$(curl --fail --silent --show-error \
        --retry 5 --retry-connrefused --max-time 600 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H "x-namespace: ${CAPROVER_NAMESPACE}" \
        -H "x-captain-auth: ${CAPROVER_AUTH_TOKEN}" \
        --data "$body" \
        "${CAPROVER_API}${path}")"
    check_response "$action" "$response"
}

deploy_image() {
    local app_name="$1"
    local image_name="$2"
    local captain_definition
    local response
    captain_definition="{\"schemaVersion\":2,\"imageName\":\"${image_name}\"}"
    response="$(curl --fail --silent --show-error \
        --retry 3 --retry-connrefused --max-time 900 \
        -X POST \
        -H "x-namespace: ${CAPROVER_NAMESPACE}" \
        -H "x-captain-auth: ${CAPROVER_AUTH_TOKEN}" \
        --form-string "captainDefinitionContent=${captain_definition}" \
        --form-string 'gitHash=' \
        "${CAPROVER_API}/user/apps/appData/${app_name}/")"
    check_response "Deploy ${app_name}" "$response"
}

service_uses_image() {
    local service_name="$1"
    local desired_image="$2"
    local current_image
    current_image="$(docker service inspect \
        --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' \
        "$service_name" 2>/dev/null || true)"
    [[ "$current_image" == "$desired_image" || "$current_image" == "${desired_image}@"* ]]
}

generate_root_secret() {
    local path="$1"
    local bytes="$2"
    if [[ ! -f "$path" ]]; then
        umask 077
        openssl rand -hex "$bytes" >"$path"
        chmod 600 "$path"
    fi
}

login_password=''
login_response=''
if [[ -f /root/caprover-admin-password ]]; then
    password_candidates=("$(cat /root/caprover-admin-password)")
else
    require_file /root/caprover-initial-password
    password_candidates=(
        "$(cut -c1-29 /root/caprover-initial-password)"
        "\"$(cut -c1-28 /root/caprover-initial-password)"
        'captain42'
    )
fi

for candidate in "${password_candidates[@]}"; do
    response="$(curl --fail --silent --show-error \
        --retry 5 --retry-connrefused --max-time 60 \
        -X POST \
        -H 'Content-Type: application/json' \
        -H "x-namespace: ${CAPROVER_NAMESPACE}" \
        --data "$(python3 -c 'import json,sys; print(json.dumps({"password":sys.argv[1]}))' "$candidate")" \
        "${CAPROVER_API}/login")"
    status="$(printf '%s' "$response" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))')"
    if [[ "$status" == '100' ]]; then
        login_password="$candidate"
        login_response="$response"
        break
    fi
done
unset candidate
unset password_candidates

if [[ -z "$login_response" ]]; then
    echo 'CapRover login failed for all safe bootstrap password candidates.' >&2
    exit 1
fi
check_response 'CapRover login' "$login_response"
CAPROVER_AUTH_TOKEN="$(printf '%s' "$login_response" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["token"])')"

if [[ "${1:-}" == '--pin-n8n-only' ]]; then
    if service_uses_image 'srv-captain--n8n' "$N8N_IMAGE"; then
        echo "n8n image is already ${N8N_IMAGE}."
    else
        deploy_image 'n8n' "$N8N_IMAGE"
    fi
    unset CAPROVER_AUTH_TOKEN
    unset login_password
    exit 0
fi

system_info="$(api_get '/user/system/info/')"
check_response 'Read CapRover system configuration' "$system_info"
current_root_domain="$(printf '%s' "$system_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("rootDomain", ""))')"
if [[ -z "$current_root_domain" ]]; then
    api_post_json \
        'Configure CapRover root domain' \
        '/user/system/changerootdomain/' \
        "{\"rootDomain\":\"${ROOT_DOMAIN}\",\"force\":false}"
    sleep 8
elif [[ "$current_root_domain" != "$ROOT_DOMAIN" ]]; then
    echo "CapRover already has an unexpected root domain: ${current_root_domain}" >&2
    exit 1
else
    echo "CapRover root domain is already configured."
fi

system_info="$(api_get '/user/system/info/')"
has_root_ssl="$(printf '%s' "$system_info" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["data"].get("hasRootSsl", False)).lower())')"
if [[ "$has_root_ssl" != 'true' ]]; then
    api_post_json \
        'Enable CapRover HTTPS' \
        '/user/system/enablessl/' \
        "{\"emailAddress\":\"${LETSENCRYPT_EMAIL}\"}"
else
    echo "CapRover HTTPS is already enabled."
fi

system_info="$(api_get '/user/system/info/')"
force_root_ssl="$(printf '%s' "$system_info" | python3 -c 'import json,sys; print(str(json.load(sys.stdin)["data"].get("forceSsl", False)).lower())')"
if [[ "$force_root_ssl" != 'true' ]]; then
    api_post_json \
        'Force CapRover HTTPS' \
        '/user/system/forcessl/' \
        '{"isEnabled":true}'
else
    echo "CapRover HTTPS redirect is already enabled."
fi
CAPROVER_API="$CAPROVER_PUBLIC_API"

generate_root_secret /root/n8n-postgres-password 24
generate_root_secret /root/n8n-encryption-key 32
POSTGRES_PASSWORD="$(cat /root/n8n-postgres-password)"
N8N_ENCRYPTION_KEY="$(cat /root/n8n-encryption-key)"

app_definitions="$(api_get '/user/apps/appDefinitions/')"
check_response 'Read CapRover applications' "$app_definitions"

app_exists() {
    local app_name="$1"
    printf '%s' "$app_definitions" | python3 -c \
        'import json,sys; name=sys.argv[1]; apps=json.load(sys.stdin)["data"]["appDefinitions"]; print("true" if any(a.get("appName")==name for a in apps) else "false")' \
        "$app_name"
}

if [[ "$(app_exists 'n8n-postgres')" != 'true' ]]; then
    api_post_json \
        'Register n8n PostgreSQL service' \
        '/user/apps/appDefinitions/register/' \
        '{"appName":"n8n-postgres","hasPersistentData":true}'
    app_definitions="$(api_get '/user/apps/appDefinitions/')"
fi

postgres_payload="$(python3 -c '
import json,sys
password=sys.argv[1]
print(json.dumps({
  "appName":"n8n-postgres",
  "description":"PostgreSQL database for n8n",
  "instanceCount":1,
  "notExposeAsWebApp":True,
  "containerHttpPort":5432,
  "forceSsl":False,
  "websocketSupport":False,
  "envVars":[
    {"key":"POSTGRES_USER","value":"n8n"},
    {"key":"POSTGRES_PASSWORD","value":password},
    {"key":"POSTGRES_DB","value":"n8n"},
    {"key":"PGDATA","value":"/var/lib/postgresql/data/pgdata"}
  ],
  "volumes":[
    {"containerPath":"/var/lib/postgresql/data","volumeName":"n8n-postgres-data"}
  ],
  "ports":[],
  "tags":[],
  "customNginxConfig":"",
  "redirectDomain":"",
  "preDeployFunction":"",
  "serviceUpdateOverride":"",
  "appDeployTokenConfig":{"enabled":False}
}))' "$POSTGRES_PASSWORD")"
api_post_json \
    'Configure n8n PostgreSQL service' \
    '/user/apps/appDefinitions/update/' \
    "$postgres_payload"
if service_uses_image 'srv-captain--n8n-postgres' "$POSTGRES_IMAGE"; then
    echo "n8n PostgreSQL image is already ${POSTGRES_IMAGE}."
else
    deploy_image 'n8n-postgres' "$POSTGRES_IMAGE"
fi

postgres_ready='false'
for _ in $(seq 1 45); do
    postgres_container="$(docker ps -q --filter name=srv-captain--n8n-postgres | head -n1)"
    if [[ -n "$postgres_container" ]] &&
        docker exec "$postgres_container" pg_isready -U n8n -d n8n >/dev/null 2>&1; then
        postgres_ready='true'
        break
    fi
    sleep 2
done
if [[ "$postgres_ready" != 'true' ]]; then
    echo 'PostgreSQL did not become ready in time.' >&2
    docker service logs --tail 100 srv-captain--n8n-postgres >&2 || true
    exit 1
fi
echo 'PostgreSQL is ready.'

app_definitions="$(api_get '/user/apps/appDefinitions/')"
if [[ "$(app_exists 'n8n')" != 'true' ]]; then
    api_post_json \
        'Register n8n service' \
        '/user/apps/appDefinitions/register/' \
        '{"appName":"n8n","hasPersistentData":true}'
    app_definitions="$(api_get '/user/apps/appDefinitions/')"
fi

create_n8n_payload() {
    local force_ssl="$1"
    python3 -c '
import json,sys
db_password=sys.argv[1]
encryption_key=sys.argv[2]
force_ssl=sys.argv[3].lower()=="true"
print(json.dumps({
  "appName":"n8n",
  "description":"n8n workflow automation",
  "instanceCount":1,
  "notExposeAsWebApp":False,
  "containerHttpPort":5678,
  "forceSsl":force_ssl,
  "websocketSupport":True,
  "envVars":[
    {"key":"DB_TYPE","value":"postgresdb"},
    {"key":"DB_POSTGRESDB_HOST","value":"srv-captain--n8n-postgres"},
    {"key":"DB_POSTGRESDB_PORT","value":"5432"},
    {"key":"DB_POSTGRESDB_DATABASE","value":"n8n"},
    {"key":"DB_POSTGRESDB_USER","value":"n8n"},
    {"key":"DB_POSTGRESDB_PASSWORD","value":db_password},
    {"key":"N8N_HOST","value":"n8n.jurisvoice.com"},
    {"key":"N8N_PORT","value":"5678"},
    {"key":"N8N_PROTOCOL","value":"https"},
    {"key":"WEBHOOK_URL","value":"https://n8n.jurisvoice.com/"},
    {"key":"N8N_EDITOR_BASE_URL","value":"https://n8n.jurisvoice.com/"},
    {"key":"N8N_PROXY_HOPS","value":"1"},
    {"key":"N8N_ENCRYPTION_KEY","value":encryption_key},
    {"key":"N8N_SECURE_COOKIE","value":"true"},
    {"key":"N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS","value":"true"},
    {"key":"EXECUTIONS_DATA_PRUNE","value":"true"},
    {"key":"EXECUTIONS_DATA_MAX_AGE","value":"336"},
    {"key":"GENERIC_TIMEZONE","value":"America/New_York"},
    {"key":"TZ","value":"America/New_York"}
  ],
  "volumes":[
    {"containerPath":"/home/node/.n8n","volumeName":"n8n-data"}
  ],
  "ports":[],
  "tags":[],
  "customNginxConfig":"",
  "redirectDomain":"",
  "preDeployFunction":"",
  "serviceUpdateOverride":"",
  "appDeployTokenConfig":{"enabled":False}
}))' "$POSTGRES_PASSWORD" "$N8N_ENCRYPTION_KEY" "$force_ssl"
}

n8n_payload="$(create_n8n_payload 'false')"
api_post_json \
    'Configure n8n service' \
    '/user/apps/appDefinitions/update/' \
    "$n8n_payload"
if service_uses_image 'srv-captain--n8n' "$N8N_IMAGE"; then
    echo "n8n image is already ${N8N_IMAGE}."
else
    deploy_image 'n8n' "$N8N_IMAGE"
fi

n8n_ready='false'
for _ in $(seq 1 90); do
    if curl --silent --fail \
        -H "Host: n8n.${ROOT_DOMAIN}" \
        http://127.0.0.1/healthz >/dev/null 2>&1; then
        n8n_ready='true'
        break
    fi
    sleep 2
done
if [[ "$n8n_ready" != 'true' ]]; then
    echo 'n8n did not become ready in time.' >&2
    docker service logs --tail 150 srv-captain--n8n >&2 || true
    exit 1
fi
echo 'n8n is ready over internal HTTP.'

app_definitions="$(api_get '/user/apps/appDefinitions/')"
has_custom_domain="$(printf '%s' "$app_definitions" | python3 -c '
import json,sys
apps=json.load(sys.stdin)["data"]["appDefinitions"]
app=next((a for a in apps if a.get("appName")=="n8n"), {})
print("true" if any(d.get("publicDomain")=="n8n.jurisvoice.com" for d in app.get("customDomain", [])) else "false")
')"
if [[ "$has_custom_domain" != 'true' ]]; then
    api_post_json \
        'Attach n8n custom domain' \
        '/user/apps/appDefinitions/customdomain/' \
        "{\"appName\":\"n8n\",\"customDomain\":\"${N8N_DOMAIN}\"}"
fi

app_definitions="$(api_get '/user/apps/appDefinitions/')"
has_custom_ssl="$(printf '%s' "$app_definitions" | python3 -c '
import json,sys
apps=json.load(sys.stdin)["data"]["appDefinitions"]
app=next((a for a in apps if a.get("appName")=="n8n"), {})
domain=next((d for d in app.get("customDomain", []) if d.get("publicDomain")=="n8n.jurisvoice.com"), {})
print(str(bool(domain.get("hasSsl"))).lower())
')"
if [[ "$has_custom_ssl" != 'true' ]]; then
    api_post_json \
        'Enable n8n HTTPS' \
        '/user/apps/appDefinitions/enablecustomdomainssl/' \
        "{\"appName\":\"n8n\",\"customDomain\":\"${N8N_DOMAIN}\"}"
fi

n8n_payload="$(create_n8n_payload 'true')"
api_post_json \
    'Force n8n HTTPS' \
    '/user/apps/appDefinitions/update/' \
    "$n8n_payload"

if [[ ! -f /root/caprover-admin-password ]]; then
    generate_root_secret /root/caprover-admin-password 12
    new_admin_password="$(cat /root/caprover-admin-password)"
    api_post_json \
        'Rotate CapRover administrator password' \
        '/user/changepassword/' \
        "{\"oldPassword\":\"${login_password}\",\"newPassword\":\"${new_admin_password}\"}"
    rm -f /root/caprover-initial-password
    rm -f /root/caprover-initial-password.invalid-*
    docker service update --env-rm DEFAULT_PASSWORD captain-captain >/dev/null
fi

unset CAPROVER_AUTH_TOKEN
unset login_password
unset POSTGRES_PASSWORD
unset N8N_ENCRYPTION_KEY

echo "CapRover URL: https://${CAPROVER_DOMAIN}"
echo "n8n URL: https://${N8N_DOMAIN}"
