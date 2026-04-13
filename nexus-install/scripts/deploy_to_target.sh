#!/usr/bin/env bash
# ============================================================
# deploy_to_target.sh
# 번들을 대상 서버로 전송하고 설치를 실행한다.
#
# 용도: 빌드 서버(178)에서 대상 서버(179, 180)로 원격 배포
# 실행: bash deploy_to_target.sh <target_ip> [--install] [--configure] [--validate]
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../config/install.env"

# --- 색상 ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }

# --- 인자 파싱 ---
if [[ $# -lt 1 ]]; then
    echo "사용법: $0 <target_ip> [--install] [--configure] [--validate] [--rollback]"
    echo ""
    echo "예시:"
    echo "  $0 10.100.64.179                          # 번들 전송만"
    echo "  $0 10.100.64.179 --install                # 전송 + 설치"
    echo "  $0 10.100.64.179 --install --configure    # 전송 + 설치 + 초기 설정"
    echo "  $0 10.100.64.179 --install --configure --validate  # 전체 파이프라인"
    echo "  $0 10.100.64.179 --rollback               # 롤백"
    exit 1
fi

TARGET_IP="$1"
shift

DO_INSTALL="false"
DO_CONFIGURE="false"
DO_VALIDATE="false"
DO_ROLLBACK="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)    DO_INSTALL="true" ;;
        --configure)  DO_CONFIGURE="true" ;;
        --validate)   DO_VALIDATE="true" ;;
        --rollback)   DO_ROLLBACK="true" ;;
        *) log_error "알 수 없는 옵션: $1"; exit 1 ;;
    esac
    shift
done

SSH_CMD="sshpass -p '${SSH_PASSWORD}' ssh -o StrictHostKeyChecking=no ${SSH_USER}@${TARGET_IP}"
SCP_CMD="sshpass -p '${SSH_PASSWORD}' scp -o StrictHostKeyChecking=no"

# sshpass 존재 확인
if ! command -v sshpass &>/dev/null; then
    log_error "sshpass 가 설치되어 있지 않습니다."
    log_error "설치: dnf install -y sshpass"
    exit 1
fi

# ============================================================
# 롤백 모드
# ============================================================
if [[ "${DO_ROLLBACK}" == "true" ]]; then
    log_info "=== ${TARGET_IP} 롤백 시작 ==="
    eval "${SSH_CMD}" "sudo bash ${BUNDLE_DIR}/scripts/rollback_nexus_install.sh --full" <<< "y"
    log_info "=== 롤백 완료 ==="
    exit 0
fi

# ============================================================
# 번들 전송
# ============================================================
log_info "=== ${TARGET_IP} 번들 전송 시작 ==="

# 대상 서버에 번들 디렉터리 생성
eval "${SSH_CMD}" "sudo mkdir -p ${BUNDLE_DIR}"

# rsync 전송
log_info "rsync 전송 중... (시간이 걸릴 수 있습니다)"
sshpass -p "${SSH_PASSWORD}" rsync -avz --progress \
    -e "ssh -o StrictHostKeyChecking=no" \
    "${BUNDLE_DIR}/" \
    "${SSH_USER}@${TARGET_IP}:${BUNDLE_DIR}/"

log_info "번들 전송 완료"

# ============================================================
# 설치
# ============================================================
if [[ "${DO_INSTALL}" == "true" ]]; then
    log_info "=== ${TARGET_IP} 설치 시작 ==="
    eval "${SSH_CMD}" "sudo bash ${BUNDLE_DIR}/scripts/install_nexus_offline.sh"
    log_info "=== 설치 완료 ==="
fi

# ============================================================
# 초기 설정
# ============================================================
if [[ "${DO_CONFIGURE}" == "true" ]]; then
    log_info "=== ${TARGET_IP} 초기 설정 시작 ==="
    eval "${SSH_CMD}" "sudo bash ${BUNDLE_DIR}/scripts/configure_nexus_post_install.sh"
    log_info "=== 초기 설정 완료 ==="
fi

# ============================================================
# 검증
# ============================================================
if [[ "${DO_VALIDATE}" == "true" ]]; then
    log_info "=== ${TARGET_IP} 검증 시작 ==="
    eval "${SSH_CMD}" "bash ${BUNDLE_DIR}/scripts/validate_nexus_install.sh"
    log_info "=== 검증 완료 ==="
fi

log_info "=== ${TARGET_IP} 배포 파이프라인 완료 ==="
