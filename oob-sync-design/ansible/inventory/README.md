# Inventory 구조

OOB 파일 동기화는 **정적 inventory 파일을 사용하지 않는다.**
매 실행마다 Jenkins Master 가 동적 inventory 를 만들어 Ansible 에 넘긴다.

## 동적 생성 방식

1. `nodesByLabel("${location_code} && redfish")` 로 후보군 조회
2. online 필터 + `exclude_node_names` 제외
3. 대표/대상 OOB 에이전트 선정
4. inventory JSON 생성 → 환경변수 `INVENTORY_JSON` 에 주입

```json
{
  "event_id": "evt-20260409-0001",
  "location_code": "ich",
  "repository_name": "bios-firmware",
  "asset_path": "dell/r760/2.18.1.BIN",
  "download_url": "https://nexus.icheon.ops.internal/repository/bios-firmware/dell/r760/2.18.1.BIN",
  "checksum_algorithm": "sha256",
  "checksum_value": "e3b0c44298fc1c14...",
  "file_size_bytes": 18446744073,
  "operation_type": "upload",
  "selected_seed_node": "ich-oob-01",
  "selected_peer_nodes": ["ich-oob-02"],
  "selection_reason": "파일을 이미 보유한 노드를 대표 OOB 에이전트로 선정했습니다."
}
```

Ansible 은 `lookup('env','INVENTORY_JSON') | from_json` 으로 읽어 처리한다.
