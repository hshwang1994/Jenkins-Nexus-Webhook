#!/usr/bin/env bash
# ============================================================
# validate_nexus_install.sh — Nexus CE 3.91.0 설치 종합 검증
# NEXUS_ROLE 에 따라 primary/secondary 검증 항목이 달라진다.
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
if [[ -f "${SCRIPT_DIR}/../config/install.env" ]]; then
    source "${SCRIPT_DIR}/../config/install.env"
elif [[ -f "${SCRIPT_DIR}/config/install.env" ]]; then
    source "${SCRIPT_DIR}/config/install.env"
fi
set +a

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; WARN=0
check_pass() { echo -e "  ${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
check_fail() { echo -e "  ${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
check_warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; WARN=$((WARN + 1)); }

NEXUS_URL="http://localhost:${NEXUS_HTTP_PORT}"

# 역할별 Repository 이름 결정
if [[ "${NEXUS_ROLE}" == "primary" ]]; then
    REPO_NAME="${RAW_HOSTED_REPO_NAME}"
    REPO_TYPE="hosted"
else
    REPO_NAME="${RAW_PROXY_REPO_NAME}"
    REPO_TYPE="proxy"
fi

echo "============================================================"
echo " Nexus Repository CE ${NEXUS_VERSION} 설치 검증"
echo " 역할: ${NEXUS_ROLE} (${REPO_TYPE})"
echo " 호스트: $(hostname) ($(hostname -I | awk '{print $1}'))"
echo " RAM: $(free -h | awk '/Mem:/{print $2}'), CPU: $(nproc) vCPU"
echo " 시각: $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

# --- [1] 서비스 상태 ---
echo "[1] 서비스 상태"
for svc in "${PG_SERVICE}" nexus nginx; do
    systemctl is-active --quiet "${svc}" 2>/dev/null && check_pass "${svc} active" || check_fail "${svc} inactive"
done

# --- [2] 포트 리스닝 ---
echo ""; echo "[2] 포트 리스닝"
for pi in "${PG_PORT}:PostgreSQL" "${NEXUS_HTTP_PORT}:Nexus" "${NGINX_LISTEN_PORT}:Nginx"; do
    P="${pi%%:*}"; N="${pi##*:}"
    ss -tlnp | grep -q ":${P} " && check_pass "${N} :${P}" || check_fail "${N} :${P}"
done

# --- [3] REST API ---
echo ""; echo "[3] Nexus REST API"
HC=$(curl -s -o /dev/null -w '%{http_code}' "${NEXUS_URL}/service/rest/v1/status" 2>/dev/null || echo "000")
[[ "${HC}" == "200" ]] && check_pass "API 200" || check_fail "API ${HC}"
HC_RW=$(curl -s -o /dev/null -w '%{http_code}' "${NEXUS_URL}/service/rest/v1/status/writable" 2>/dev/null || echo "000")
[[ "${HC_RW}" == "200" ]] && check_pass "Writable" || check_fail "Read-only (${HC_RW})"

# --- [4] admin 인증 ---
echo ""; echo "[4] admin 인증"
AA=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${NEXUS_ADMIN_PASSWORD}" \
    "${NEXUS_URL}/service/rest/v1/security/users" 2>/dev/null || echo "000")
[[ "${AA}" == "200" ]] && check_pass "admin 로그인 OK" || check_fail "admin 실패 (${AA})"

# --- [5] Repository ---
echo ""; echo "[5] Repository (${REPO_NAME}, ${REPO_TYPE})"
RC=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${NEXUS_ADMIN_PASSWORD}" \
    "${NEXUS_URL}/service/rest/v1/repositories/${REPO_NAME}" 2>/dev/null || echo "000")
[[ "${RC}" == "200" ]] && check_pass "${REPO_NAME} 존재" || check_fail "${REPO_NAME} 없음 (${RC})"

# --- [6] 서비스 계정 ---
echo ""; echo "[6] 서비스 계정"
SA=$(curl -s -o /dev/null -w '%{http_code}' -u "${SVC_ACCOUNT_USER}:${SVC_ACCOUNT_PASSWORD}" \
    "${NEXUS_URL}/service/rest/v1/status" 2>/dev/null || echo "000")
[[ "${SA}" == "200" ]] && check_pass "${SVC_ACCOUNT_USER} 인증 OK" || check_fail "서비스 계정 실패 (${SA})"

# --- [7] 파일 업/다운로드 ---
echo ""; echo "[7] 파일 업/다운로드 (${REPO_TYPE})"
TF="/tmp/nexus_test_$(date +%s).txt"
echo "Validation $(date)" > "${TF}"
TA="validation/test_$(date +%s).txt"

if [[ "${NEXUS_ROLE}" == "primary" ]]; then
    # Primary: 업로드 + 다운로드 + 익명 거부
    UC=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:${NEXUS_ADMIN_PASSWORD}" \
        --upload-file "${TF}" "${NEXUS_URL}/repository/${REPO_NAME}/${TA}" 2>/dev/null || echo "000")
    [[ "${UC}" =~ ^(200|201|204)$ ]] && check_pass "업로드 (${UC})" || check_fail "업로드 실패 (${UC})"

    DC=$(curl -s -o /dev/null -w '%{http_code}' -u "${SVC_ACCOUNT_USER}:${SVC_ACCOUNT_PASSWORD}" \
        "${NEXUS_URL}/repository/${REPO_NAME}/${TA}" 2>/dev/null || echo "000")
    [[ "${DC}" == "200" ]] && check_pass "다운로드 (svc)" || check_fail "다운로드 실패 (${DC})"

    AC=$(curl -s -o /dev/null -w '%{http_code}' "${NEXUS_URL}/repository/${REPO_NAME}/${TA}" 2>/dev/null || echo "000")
    [[ "${AC}" == "401" ]] && check_pass "익명 거부 (401)" || check_warn "익명 응답 (${AC})"
else
    # Secondary: proxy 에는 업로드 불가, 다운로드만 (Primary에 파일이 있어야)
    # Primary 에 먼저 업로드
    PRIMARY_UPLOAD=$(curl -s -o /dev/null -w '%{http_code}' \
        -u "admin:${NEXUS_ADMIN_PASSWORD}" --upload-file "${TF}" \
        "${PRIMARY_NEXUS_URL}/repository/${RAW_HOSTED_REPO_NAME}/${TA}" 2>/dev/null || echo "000")
    if [[ "${PRIMARY_UPLOAD}" =~ ^(200|201|204)$ ]]; then
        check_pass "Primary 업로드 (${PRIMARY_UPLOAD})"
        # Proxy 를 통한 다운로드 (on-demand cache)
        sleep 1
        DC=$(curl -s -o /dev/null -w '%{http_code}' -u "${SVC_ACCOUNT_USER}:${SVC_ACCOUNT_PASSWORD}" \
            "${NEXUS_URL}/repository/${REPO_NAME}/${TA}" 2>/dev/null || echo "000")
        [[ "${DC}" == "200" ]] && check_pass "Proxy 다운로드 (${DC}) — on-demand cache" || check_fail "Proxy 다운로드 실패 (${DC})"
    else
        check_warn "Primary 접근 불가 (${PRIMARY_UPLOAD}) — proxy 다운로드 미검증"
    fi

    AC=$(curl -s -o /dev/null -w '%{http_code}' "${NEXUS_URL}/repository/${REPO_NAME}/${TA}" 2>/dev/null || echo "000")
    [[ "${AC}" == "401" ]] && check_pass "익명 거부 (401)" || check_warn "익명 응답 (${AC})"
fi
rm -f "${TF}"

# --- [8] PostgreSQL ---
echo ""; echo "[8] PostgreSQL"
PGC=$(PGPASSWORD="${PG_DB_PASSWORD}" psql -h 127.0.0.1 -p "${PG_PORT}" \
    -U "${PG_DB_USER}" -d "${PG_DB_NAME}" -tAc "SELECT 1;" 2>/dev/null || echo "fail")
[[ "${PGC}" == "1" ]] && check_pass "PG 연결 OK" || check_fail "PG 연결 실패"

TG=$(PGPASSWORD="${PG_DB_PASSWORD}" psql -h 127.0.0.1 -p "${PG_PORT}" \
    -U "${PG_DB_USER}" -d "${PG_DB_NAME}" -tAc \
    "SELECT extname FROM pg_extension WHERE extname='pg_trgm';" 2>/dev/null || echo "")
[[ "${TG}" == "pg_trgm" ]] && check_pass "pg_trgm OK" || check_fail "pg_trgm 없음"

PGV=$(PGPASSWORD="${PG_DB_PASSWORD}" psql -h 127.0.0.1 -p "${PG_PORT}" \
    -U "${PG_DB_USER}" -d "${PG_DB_NAME}" -tAc "SHOW server_version;" 2>/dev/null || echo "")
echo "${PGV}" | grep -q "^16\." && check_pass "PG 버전: ${PGV}" || check_warn "PG 버전: ${PGV}"

# --- [9] Nginx 프록시 ---
echo ""; echo "[9] Nginx 프록시"
NC_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    "http://localhost:${NGINX_LISTEN_PORT}/service/rest/v1/status" 2>/dev/null || echo "000")
[[ "${NC_CODE}" == "200" ]] && check_pass "Nginx 프록시 OK" || check_fail "Nginx 프록시 (${NC_CODE})"

# --- [10] 디스크 여유 ---
echo ""; echo "[10] 디스크 여유"
for pi in "${NEXUS_DATA_DIR}:Nexus-Data" "/opt:Application"; do
    DP="${pi%%:*}"; DN="${pi##*:}"
    if [[ -d "${DP}" ]]; then
        FG=$(df -BG "${DP}" | tail -1 | awk '{gsub("G",""); print $4}')
        [[ "${FG}" -ge 10 ]] && check_pass "${DN}: ${FG}GB" || check_warn "${DN}: ${FG}GB 부족"
    fi
done

# --- [11] JDK 검증 ---
echo ""; echo "[11] Nexus JDK 검증"
NPID=$(pgrep -f "nexus-${NEXUS_VERSION}" 2>/dev/null | head -1 || echo "")
if [[ -n "${NPID}" ]]; then
    NJP=$(readlink -f /proc/${NPID}/exe 2>/dev/null || echo "unknown")
    echo "${NJP}" | grep -qi "sonatype" && check_pass "번들 JDK: ${NJP}" || check_warn "시스템 Java: ${NJP}"
    NJV=$("${NJP}" -version 2>&1 | head -1 || echo "unknown")
    echo "${NJV}" | grep -q '"21\.' && check_pass "JDK 21: ${NJV}" || check_warn "JDK: ${NJV}"
else
    check_fail "Nexus PID 없음"
fi

# --- [12] /nexus-data 권한 ---
echo ""; echo "[12] /nexus-data 권한"
ND_OWNER=$(stat -c '%U' "${NEXUS_DATA_DIR}" 2>/dev/null || echo "unknown")
[[ "${ND_OWNER}" == "${NEXUS_USER}" ]] && check_pass "owner=${ND_OWNER}" || check_fail "owner=${ND_OWNER}"

# --- [13] Webhook (역할별) ---
echo ""; echo "[13] Webhook Capability"
WH_LIST=$(curl -s -u "admin:${NEXUS_ADMIN_PASSWORD}" \
    "${NEXUS_URL}/service/rest/v1/capabilities" 2>/dev/null || echo "[]")
WH_COUNT=$(echo "${WH_LIST}" | grep -c '"webhook.repository"' || echo "0")
if [[ "${NEXUS_ROLE}" == "primary" ]]; then
    [[ "${WH_COUNT}" -gt 0 ]] && check_pass "Webhook ${WH_COUNT}개 등록 (Primary)" || check_warn "Webhook 미등록"
else
    [[ "${WH_COUNT}" -eq 0 ]] && check_pass "Webhook 없음 (Secondary 정상)" || check_warn "Secondary에 Webhook ${WH_COUNT}개 존재 (불필요)"
fi

# --- [14] Nginx 버전 ---
echo ""; echo "[14] Nginx 버전"
command -v nginx &>/dev/null && check_pass "$(nginx -v 2>&1)" || check_fail "Nginx 미설치"

# --- [15] SELinux ---
echo ""; echo "[15] SELinux 설정"
if command -v getsebool &>/dev/null; then
    SE=$(getsebool httpd_can_network_connect 2>/dev/null || echo "off")
    echo "${SE}" | grep -q "on" && check_pass "httpd_can_network_connect=on" || check_warn "${SE}"
else
    check_pass "SELinux 비활성"
fi

# ============================================================
echo ""
echo "============================================================"
echo " 검증 결과 (${NEXUS_ROLE})"
echo "============================================================"
echo -e "  ${GREEN}PASS${NC}: ${PASS}"
echo -e "  ${RED}FAIL${NC}: ${FAIL}"
echo -e "  ${YELLOW}WARN${NC}: ${WARN}"
echo ""
[[ ${FAIL} -eq 0 ]] && echo -e "  ${GREEN}결과: 전체 통과${NC}" || echo -e "  ${RED}결과: ${FAIL}개 실패${NC}"

REPORT_FILE="${LOG_DIR}/validation_$(date +%Y%m%d_%H%M%S).json"
mkdir -p "${LOG_DIR}"
cat > "${REPORT_FILE}" <<EOJSON
{
    "timestamp": "$(date -Iseconds)",
    "hostname": "$(hostname)",
    "ip": "$(hostname -I | awk '{print $1}')",
    "nexus_role": "${NEXUS_ROLE}",
    "nexus_version": "${NEXUS_VERSION}",
    "repository": "${REPO_NAME}",
    "repository_type": "${REPO_TYPE}",
    "ram": "$(free -h | awk '/Mem:/{print $2}')",
    "vcpu": $(nproc),
    "pass": ${PASS},
    "fail": ${FAIL},
    "warn": ${WARN},
    "result": "$(if [[ ${FAIL} -eq 0 ]]; then echo 'PASS'; else echo 'FAIL'; fi)"
}
EOJSON
echo "  리포트: ${REPORT_FILE}"
echo ""
exit $([[ ${FAIL} -eq 0 ]] && echo 0 || echo 1)
