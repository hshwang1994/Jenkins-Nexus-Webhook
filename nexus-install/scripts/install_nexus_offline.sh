#!/usr/bin/env bash
# ============================================================
# install_nexus_offline.sh
# 에어갭 RHEL 서버에서 Nexus CE 3.91.0 을 오프라인 설치한다.
#
# 순서: 시스템 RPM → OpenSSL → PG16 → Nexus 추출 → JDK 강제 →
#       systemd → Nginx+SELinux → Nexus 시작 → 방화벽
# 실행: sudo bash install_nexus_offline.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# install.env 탐색 (set -a 로 envsubst 용 export)
set -a
if [[ -f "${SCRIPT_DIR}/../config/install.env" ]]; then
    source "${SCRIPT_DIR}/../config/install.env"
elif [[ -f "${SCRIPT_DIR}/config/install.env" ]]; then
    source "${SCRIPT_DIR}/config/install.env"
else
    echo "[ERROR] install.env 를 찾을 수 없습니다."
    exit 1
fi
set +a

# --- 색상 ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $(date '+%H:%M:%S') ====== $* ======"; }

# --- 로그 ---
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

# --- 사전 조건 ---
if [[ $EUID -ne 0 ]]; then log_error "root 권한이 필요합니다."; exit 1; fi
if [[ ! -d "${BUNDLE_DIR}" ]]; then
    log_error "번들 디렉터리가 없습니다: ${BUNDLE_DIR}"
    exit 1
fi

log_info "=== Nexus Repository CE ${NEXUS_VERSION} 오프라인 설치 시작 ==="
log_info "서버 RAM: $(free -h | awk '/Mem:/{print $2}'), CPU: $(nproc) vCPU"
log_info "로그: ${LOG_FILE}"

# ============================================================
# 1/9. 시스템 RPM + OpenSSL 설치
# ============================================================
log_step "1/9 시스템 유틸리티 RPM 설치"

if ls "${BUNDLE_DIR}/system/"*.rpm 1>/dev/null 2>&1; then
    dnf install -y --disablerepo='*' "${BUNDLE_DIR}/system/"*.rpm 2>/dev/null || \
        log_warn "일부 시스템 RPM 이미 설치됨"
else
    log_warn "시스템 RPM 없음 (skip)"
fi

# OpenSSL 업데이트 (PG16 contrib 의존성: OPENSSL_3.4.0 필요)
if ls "${BUNDLE_DIR}/system/openssl"*.rpm 1>/dev/null 2>&1; then
    log_info "OpenSSL RPM 업데이트 (PG16 contrib 의존성)..."
    dnf install -y --disablerepo='*' "${BUNDLE_DIR}/system/openssl"*.rpm 2>/dev/null || \
        log_warn "OpenSSL 이미 최신"
elif dnf repolist --enabled 2>/dev/null | grep -q "baseos\|appstream"; then
    log_info "OpenSSL 온라인 업데이트..."
    dnf update -y openssl openssl-libs 2>/dev/null || log_warn "OpenSSL 업데이트 실패"
fi

# ============================================================
# 2/9. PostgreSQL 16 설치 및 초기화
# ============================================================
log_step "2/9 PostgreSQL ${PG_VERSION} 설치"

dnf -qy module disable postgresql 2>/dev/null || true
dnf install -y --disablerepo='*' "${BUNDLE_DIR}/postgresql/"*.rpm 2>/dev/null || \
    log_warn "일부 PostgreSQL RPM 이미 설치됨"

if [[ ! -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
    log_info "PostgreSQL initdb..."
    "/usr/pgsql-${PG_VERSION}/bin/postgresql-${PG_VERSION}-setup" initdb
else
    log_warn "PostgreSQL 이미 초기화됨 (skip)"
fi

# pg_hba.conf
PG_HBA="${PG_DATA_DIR}/pg_hba.conf"
cp "${PG_HBA}" "${PG_HBA}.bak.$(date +%s)"
cat > "${PG_HBA}" <<'PGHBA'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             all                                     peer
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
PGHBA

# postgresql.conf (install.env 변수 사용)
PG_CONF="${PG_DATA_DIR}/postgresql.conf"
log_info "postgresql.conf 최적화 (shared_buffers=${PG_SHARED_BUFFERS}, work_mem=${PG_WORK_MEM})..."
sed -i "s/^#*max_connections.*/max_connections = ${PG_MAX_CONNECTIONS}/" "${PG_CONF}"
sed -i "s/^#*listen_addresses.*/listen_addresses = 'localhost'/" "${PG_CONF}"
sed -i "s/^#*shared_buffers.*/shared_buffers = ${PG_SHARED_BUFFERS}/" "${PG_CONF}"
sed -i "s/^#*work_mem.*/work_mem = ${PG_WORK_MEM}/" "${PG_CONF}"
sed -i "s/^#*effective_cache_size.*/effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE}/" "${PG_CONF}"

systemctl enable "${PG_SERVICE}"
systemctl start "${PG_SERVICE}"
systemctl is-active "${PG_SERVICE}" || { log_error "PostgreSQL 시작 실패"; exit 1; }

# DB / 사용자 / pg_trgm
log_info "Nexus DB/사용자 생성..."
sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOSQL || log_warn "DB/사용자 이미 존재할 수 있음"
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${PG_DB_USER}') THEN
        CREATE ROLE ${PG_DB_USER} WITH LOGIN PASSWORD '${PG_DB_PASSWORD}';
    END IF;
END \$\$;

SELECT 'CREATE DATABASE ${PG_DB_NAME} OWNER ${PG_DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${PG_DB_NAME}')
\gexec

GRANT ALL PRIVILEGES ON DATABASE ${PG_DB_NAME} TO ${PG_DB_USER};
EOSQL

sudo -u postgres psql -d "${PG_DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" || {
    log_error "pg_trgm 설치 실패"; exit 1
}
log_info "PostgreSQL ${PG_VERSION} 완료"

# ============================================================
# 3/9. Nexus OS 사용자 생성
# ============================================================
log_step "3/9 Nexus 시스템 사용자"

if id "${NEXUS_USER}" &>/dev/null; then
    log_warn "사용자 ${NEXUS_USER} 이미 존재"
else
    useradd --system --no-create-home --shell /bin/false "${NEXUS_USER}"
    log_info "사용자 ${NEXUS_USER} 생성"
fi

# ============================================================
# 4/9. Nexus 아카이브 추출 + 설정 배포
# ============================================================
log_step "4/9 Nexus 아카이브 추출"

NEXUS_ARCHIVE_PATH="${BUNDLE_DIR}/nexus/${NEXUS_ARCHIVE}"
[[ -f "${NEXUS_ARCHIVE_PATH}" ]] || { log_error "아카이브 없음: ${NEXUS_ARCHIVE_PATH}"; exit 1; }

if [[ -d "${NEXUS_REAL_DIR}" ]]; then
    log_warn "기존 디렉터리 백업..."
    mv "${NEXUS_REAL_DIR}" "${NEXUS_REAL_DIR}.bak.$(date +%s)"
fi

log_info "추출 중..."
mkdir -p "${NEXUS_INSTALL_BASE}"
tar xzf "${NEXUS_ARCHIVE_PATH}" -C "${NEXUS_INSTALL_BASE}"

# 추출 디렉터리 확인
EXTRACTED_DIR=$(ls -d "${NEXUS_INSTALL_BASE}/nexus-${NEXUS_VERSION}" 2>/dev/null || \
    ls -d "${NEXUS_INSTALL_BASE}/nexus-"* 2>/dev/null | head -1)
[[ -n "${EXTRACTED_DIR}" ]] || { log_error "추출된 디렉터리 없음"; exit 1; }

# 심볼릭 링크
ln -sfn "${EXTRACTED_DIR}" "${NEXUS_INSTALL_DIR}"
log_info "심볼릭 링크: ${NEXUS_INSTALL_DIR} -> ${EXTRACTED_DIR}"

# 데이터 디렉터리
mkdir -p "${NEXUS_DATA_DIR}"/{etc/fabric,log,tmp}

# --- JDK 21 강제 사용 설정 ---
# Nexus 3.91.0 번들 JDK 경로 탐색 (버전별로 구조가 다름)
#   3.70 이전: ${EXTRACTED_DIR}/jre
#   3.91.0:    ${EXTRACTED_DIR}/jdk/temurin_*/jdk-*/bin/java  (depth 5)
BUNDLED_JDK=""
# 방법 1: 전통적 jre 디렉터리
if [[ -d "${EXTRACTED_DIR}/jre" ]]; then
    BUNDLED_JDK="${EXTRACTED_DIR}/jre"
fi
# 방법 2: Nexus 3.91.0+ — jdk/temurin_*/jdk-*/bin/java 구조 (depth 4)
if [[ -z "${BUNDLED_JDK}" ]] && [[ -d "${EXTRACTED_DIR}/jdk" ]]; then
    _JAVA_BIN=$(find "${EXTRACTED_DIR}/jdk" -maxdepth 5 -name "java" -path "*/bin/java" -type f 2>/dev/null | head -1)
    if [[ -n "${_JAVA_BIN}" ]]; then
        BUNDLED_JDK=$(cd "$(dirname "${_JAVA_BIN}")/.." && pwd)
    fi
fi
# 방법 3: 전체 검색 fallback
if [[ -z "${BUNDLED_JDK}" || ! -d "${BUNDLED_JDK}" ]]; then
    _JAVA_BIN=$(find "${EXTRACTED_DIR}" -maxdepth 8 -name "java" -path "*/bin/java" -type f 2>/dev/null | head -1)
    if [[ -n "${_JAVA_BIN}" ]]; then
        BUNDLED_JDK=$(cd "$(dirname "${_JAVA_BIN}")/.." && pwd)
    fi
fi
if [[ -d "${BUNDLED_JDK}" ]]; then
    log_info "번들 JDK 경로: ${BUNDLED_JDK}"
    BUNDLED_JAVA_VER=$("${BUNDLED_JDK}/bin/java" -version 2>&1 | head -1)
    log_info "번들 JDK 버전: ${BUNDLED_JAVA_VER}"
else
    log_warn "번들 JDK 경로를 자동 탐지하지 못함. Nexus 기본 탐색에 의존합니다."
fi

# nexus 실행 스크립트에서 INSTALL4J_JAVA_HOME_OVERRIDE 설정으로 번들 JDK 강제
if [[ -d "${BUNDLED_JDK}" ]]; then
    log_info "INSTALL4J_JAVA_HOME_OVERRIDE 로 번들 JDK 21 강제..."
    # nexus.rc 에 환경변수 추가
    cat > "${EXTRACTED_DIR}/bin/nexus.rc" <<NEXUSRC
run_as_user="${NEXUS_USER}"
INSTALL4J_JAVA_HOME_OVERRIDE="${BUNDLED_JDK}"
NEXUSRC
else
    echo "run_as_user=\"${NEXUS_USER}\"" > "${EXTRACTED_DIR}/bin/nexus.rc"
fi

# 설정 파일 배포
log_info "nexus.vmoptions 배포..."
envsubst < "${BUNDLE_DIR}/config/nexus.vmoptions.tpl" > "${EXTRACTED_DIR}/bin/nexus.vmoptions"

log_info "nexus.properties 배포..."
envsubst < "${BUNDLE_DIR}/config/nexus.properties.tpl" > "${NEXUS_DATA_DIR}/etc/nexus.properties"

log_info "nexus-store.properties 배포..."
envsubst < "${BUNDLE_DIR}/config/nexus-store.properties.tpl" > "${NEXUS_DATA_DIR}/etc/fabric/nexus-store.properties"

# 소유권
chown -R "${NEXUS_USER}:${NEXUS_GROUP}" "${EXTRACTED_DIR}"
chown -R "${NEXUS_USER}:${NEXUS_GROUP}" "${NEXUS_DATA_DIR}"

log_info "Nexus 추출 + 설정 완료"

# ============================================================
# 5/9. systemd 서비스 등록
# ============================================================
log_step "5/9 systemd 서비스 등록"

envsubst < "${BUNDLE_DIR}/config/nexus.service.tpl" > /etc/systemd/system/nexus.service
systemctl daemon-reload
systemctl enable nexus
log_info "nexus.service 등록"

# ============================================================
# 6/9. Nginx 설치 + SELinux + 기본 server 비활성화
# ============================================================
log_step "6/9 Nginx 설치"

if ls "${BUNDLE_DIR}/nginx/"*.rpm 1>/dev/null 2>&1; then
    dnf install -y --disablerepo='*' "${BUNDLE_DIR}/nginx/"*.rpm 2>/dev/null || \
        log_warn "Nginx 이미 설치됨"
else
    log_warn "Nginx RPM 없음 (skip)"
fi

[[ -f /etc/nginx/conf.d/default.conf ]] && \
    mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.bak 2>/dev/null || true

# nginx.conf 기본 server 블록 비활성화
if grep -q "^    server {" /etc/nginx/nginx.conf 2>/dev/null; then
    log_info "nginx.conf 기본 server 블록 비활성화..."
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%s)
    sed -i '/^    server {/,/^    }/s/^/#/' /etc/nginx/nginx.conf
fi

# Nexus 프록시 설정
if [[ -f "${BUNDLE_DIR}/config/nexus_nginx.conf" ]]; then
    cp "${BUNDLE_DIR}/config/nexus_nginx.conf" /etc/nginx/conf.d/nexus.conf
elif [[ -f "${BUNDLE_DIR}/config/nginx.conf.tpl" ]]; then
    envsubst '${NEXUS_HTTP_PORT} ${NGINX_LISTEN_PORT} ${NGINX_SERVER_NAME}' \
        < "${BUNDLE_DIR}/config/nginx.conf.tpl" > /etc/nginx/conf.d/nexus.conf
fi

# SELinux
if command -v setsebool &>/dev/null; then
    log_info "SELinux httpd_can_network_connect=on..."
    setsebool -P httpd_can_network_connect 1 || log_warn "setsebool 실패"
fi

systemctl enable nginx
systemctl start nginx || log_warn "Nginx 시작 실패 (Nexus 기동 후 재시도)"
log_info "Nginx 완료"

# ============================================================
# 7/9. Nexus 시작 + 부팅 대기
# ============================================================
log_step "7/9 Nexus 서비스 시작"

systemctl start nexus
log_info "Nexus 시작 요청. 초기 부팅 대기..."

MAX_WAIT=300; ELAPSED=0; INTERVAL=10
while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        "http://localhost:${NEXUS_HTTP_PORT}/service/rest/v1/status" 2>/dev/null || echo "000")
    [[ "${HTTP_CODE}" == "200" ]] && { log_info "Nexus 정상 기동 (HTTP 200)"; break; }
    log_info "대기... (${ELAPSED}s/${MAX_WAIT}s, HTTP=${HTTP_CODE})"
    sleep ${INTERVAL}; ELAPSED=$((ELAPSED + INTERVAL))
done
[[ ${ELAPSED} -ge ${MAX_WAIT} ]] && { log_error "Nexus ${MAX_WAIT}s 내 미기동"; exit 1; }

systemctl restart nginx 2>/dev/null || true

# ============================================================
# 8/9. 방화벽 포트 개방
# ============================================================
log_step "8/9 방화벽 포트 개방"

if systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=80/tcp 2>/dev/null || true
    firewall-cmd --permanent --add-port=${NEXUS_HTTP_PORT}/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    log_info "방화벽 80, ${NEXUS_HTTP_PORT} 개방"
else
    log_warn "firewalld 비활성"
fi

# ============================================================
# 9/9. JDK 21 강제 사용 검증
# ============================================================
log_step "9/9 Nexus 런타임 JDK 검증"

NEXUS_PID=$(pgrep -f "nexus-${NEXUS_VERSION}" | head -1 || echo "")
if [[ -n "${NEXUS_PID}" ]]; then
    NEXUS_JAVA_PATH=$(readlink -f /proc/${NEXUS_PID}/exe 2>/dev/null || echo "unknown")
    NEXUS_JAVA_VER=$(strings /proc/${NEXUS_PID}/cmdline 2>/dev/null | head -1 || echo "")
    log_info "Nexus PID: ${NEXUS_PID}"
    log_info "Nexus Java 경로: ${NEXUS_JAVA_PATH}"

    if echo "${NEXUS_JAVA_PATH}" | grep -q "nexus-${NEXUS_VERSION}"; then
        log_info "번들 JDK 사용 확인: OK"
    else
        log_warn "시스템 Java 를 사용 중일 수 있음. 경로 확인 필요: ${NEXUS_JAVA_PATH}"
    fi

    # Java 버전 직접 확인
    ACTUAL_JAVA=$("${NEXUS_JAVA_PATH}" -version 2>&1 | head -1 || echo "unknown")
    log_info "실행 중인 Java: ${ACTUAL_JAVA}"
    if echo "${ACTUAL_JAVA}" | grep -q '"21\.'; then
        log_info "JDK 21 확인: OK"
    else
        log_warn "JDK 21 이 아닐 수 있음: ${ACTUAL_JAVA}"
    fi
else
    log_warn "Nexus PID 탐지 실패. 서비스 상태를 확인하세요."
fi

# ============================================================
# 초기 admin 비밀번호
# ============================================================
ADMIN_PASS_FILE="${NEXUS_DATA_DIR}/admin.password"
if [[ -f "${ADMIN_PASS_FILE}" ]]; then
    log_info "초기 admin 비밀번호 파일 존재 (configure_nexus_post_install.sh 에서 변경됨)"
fi

log_info "=== Nexus Repository CE ${NEXUS_VERSION} 설치 완료 ==="
log_info "  PostgreSQL: $(systemctl is-active ${PG_SERVICE})"
log_info "  Nexus:      $(systemctl is-active nexus)"
log_info "  Nginx:      $(systemctl is-active nginx)"
log_info "다음: sudo bash ${SCRIPT_DIR}/configure_nexus_post_install.sh"
