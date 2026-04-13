#!/usr/bin/env bash
# ============================================================
# rollback_nexus_install.sh
# Nexus CE 3.91.0 설치를 롤백(완전 제거)한다.
#
# 제거 범위:
#   1. Nexus 서비스 중지 및 제거
#   2. Nginx 설정 제거
#   3. PostgreSQL 데이터베이스/사용자 제거 (선택)
#   4. Nexus 디렉터리 제거
#   5. OS 사용자 제거
#
# 실행: sudo bash rollback_nexus_install.sh [--full]
#   --full: PostgreSQL 까지 완전 제거
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/install.env"

# --- 색상 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $(date '+%H:%M:%S') ====== $* ======"; }

FULL_ROLLBACK="false"
if [[ "${1:-}" == "--full" ]]; then
    FULL_ROLLBACK="true"
fi

# --- 사전 조건 ---
if [[ $EUID -ne 0 ]]; then
    log_error "root 권한이 필요합니다."
    exit 1
fi

echo ""
echo "============================================================"
echo " Nexus Repository CE ${NEXUS_VERSION} 롤백"
if [[ "${FULL_ROLLBACK}" == "true" ]]; then
    echo " 모드: 완전 제거 (PostgreSQL 포함)"
else
    echo " 모드: 부분 제거 (PostgreSQL 유지)"
fi
echo "============================================================"
echo ""

read -r -p "정말 롤백하시겠습니까? (y/N): " CONFIRM
if [[ "${CONFIRM}" != "y" && "${CONFIRM}" != "Y" ]]; then
    log_info "롤백 취소"
    exit 0
fi

# ============================================================
# Step 1. Nexus 서비스 중지 및 제거
# ============================================================
log_step "1/5 Nexus 서비스 중지"

if systemctl is-active --quiet nexus 2>/dev/null; then
    systemctl stop nexus
    log_info "Nexus 서비스 중지 완료"
else
    log_warn "Nexus 서비스 이미 중지됨"
fi
systemctl disable nexus 2>/dev/null || true
rm -f /etc/systemd/system/nexus.service
systemctl daemon-reload
log_info "nexus.service 제거 완료"

# ============================================================
# Step 2. Nginx 설정 제거
# ============================================================
log_step "2/5 Nginx 설정 제거"

rm -f /etc/nginx/conf.d/nexus.conf
if [[ -f /etc/nginx/conf.d/default.conf.bak ]]; then
    mv /etc/nginx/conf.d/default.conf.bak /etc/nginx/conf.d/default.conf
fi
systemctl restart nginx 2>/dev/null || log_warn "Nginx 재시작 실패"
log_info "Nginx Nexus 설정 제거 완료"

# ============================================================
# Step 3. PostgreSQL 데이터베이스/사용자 제거
# ============================================================
log_step "3/5 PostgreSQL 정리"

if [[ "${FULL_ROLLBACK}" == "true" ]]; then
    log_info "PostgreSQL 데이터베이스/사용자 제거..."
    sudo -u postgres psql -v ON_ERROR_STOP=1 <<EOSQL 2>/dev/null || log_warn "DB 제거 실패 (이미 없을 수 있음)"
DROP DATABASE IF EXISTS ${PG_DB_NAME};
DROP ROLE IF EXISTS ${PG_DB_USER};
EOSQL
    log_info "데이터베이스 '${PG_DB_NAME}' 및 사용자 '${PG_DB_USER}' 제거 완료"
else
    log_warn "PostgreSQL 유지 (--full 옵션으로 완전 제거 가능)"
fi

# ============================================================
# Step 4. Nexus 디렉터리 제거
# ============================================================
log_step "4/5 Nexus 디렉터리 제거"

# 데이터 디렉터리 백업 여부 확인
if [[ -d "${NEXUS_DATA_DIR}" ]]; then
    BACKUP_PATH="${NEXUS_DATA_DIR}.rollback.$(date +%Y%m%d_%H%M%S)"
    log_info "데이터 디렉터리 백업: ${BACKUP_PATH}"
    mv "${NEXUS_DATA_DIR}" "${BACKUP_PATH}"
fi

# 애플리케이션 디렉터리 제거
if [[ -L "${NEXUS_INSTALL_DIR}" ]]; then
    REAL_DIR=$(readlink -f "${NEXUS_INSTALL_DIR}")
    rm -f "${NEXUS_INSTALL_DIR}"
    rm -rf "${REAL_DIR}"
    log_info "Nexus 애플리케이션 디렉터리 제거: ${REAL_DIR}"
elif [[ -d "${NEXUS_INSTALL_DIR}" ]]; then
    rm -rf "${NEXUS_INSTALL_DIR}"
    log_info "Nexus 애플리케이션 디렉터리 제거: ${NEXUS_INSTALL_DIR}"
fi

# sonatype-work 제거
if [[ -d "/opt/sonatype-work" ]]; then
    rm -rf /opt/sonatype-work
    log_info "/opt/sonatype-work 제거 완료"
fi

# ============================================================
# Step 5. OS 사용자 제거
# ============================================================
log_step "5/5 OS 사용자 제거"

if id "${NEXUS_USER}" &>/dev/null; then
    userdel "${NEXUS_USER}" 2>/dev/null || log_warn "사용자 제거 실패"
    log_info "사용자 '${NEXUS_USER}' 제거 완료"
else
    log_warn "사용자 '${NEXUS_USER}' 이미 없음"
fi

# ============================================================
# 결과
# ============================================================
log_info "=== 롤백 완료 ==="
log_info ""
log_info "제거 항목:"
log_info "  [O] Nexus 서비스 (systemd)"
log_info "  [O] Nginx Nexus 프록시 설정"
if [[ "${FULL_ROLLBACK}" == "true" ]]; then
    log_info "  [O] PostgreSQL DB/사용자"
else
    log_info "  [X] PostgreSQL DB/사용자 (유지)"
fi
log_info "  [O] Nexus 디렉터리 (데이터 백업됨)"
log_info "  [O] nexus OS 사용자"
log_info ""
if [[ -n "${BACKUP_PATH:-}" ]]; then
    log_info "데이터 백업 위치: ${BACKUP_PATH}"
    log_info "백업이 불필요하면 수동으로 삭제하세요: rm -rf ${BACKUP_PATH}"
fi
log_info ""
log_info "재설치: sudo bash install_nexus_offline.sh"
