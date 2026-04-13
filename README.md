# Jenkins-Nexus-Webhook

Nexus CE 3.91.0 멀티사이트 설치 + OOB 파일 동기화 자동화

## 아키텍처

```
178 이천 Primary Nexus
├── application-install-raw-hosted (일반 배포)
├── infra-automation-raw-hosted (포털 업로드, OOB 동기화 원본)
│   └── Webhook → Jenkins Master (198 운영 / 199 개발)
│
├── 179 용인: application-install-raw-proxy (on-demand cache)
└── 180 청주: application-install-raw-proxy (on-demand cache)

OOB 파일 배포 흐름:
  포털 → 178 Nexus 업로드
  → Webhook → Jenkins Master
  → Master: 178에서 다운로드
  → Master → seed 3대 SCP (ich/chj/yi 각 1대)
  → seed → same-region peer rsync fan-out
```

## 디렉터리 구조

```
Jenkins-Nexus-Webhook/
├── nexus-install/          Nexus CE 설치 자동화
│   ├── config/             install.env + 템플릿
│   ├── scripts/            설치/구성/검증 스크립트
│   └── docs/               설치 가이드, 검증 보고서
│
└── oob-sync-design/        OOB 파일 동기화 설계
    ├── config/             sync_config.yml (SSOT)
    ├── jenkins/            4개 Jenkinsfile (Pipeline from SCM)
    ├── ansible/            playbook, group_vars, scripts
    └── docs/               설계서, 운영가이드, 테스트시나리오
```

## 서버 구성

| IP | 호스트명 | 역할 |
|----|---------|------|
| 10.100.64.178 | nexus-ich | Primary Nexus (이천) |
| 10.100.64.179 | nexus-chj | Secondary Nexus (용인, proxy) |
| 10.100.64.180 | nexus-yi | Secondary Nexus (청주, proxy) |
| 10.100.64.198 | nexus-jenkins-ops | 운영 Jenkins Master |
| 10.100.64.199 | nexus-jenkins-dev | 개발 Jenkins Master |

OOB Agent: 각 Master 하위 6대 (ich 2, chj 2, yi 2)

## Jenkins Job 구조

```
oob-sync/
├── webhook_dispatch          Webhook 수신 + HMAC 검증 + 트리거
├── master_realtime_sync      실시간 동기화 (upload/delete)
├── master_reconcile          주기 점검 (partial 30분 / full 03시)
└── master_heartbeat          Agent 상태 점검 (15분)
```

Jenkins Pipeline from SCM: `oob-sync-design/jenkins/Jenkinsfile_*`

## 핵심 원칙

- **Source of Truth**: `178 infra-automation-raw-hosted`
- Jenkins는 오케스트레이터 및 중간 전달 허브
- OOB Agent는 Nexus에 직접 접근하지 않음
- Regional seed 구조: 지역별 대표 1대 → same-region peer fan-out
- Cross-region fan-out 금지

## 검증 상태

| 항목 | 결과 |
|------|------|
| Upload E2E (12대 Agent) | PASS |
| Delete E2E (quarantine) | PASS |
| Reconcile partial/full | PASS |
| Heartbeat | PASS |
| Nexus 2계열 (app/infra) | PASS |
| Webhook 실수신 | PASS |

## 운영 전 필수 변경

| 항목 | 현재값 | 조치 |
|------|--------|------|
| 비밀번호 | `Goodmit0802!` | 운영 환경 고유값 |
| SSH key | `StrictHostKeyChecking=no` | known_hosts 사전 등록 |
| Webhook token | `infra-automation-nexus-webhook` | 필요 시 변경 |
