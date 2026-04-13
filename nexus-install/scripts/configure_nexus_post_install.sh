#!/usr/bin/env bash
# ============================================================
# configure_nexus_post_install.sh
# Nexus CE 3.91.0 초기 설정 — REST API 자동화
#
# Repository 2계열:
#   application-install-raw — 일반 배포 파일
#     primary:   hosted repo
#     secondary: proxy repo → primary
#   infra-automation-raw — 포털 업로드/삭제 (Primary 178 전용)
#     primary:   hosted repo + webhook
#     secondary: 해당 없음
#
# 실행: sudo bash configure_nexus_post_install.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
if [[ -f "${SCRIPT_DIR}/../config/install.env" ]]; then
    source "${SCRIPT_DIR}/../config/install.env"
elif [[ -f "${SCRIPT_DIR}/config/install.env" ]]; then
    source "${SCRIPT_DIR}/config/install.env"
else
    echo "[ERROR] install.env 를 찾을 수 없습니다."; exit 1
fi
set +a

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $(date '+%H:%M:%S') ====== $* ======"; }

NEXUS_URL="http://localhost:${NEXUS_HTTP_PORT}"
log_info "=== Nexus 초기 설정 (역할: ${NEXUS_ROLE}) ==="

# --- API 헬퍼 ---
nexus_api() {
    local method="$1"; local path="$2"; local user="$3"; local pass="$4"; shift 4
    curl -s -f -X "${method}" -u "${user}:${pass}" -H "Content-Type: application/json" "${NEXUS_URL}${path}" "$@"
}
nexus_api_status() {
    local method="$1"; local path="$2"; local user="$3"; local pass="$4"; shift 4
    curl -s -o /dev/null -w '%{http_code}' -X "${method}" -u "${user}:${pass}" -H "Content-Type: application/json" "${NEXUS_URL}${path}" "$@"
}

# --- Nexus 상태 확인 ---
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "${NEXUS_URL}/service/rest/v1/status" 2>/dev/null || echo "000")
if [[ "${HTTP_CODE}" != "200" ]]; then
    log_error "Nexus 미응답 (HTTP ${HTTP_CODE})"; exit 1
fi
log_info "Nexus 정상 (HTTP 200)"

# --- 초기 비밀번호 ---
ADMIN_PASS_FILE="${NEXUS_DATA_DIR}/admin.password"
if [[ -f "${ADMIN_PASS_FILE}" ]]; then
    CURRENT_ADMIN_PASS=$(cat "${ADMIN_PASS_FILE}"); FIRST_RUN="true"
    log_info "초기 비밀번호 파일 발견"
else
    CURRENT_ADMIN_PASS="${NEXUS_ADMIN_PASSWORD}"; FIRST_RUN="false"
fi

# ============================================================
# Step 0. EULA 수락
# ============================================================
log_step "0. EULA 수락"
EULA_TEXT=$(curl -s -u "admin:${CURRENT_ADMIN_PASS}" "${NEXUS_URL}/service/rest/v1/system/eula" 2>/dev/null || echo "")
if [[ -n "${EULA_TEXT}" ]]; then
    DISCLAIMER=$(echo "${EULA_TEXT}" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin); print(d.get('disclaimer', ''))
except: print('')
" 2>/dev/null || echo "")
    if [[ -n "${DISCLAIMER}" ]]; then
        EULA_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
            -u "admin:${CURRENT_ADMIN_PASS}" -H "Content-Type: application/json" \
            "${NEXUS_URL}/service/rest/v1/system/eula" \
            -d "{\"accepted\": true, \"disclaimer\": $(echo "${DISCLAIMER}" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}")
        log_info "EULA 수락 (HTTP ${EULA_STATUS})"
    else
        log_info "EULA 이미 수락됨"
    fi
fi

# ============================================================
# Step 1. admin 비밀번호
# ============================================================
log_step "1. admin 비밀번호"
if [[ "${FIRST_RUN}" == "true" ]]; then
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
        -u "admin:${CURRENT_ADMIN_PASS}" -H "Content-Type: text/plain" \
        "${NEXUS_URL}/service/rest/v1/security/users/admin/change-password" \
        -d "${NEXUS_ADMIN_PASSWORD}")
    if [[ "${STATUS}" == "204" || "${STATUS}" == "200" ]]; then
        CURRENT_ADMIN_PASS="${NEXUS_ADMIN_PASSWORD}"; rm -f "${ADMIN_PASS_FILE}"
        log_info "변경 완료"
    else
        log_error "변경 실패 (HTTP ${STATUS})"; exit 1
    fi
else
    log_warn "이미 설정됨 (skip)"
fi

# ============================================================
# Step 2. 익명 접근 비활성화
# ============================================================
log_step "2. 익명 접근 비활성화"
nexus_api_status PUT "/service/rest/v1/security/anonymous" "admin" "${CURRENT_ADMIN_PASS}" \
    -d '{"enabled": false, "userId": "anonymous", "realmName": "NexusAuthorizingRealm"}' >/dev/null
log_info "완료"

# ============================================================
# Step 3. Blob Store
# ============================================================
log_step "3. Blob Store"
BLOB_LIST=$(nexus_api GET "/service/rest/v1/blobstores" "admin" "${CURRENT_ADMIN_PASS}" 2>/dev/null || echo "[]")
echo "${BLOB_LIST}" | grep -q "\"name\":\"${BLOB_STORE_NAME}\"" && log_info "'${BLOB_STORE_NAME}' 존재" || \
    nexus_api_status POST "/service/rest/v1/blobstores/file" "admin" "${CURRENT_ADMIN_PASS}" \
        -d "{\"name\": \"${BLOB_STORE_NAME}\", \"path\": \"${BLOB_STORE_NAME}\"}" >/dev/null

# --- Repository 생성 헬퍼 ---
create_hosted_repo() {
    local repo_name="$1"
    local rc=$(nexus_api_status GET "/service/rest/v1/repositories/${repo_name}" "admin" "${CURRENT_ADMIN_PASS}")
    if [[ "${rc}" == "200" ]]; then
        log_warn "Repository '${repo_name}' 이미 존재 (skip)"; return 0
    fi
    log_info "Hosted Repository '${repo_name}' 생성..."
    local st=$(nexus_api_status POST "/service/rest/v1/repositories/raw/hosted" "admin" "${CURRENT_ADMIN_PASS}" \
        -d "{
            \"name\": \"${repo_name}\",
            \"online\": true,
            \"storage\": {
                \"blobStoreName\": \"${BLOB_STORE_NAME}\",
                \"strictContentTypeValidation\": false,
                \"writePolicy\": \"${RAW_REPO_WRITE_POLICY}\"
            },
            \"cleanup\": { \"policyNames\": [] }
        }")
    log_info "  -> HTTP ${st}"
}

create_proxy_repo() {
    local repo_name="$1"; local remote_url="$2"
    local rc=$(nexus_api_status GET "/service/rest/v1/repositories/${repo_name}" "admin" "${CURRENT_ADMIN_PASS}")
    if [[ "${rc}" == "200" ]]; then
        log_warn "Repository '${repo_name}' 이미 존재 (skip)"; return 0
    fi
    log_info "Proxy Repository '${repo_name}' 생성..."
    log_info "  Remote: ${remote_url}"
    local st=$(nexus_api_status POST "/service/rest/v1/repositories/raw/proxy" "admin" "${CURRENT_ADMIN_PASS}" \
        -d "{
            \"name\": \"${repo_name}\",
            \"online\": true,
            \"storage\": {
                \"blobStoreName\": \"${BLOB_STORE_NAME}\",
                \"strictContentTypeValidation\": false
            },
            \"proxy\": {
                \"remoteUrl\": \"${remote_url}\",
                \"contentMaxAge\": -1,
                \"metadataMaxAge\": 1440
            },
            \"httpClient\": {
                \"blocked\": false,
                \"autoBlock\": true,
                \"connection\": { \"retries\": 3, \"timeout\": 60 },
                \"authentication\": {
                    \"type\": \"username\",
                    \"username\": \"${SVC_ACCOUNT_USER}\",
                    \"password\": \"${SVC_ACCOUNT_PASSWORD}\"
                }
            },
            \"negativeCache\": { \"enabled\": true, \"timeToLive\": 1440 }
        }")
    log_info "  -> HTTP ${st}"
}

# ============================================================
# Step 4. Repository 생성 — 역할별 분기
# ============================================================
if [[ "${NEXUS_ROLE}" == "primary" ]]; then
    log_step "4a. application-install-raw-hosted (Primary)"
    create_hosted_repo "${APP_HOSTED_REPO_NAME}"

    log_step "4b. infra-automation-raw-hosted (Primary only)"
    create_hosted_repo "${INFRA_HOSTED_REPO_NAME}"

elif [[ "${NEXUS_ROLE}" == "secondary" ]]; then
    log_step "4. application-install-raw-proxy (Secondary -> ${PRIMARY_NEXUS_URL})"
    if [[ -z "${PRIMARY_NEXUS_URL}" ]]; then
        log_error "PRIMARY_NEXUS_URL 미설정"; exit 1
    fi
    create_proxy_repo "${APP_PROXY_REPO_NAME}" "${PRIMARY_NEXUS_URL}/repository/${APP_HOSTED_REPO_NAME}"

    log_info "infra-automation-raw: Secondary에서는 생성하지 않음 (Primary 178 전용)"
else
    log_error "NEXUS_ROLE 은 primary 또는 secondary: ${NEXUS_ROLE}"; exit 1
fi

# ============================================================
# Step 5. 서비스 계정
# ============================================================
log_step "5. 서비스 계정"
EXISTING_USER=$(nexus_api GET "/service/rest/v1/security/users?userId=${SVC_ACCOUNT_USER}" \
    "admin" "${CURRENT_ADMIN_PASS}" 2>/dev/null || echo "[]")
if echo "${EXISTING_USER}" | grep -q "\"userId\":\"${SVC_ACCOUNT_USER}\""; then
    log_warn "'${SVC_ACCOUNT_USER}' 이미 존재 (skip)"
else
    nexus_api_status POST "/service/rest/v1/security/users" "admin" "${CURRENT_ADMIN_PASS}" \
        -d "{
            \"userId\": \"${SVC_ACCOUNT_USER}\",
            \"firstName\": \"App Install\",
            \"lastName\": \"Service Account\",
            \"emailAddress\": \"svc_app_install@localhost\",
            \"password\": \"${SVC_ACCOUNT_PASSWORD}\",
            \"status\": \"active\",
            \"roles\": [\"nx-anonymous\"]
        }" >/dev/null
    log_info "서비스 계정 생성 완료"
fi

# ============================================================
# Step 6. Webhook (Primary 전용, infra-automation-raw-hosted 대상)
# ============================================================
if [[ "${NEXUS_ROLE}" == "primary" ]]; then
    log_step "6. Webhook (infra-automation-raw-hosted -> Jenkins)"

    register_webhook() {
        local label="$1"; local webhook_url="$2"
        [[ -z "${webhook_url}" ]] && { log_warn "URL 미설정 (${label})"; return 0; }
        EXISTING_CAPS=$(nexus_api GET "/service/rest/v1/capabilities" "admin" "${CURRENT_ADMIN_PASS}" 2>/dev/null || echo "[]")
        echo "${EXISTING_CAPS}" | grep -q "\"url\":\"${webhook_url}\"" && { log_warn "이미 존재 (${label})"; return 0; }
        log_info "Webhook 등록 (${label})..."
        local st=$(nexus_api_status POST "/service/rest/v1/capabilities" "admin" "${CURRENT_ADMIN_PASS}" \
            -d "{
                \"type\": \"webhook.repository\",
                \"enabled\": true,
                \"notes\": \"Infra Automation Webhook - ${label}\",
                \"properties\": {
                    \"repository\": \"${INFRA_HOSTED_REPO_NAME}\",
                    \"names\": \"${WEBHOOK_EVENT_TYPES}\",
                    \"url\": \"${webhook_url}\",
                    \"secret\": \"${WEBHOOK_HMAC_SECRET}\"
                }
            }")
        log_info "  -> HTTP ${st}"
    }

    register_webhook "운영 Master" "${WEBHOOK_URL_PROD:-}"
    register_webhook "개발 Master" "${WEBHOOK_URL_DEV:-}"
else
    log_step "6. Webhook 건너뜀 (Secondary)"
    log_info "Webhook/infra-automation-raw 은 Primary(178) 전용"
fi

# ============================================================
# 결과 요약
# ============================================================
log_info ""
log_info "=== 초기 설정 완료 (${NEXUS_ROLE}) ==="
if [[ "${NEXUS_ROLE}" == "primary" ]]; then
    log_info "  [계열1] ${APP_HOSTED_REPO_NAME} (hosted)"
    log_info "  [계열2] ${INFRA_HOSTED_REPO_NAME} (hosted, webhook -> Jenkins)"
    log_info "  Webhook 운영: ${WEBHOOK_URL_PROD:-미설정}"
    log_info "  Webhook 개발: ${WEBHOOK_URL_DEV:-미설정}"
else
    log_info "  [계열1] ${APP_PROXY_REPO_NAME} (proxy -> ${PRIMARY_NEXUS_URL})"
    log_info "  [계열2] infra-automation-raw: 해당 없음 (Primary 전용)"
fi
log_info "  서비스 계정: ${SVC_ACCOUNT_USER}"
log_info "  Nexus UI: ${NEXUS_URL}"

# --- 결과 JSON ---
mkdir -p "${LOG_DIR}"
cat > "${LOG_DIR}/post_install_result.json" <<EOJSON
{
    "timestamp": "$(date -Iseconds)",
    "hostname": "$(hostname)",
    "ip": "$(hostname -I | awk '{print $1}')",
    "nexus_role": "${NEXUS_ROLE}",
    "repositories": {
        "application_install": "$([[ "${NEXUS_ROLE}" == "primary" ]] && echo "${APP_HOSTED_REPO_NAME}" || echo "${APP_PROXY_REPO_NAME}")",
        "infra_automation": "$([[ "${NEXUS_ROLE}" == "primary" ]] && echo "${INFRA_HOSTED_REPO_NAME}" || echo "N/A")"
    },
    "webhook_target_repo": "$([[ "${NEXUS_ROLE}" == "primary" ]] && echo "${INFRA_HOSTED_REPO_NAME}" || echo "N/A")"
}
EOJSON
log_info "결과: ${LOG_DIR}/post_install_result.json"
