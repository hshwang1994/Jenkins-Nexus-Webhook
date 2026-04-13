# Jenkins Pipeline from SCM 운영 방식

## 원칙

- Jenkinsfile은 Git 저장소(`Jenkins-Nexus-Webhook`)에서 관리
- Jenkins UI에서 Job 수작업 생성은 초기 1회만
- 이후 Jenkinsfile 변경은 Git push → Jenkins 자동 반영

## Job 구성

```
Jenkins → oob-sync (Folder)
├── webhook_dispatch          Pipeline from SCM
├── master_realtime_sync      Pipeline from SCM
├── master_reconcile          Pipeline from SCM
└── master_heartbeat          Pipeline from SCM
```

## Pipeline from SCM 설정

각 Job에 아래 설정 적용:

| 항목 | 값 |
|------|-----|
| SCM | Git |
| Repository URL | `https://github.com/hshwang1994/Jenkins-Nexus-Webhook.git` |
| Branch | `*/main` |
| Script Path | `oob-sync-design/jenkins/Jenkinsfile_{job_name}` |
| Lightweight checkout | true |

### Script Path 매핑

| Job | Script Path |
|-----|-------------|
| webhook_dispatch | `oob-sync-design/jenkins/Jenkinsfile_webhook_dispatch` |
| master_realtime_sync | `oob-sync-design/jenkins/Jenkinsfile_master_realtime_sync` |
| master_reconcile | `oob-sync-design/jenkins/Jenkinsfile_master_reconcile` |
| master_heartbeat | `oob-sync-design/jenkins/Jenkinsfile_master_heartbeat` |

## 초기 설정 절차

```bash
# 1. Jenkins Groovy Console에서 폴더 + Job 생성
# (또는 Jenkins CLI / REST API)

# 2. 각 Job에서 Pipeline → Definition → Pipeline script from SCM 선택
# 3. Git URL + Branch + Script Path 설정
# 4. Save → Build Now (trigger 등록 목적)
```

## sync_config.yml 배포

`/etc/oob-sync/sync_config.yml`은 Jenkins Job 외부 설정이므로 별도 배포:

```bash
# Master에 배포
scp oob-sync-design/config/sync_config.yml \
  cloviradmin@10.100.64.198:/etc/oob-sync/sync_config.yml

# Agent 12대에도 배포 (heartbeat에서 참조)
for IP in 186 189 172 173 174 177 187 188 190 192 193 194; do
  scp oob-sync-design/config/sync_config.yml \
    cloviradmin@10.100.64.$IP:/etc/oob-sync/sync_config.yml
done
```

## Nexus 설치 Job (별도)

Nexus 설치용 Job은 `oob-sync` 폴더와 분리:

```
Jenkins
├── oob-sync/              OOB 동기화 운영 Job
│   └── (위 4개 Job)
└── nexus-install/         Nexus 설치 자동화 (필요 시)
    └── install-nexus      Pipeline from SCM
                           Script Path: nexus-install/jenkins/Jenkinsfile
```
