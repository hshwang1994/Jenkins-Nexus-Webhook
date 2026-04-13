#!/usr/bin/env python3
"""
Nexus REST API 로 repository asset 목록을 페이지네이션 조회한다.

사용법:
  python3 list_nexus_assets.py \
    --nexus-url http://nexus.example.com \
    --repository oob-firmware \
    --username "$NEXUS_USER" \
    --password "$NEXUS_PASS" \
    --mode partial \
    --output /tmp/nexus_assets.json

partial 모드: 최근 24h 변경분만 필터링
full 모드: 전체 asset
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone


def build_auth_header(username: str, password: str) -> str:
    """Basic Auth 헤더 값을 생성한다."""
    credentials = f"{username}:{password}"
    encoded = base64.b64encode(credentials.encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def fetch_page(
    nexus_url: str,
    repository: str,
    auth_header: str,
    continuation_token=None,
) -> dict:
    """Nexus REST API 에서 한 페이지의 asset 목록을 가져온다."""
    url = f"{nexus_url.rstrip('/')}/service/rest/v1/assets?repository={repository}"
    if continuation_token:
        url += f"&continuationToken={continuation_token}"

    request = urllib.request.Request(url)
    request.add_header("Authorization", auth_header)
    request.add_header("Accept", "application/json")

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        print(
            f"[Nexus asset 목록 조회 실패]\n"
            f"\n"
            f"발생상황:\n"
            f"Nexus REST API 호출이 HTTP {exc.code} 으로 실패했습니다.\n"
            f"\n"
            f"원인:\n"
            f"인증 실패, 권한 부족, repository 이름 오류 중 하나입니다.\n"
            f"\n"
            f"문제:\n"
            f"주기 점검이 Nexus 기대 상태를 파악할 수 없습니다.\n"
            f"\n"
            f"조치방법:\n"
            f"1. Jenkins Credentials(nexus-oob-sync-readonly) 의 유효성을 확인합니다.\n"
            f"2. repository 이름({repository})이 정확한지 확인합니다.\n"
            f"3. Nexus 측 서비스 계정 권한(read)을 확인합니다.",
            file=sys.stderr,
        )
        sys.exit(1)
    except urllib.error.URLError as exc:
        print(
            f"[Nexus 접속 불가]\n"
            f"\n"
            f"발생상황:\n"
            f"Nexus ({nexus_url}) 에 접속할 수 없습니다.\n"
            f"\n"
            f"원인:\n"
            f"네트워크 단절, DNS 미해석, Nexus 서비스 중지 중 하나입니다.\n"
            f"\n"
            f"문제:\n"
            f"주기 점검이 진행될 수 없습니다.\n"
            f"\n"
            f"조치방법:\n"
            f"1. OOB Agent 에서 curl 로 Nexus URL 에 직접 접근해 원인을 식별합니다.\n"
            f"2. 네트워크/DNS/Nexus 상태를 복구합니다.\n"
            f"3. 복구 후 다음 주기 점검이 자동으로 재시도합니다.",
            file=sys.stderr,
        )
        sys.exit(1)


def fetch_all_assets(nexus_url, repository, auth_header):
    """모든 asset 을 페이지네이션으로 수집한다."""
    all_assets = []
    continuation_token = None

    while True:
        page = fetch_page(nexus_url, repository, auth_header, continuation_token)
        items = page.get("items", [])
        for item in items:
            all_assets.append(
                {
                    "path": item.get("path", ""),
                    "downloadUrl": item.get("downloadUrl", ""),
                    "checksum": item.get("checksum", {}),
                    "fileSize": item.get("fileSize", 0),
                    "lastModified": item.get("lastModified", ""),
                }
            )
        continuation_token = page.get("continuationToken")
        if not continuation_token:
            break

    return all_assets


def filter_recent(assets, hours=24):
    """최근 N시간 이내에 변경된 asset 만 필터링한다."""
    cutoff = datetime.now(timezone.utc) - timedelta(hours=hours)
    recent = []
    for asset in assets:
        last_modified = asset.get("lastModified", "")
        if not last_modified:
            recent.append(asset)
            continue
        try:
            # Nexus 는 ISO 8601 형식 (예: 2026-04-09T12:00:00.000+00:00)
            modified_dt = datetime.fromisoformat(last_modified.replace("Z", "+00:00"))
            if modified_dt >= cutoff:
                recent.append(asset)
        except (ValueError, TypeError):
            # 파싱 실패 시 안전하게 포함
            recent.append(asset)
    return recent


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Nexus repository asset 목록을 페이지네이션으로 조회한다."
    )
    parser.add_argument("--nexus-url", required=True, help="Nexus base URL")
    parser.add_argument("--repository", required=True, help="Nexus repository name")
    parser.add_argument(
        "--username",
        default=os.environ.get("NEXUS_USER", ""),
        help="Nexus username (또는 NEXUS_USER 환경변수)",
    )
    parser.add_argument(
        "--password",
        default=os.environ.get("NEXUS_PASS", ""),
        help="Nexus password (또는 NEXUS_PASS 환경변수)",
    )
    parser.add_argument(
        "--mode",
        choices=["partial", "full"],
        default="full",
        help="partial: 최근 24h 변경분만, full: 전체",
    )
    parser.add_argument(
        "--recent-hours",
        type=int,
        default=24,
        help="partial 모드에서 최근 N시간 기준 (기본: 24)",
    )
    parser.add_argument(
        "--output",
        default="-",
        help="출력 파일 경로 (기본: stdout)",
    )

    args = parser.parse_args()

    if not args.username or not args.password:
        print(
            "[인증 정보 누락]\n"
            "\n"
            "발생상황:\n"
            "Nexus 인증에 필요한 username/password 가 제공되지 않았습니다.\n"
            "\n"
            "원인:\n"
            "--username/--password 인자 또는 NEXUS_USER/NEXUS_PASS 환경변수가 비어 있습니다.\n"
            "\n"
            "문제:\n"
            "Nexus REST API 를 호출할 수 없습니다.\n"
            "\n"
            "조치방법:\n"
            "1. Jenkins withCredentials 블록에서 NEXUS_USER, NEXUS_PASS 가 설정되어 있는지 확인합니다.\n"
            "2. 또는 명령줄 인자로 --username, --password 를 전달합니다.",
            file=sys.stderr,
        )
        sys.exit(1)

    auth_header = build_auth_header(args.username, args.password)
    assets = fetch_all_assets(args.nexus_url, args.repository, auth_header)

    if args.mode == "partial":
        assets = filter_recent(assets, hours=args.recent_hours)

    result = json.dumps(assets, ensure_ascii=False, indent=2)

    if args.output == "-":
        print(result)
    else:
        output_dir = os.path.dirname(args.output)
        if output_dir:
            os.makedirs(output_dir, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as fout:
            fout.write(result)
        print(f"asset 목록 {len(assets)}건을 {args.output} 에 저장했습니다.", file=sys.stderr)


if __name__ == "__main__":
    main()
