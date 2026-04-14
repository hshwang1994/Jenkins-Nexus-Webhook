# Nexus CE Blob Store 운영 절차

## 핵심 원칙

**asset 삭제 = 즉시 디스크 회수 아님.**

Nexus CE에서 REST API `DELETE /assets/{id}`로 asset을 삭제하면:
1. asset 메타데이터는 즉시 삭제
2. blob 파일은 **soft-delete 마킹**만 됨
3. "Cleanup unused asset blobs" scheduled task가 주기적으로 soft-delete blob 처리
4. 하지만 **blob 파일의 물리적 삭제가 즉시 되지 않는 경우가 발생**
5. 대용량 파일 반복 업로드/삭제 시 blob store가 누적 증가

## 실측 사례

| 상태 | active assets | blob store 크기 | 디스크 여유 |
|------|-------------|----------------|-----------|
| 테스트 후 | **0개** | **42GB** | **3GB** |
| 수동 정리 후 | 0개 | **1.1MB** | **45GB** |

## 디스크 회수 절차

### 방법 1: Nexus Admin UI Task 실행

1. Nexus Admin 로그인
2. Settings > System > Tasks
3. "Cleanup unused raw blobs from nexus" 클릭 > **Run**
4. "Cleanup service" 클릭 > **Run**
5. 10분 대기 후 디스크 확인

### 방법 2: 수동 blob 정리 (UI task로 회수 안 될 때)

```bash
# 1. active asset이 0인지 먼저 확인
curl -s -u admin:PASSWORD \
  http://NEXUS:8081/service/rest/v1/search/assets?repository=REPO_NAME | \
  python3 -c "import sys,json; print(len(json.load(sys.stdin)['items']))"
# 0이면 안전하게 진행 가능

# 2. Nexus 중지
sudo systemctl stop nexus

# 3. orphaned blob 삭제
sudo rm -rf /nexus-data/blobs/default/content/20*/
sudo rm -rf /nexus-data/blobs/default/content/directpath/

# 4. Nexus 재시작
sudo systemctl start nexus
# 30-60초 대기 후 HTTP 200 확인
```

### 주의사항

- active asset이 있는 상태에서 blob 수동 삭제 금지
- 삭제 전 반드시 `search/assets` API로 active asset 수 확인
- Nexus 중지 후 정리 → 재시작 순서 준수

## 운영 권장

| 항목 | 권장 |
|------|------|
| Cleanup task 실행 주기 | 일 1회 (기본 설정 유지) |
| 디스크 여유 모니터링 | blob store 디렉터리 크기 주기 점검 |
| 대용량 파일 삭제 후 | 수동으로 Cleanup task Run 권장 |
| 50GB 운영 시 | blob store를 별도 마운트(NFS/LV)로 분리 필수 |

## 5GB 반복 시 blob 증가량

| 회차 | blob 누적 | 디스크 여유 |
|------|----------|-----------|
| 시작 | 1.1MB | 45GB |
| 1회 후 | +5GB | 40GB |
| 2회 후 | +10GB | 35GB |
| 3회 후 | +16GB | 30GB |

5GB 파일 3회 업로드/삭제 후 **blob 16GB 누적** (각 회차 약 5GB씩, soft-delete 잔존).
