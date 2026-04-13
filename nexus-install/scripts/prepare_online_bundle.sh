#!/usr/bin/env bash
# ============================================================
# prepare_online_bundle.sh
# 인터넷 연결 가능한 머신에서 오프라인 번들을 준비한다.
#
# 용도: 에어갭 환경에 전달할 모든 패키지/아카이브를 한 디렉터리에 수집
# 실행: sudo bash prepare_online_bundle.sh
# 결과: /opt/nexus-bundle/ 디렉터리에 모든 파일 수집
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

# --- 사전 조건 ---
if [[ $EUID -ne 0 ]]; then
    log_error "root 권한이 필요합니다. sudo 로 실행하세요."
    exit 1
fi

BUNDLE="${BUNDLE_DIR}"
mkdir -p "${BUNDLE}"/{nexus,postgresql,nginx,system,scripts,config}

log_info "=== 오프라인 번들 준비 시작 ==="
log_info "번들 경로: ${BUNDLE}"

# ============================================================
# 1. Nexus 아카이브 다운로드
# ============================================================
log_info "[1/6] Nexus Repository ${NEXUS_VERSION} 다운로드..."
if [[ -f "${BUNDLE}/nexus/${NEXUS_ARCHIVE}" ]]; then
    log_warn "이미 존재: ${NEXUS_ARCHIVE} (skip)"
else
    curl -fSL -o "${BUNDLE}/nexus/${NEXUS_ARCHIVE}" "${NEXUS_DOWNLOAD_URL}"
    log_info "다운로드 완료: ${NEXUS_ARCHIVE}"
fi

# SHA256 체크섬 다운로드
if [[ -f "${BUNDLE}/nexus/${NEXUS_ARCHIVE}.sha256" ]]; then
    log_warn "이미 존재: ${NEXUS_ARCHIVE}.sha256 (skip)"
else
    curl -fSL -o "${BUNDLE}/nexus/${NEXUS_ARCHIVE}.sha256" \
        "${NEXUS_DOWNLOAD_URL}.sha256"
    log_info "체크섬 다운로드 완료"
fi

# 체크섬 검증
log_info "체크섬 검증..."
cd "${BUNDLE}/nexus"
if sha256sum -c "${NEXUS_ARCHIVE}.sha256" 2>/dev/null; then
    log_info "체크섬 OK"
else
    log_error "체크섬 불일치! 파일이 손상되었을 수 있습니다."
    exit 1
fi
cd -

# ============================================================
# 2. PostgreSQL 16 RPM 다운로드
# ============================================================
log_info "[2/6] PostgreSQL ${PG_VERSION} RPM 다운로드..."

# PGDG 리포지터리 RPM
PGDG_RPM="pgdg-redhat-repo-latest.noarch.rpm"
if [[ ! -f "${BUNDLE}/postgresql/${PGDG_RPM}" ]]; then
    curl -fSL -o "${BUNDLE}/postgresql/${PGDG_RPM}" \
        "https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/${PGDG_RPM}"
fi

# PGDG 리포 설치 (임시) → RPM 다운로드
dnf install -y "${BUNDLE}/postgresql/${PGDG_RPM}" 2>/dev/null || true
dnf -qy module disable postgresql 2>/dev/null || true

log_info "PostgreSQL ${PG_VERSION} 패키지 다운로드 (의존성 포함)..."
dnf download --resolve --destdir="${BUNDLE}/postgresql/" \
    "postgresql${PG_VERSION}" \
    "postgresql${PG_VERSION}-server" \
    "postgresql${PG_VERSION}-contrib" \
    "postgresql${PG_VERSION}-libs"

log_info "PostgreSQL RPM 수: $(ls "${BUNDLE}/postgresql/"*.rpm 2>/dev/null | wc -l)"

# ============================================================
# 3. Nginx RPM 다운로드
# ============================================================
log_info "[3/6] Nginx RPM 다운로드..."
dnf download --resolve --destdir="${BUNDLE}/nginx/" nginx

log_info "Nginx RPM 수: $(ls "${BUNDLE}/nginx/"*.rpm 2>/dev/null | wc -l)"

# ============================================================
# 4. 시스템 유틸리티 RPM (누락 가능성 대비)
# ============================================================
log_info "[4/6] 시스템 유틸리티 RPM 다운로드..."
dnf download --resolve --destdir="${BUNDLE}/system/" \
    tar gzip curl wget rsync policycoreutils-python-utils \
    2>/dev/null || log_warn "일부 유틸리티 RPM 다운로드 실패 (이미 설치됨일 수 있음)"

# [FIX] OpenSSL RPM 다운로드 (PG16 contrib 의존성: OPENSSL_3.4.0 필요)
log_info "OpenSSL RPM 다운로드 (PG16 contrib 의존성)..."
dnf download --resolve --destdir="${BUNDLE}/system/" \
    openssl openssl-libs \
    2>/dev/null || log_warn "OpenSSL RPM 다운로드 실패"

# ============================================================
# 5. 스크립트/설정 파일 복사
# ============================================================
log_info "[5/6] 스크립트/설정 파일 복사..."
cp -a "${SCRIPT_DIR}"/*.sh "${BUNDLE}/scripts/" 2>/dev/null || true
cp -a "${SCRIPT_DIR}"/*.py "${BUNDLE}/scripts/" 2>/dev/null || true
cp -a "${SCRIPT_DIR}/../config/"* "${BUNDLE}/config/"

# ============================================================
# 6. 번들 매니페스트 생성
# ============================================================
log_info "[6/6] 번들 매니페스트 생성..."
cat > "${BUNDLE}/MANIFEST.txt" <<MANIFEST
# ============================================================
# Nexus Repository CE ${NEXUS_VERSION} 오프라인 설치 번들
# 생성일: $(date '+%Y-%m-%d %H:%M:%S')
# 생성 호스트: $(hostname)
# ============================================================

[Nexus]
$(ls -lh "${BUNDLE}/nexus/" 2>/dev/null)

[PostgreSQL]
$(ls -lh "${BUNDLE}/postgresql/"*.rpm 2>/dev/null | wc -l) RPM files

[Nginx]
$(ls -lh "${BUNDLE}/nginx/"*.rpm 2>/dev/null | wc -l) RPM files

[System]
$(ls -lh "${BUNDLE}/system/"*.rpm 2>/dev/null | wc -l) RPM files

[Total Size]
$(du -sh "${BUNDLE}" | cut -f1)
MANIFEST

log_info "=== 번들 준비 완료 ==="
log_info "번들 경로: ${BUNDLE}"
log_info "번들 크기: $(du -sh "${BUNDLE}" | cut -f1)"
log_info ""
log_info "다음 단계: 번들을 에어갭 서버로 전송하세요."
log_info "  scp -r ${BUNDLE} ${SSH_USER}@<target>:${BUNDLE}"
log_info "  또는 USB/ISO 미디어를 사용하세요."
