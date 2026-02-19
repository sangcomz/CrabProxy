# Crab Proxy One-Shot 전환 계획서 v2 (현재 -> 3단계 일괄)

## 1) 목적

- 목표: 현재 `FFI 인프로세스` 구조에서 바로 `3단계(daemon + IPC + MCP)` 목표 상태까지 한 번에 전환한다.
- 결과: `CrabProxyMacApp`, `crabctl(CLI)`, `crab-mcp(MCP)`가 동일한 `crabd` 엔진 인스턴스를 제어한다.
- 제약: 사용자 설치 경험은 유지한다. 최종 사용자는 Rust 설치가 필요 없어야 한다.

## 2) 현재와 목표 상태

### 현재 (As-Is)

```
┌─────────────────────────────────────────────┐
│              CrabProxyMacApp                │
│  ┌──────────────┐   ┌────────────────────┐  │
│  │ProxyViewModel│──▶│ RustProxyEngine    │  │
│  │ (SwiftUI)    │   │ (FFI → libcrab_mitm)│  │
│  └──────────────┘   └────────────────────┘  │
│         │                                    │
│  ┌──────────────┐                            │
│  │ HelperClient │──XPC──▶ CrabProxyHelper   │
│  │              │        (PF/인증서, root)   │
│  └──────────────┘                            │
└─────────────────────────────────────────────┘
```

- 앱이 Rust 라이브러리를 FFI로 직접 호출해 프록시 엔진을 제어
- UI, 엔진 제어 경계가 프로세스 내부에 강하게 결합
- CLI/MCP가 동일 상태를 안전하게 공유하기 어려움
- 상태 영속화: 앱의 `UserDefaults`에 룰/설정 저장
- 권한 작업: `CrabProxyHelper` (XPC, privileged) 가 PF 제어/인증서 설치 담당

### 목표 (To-Be: 3단계)

```
┌──────────────┐  ┌──────────┐  ┌──────────┐
│CrabProxyMacApp│  │ crabctl  │  │ crab-mcp │
│   (UI)       │  │  (CLI)   │  │(MCP서버) │
└──────┬───────┘  └────┬─────┘  └────┬─────┘
       │               │              │
       └───────┬───────┴──────────────┘
               │  UDS + JSON-RPC 2.0
        ┌──────▼──────┐
        │    crabd    │
        │ (Rust daemon)│
        │  엔진+상태   │
        └──────┬──────┘
               │ XPC (권한 작업만)
        ┌──────▼──────────┐
        │CrabProxyHelper  │
        │(PF/인증서, root)│
        └─────────────────┘
```

- 엔진: `crabd` (Rust daemon, 별도 프로세스)
- 제어: `Unix Domain Socket + JSON-RPC 2.0`
- 클라이언트:
  - `CrabProxyMacApp` (UI)
  - `crabctl` (운영/자동화 CLI)
  - `crab-mcp` (IDE/AI 연동용 MCP 서버)
- 단일 진실 소스: 룰/상태/로그는 daemon이 authoritative
- 권한 작업: `CrabProxyHelper` (XPC)는 유지, `crabd`가 필요 시 호출

## 3) 범위

### 포함

- Cargo workspace 구성 및 `crabd`, `crabctl`, `crab-mcp`, `crab-ipc` 크레이트 추가
- `crabd` daemon 구현 (엔진 호스팅, IPC 서버, 상태 영속화)
- 앱 엔진 제어를 FFI → IPC 클라이언트로 전환
- 룰, 상태, 로그 스트림, replay를 daemon API로 통합
- 기존 `UserDefaults` 설정을 daemon 상태로 마이그레이션
- `CrabProxyHelper` (XPC)와 `crabd` 간 연동 정의
- 앱 번들에 daemon/cli/mcp 바이너리 포함 및 코드사인 반영
- 버전 협상, 재연결, 장애 복구 UX 구현
- 다중 클라이언트 동시 접근 정책

### 제외

- 원격 네트워크 제어 API 공개
- 멀티 호스트 분산 오케스트레이션
- 1차 릴리즈에서 FFI 코드 완전 삭제 (비상 fallback 용도로 유지 가능)

## 4) 아키텍처 결정

### IPC 기본 사항

- Transport: Unix Domain Socket
- RPC protocol: JSON-RPC 2.0
- 소켓 경로: `~/Library/Application Support/CrabProxy/crabd.sock`
- 버전 정책: `protocol_version` 핸드셰이크(최소/최대 지원 범위 검증)

### 인증/권한

- 소켓 파일 권한 `0600` (소유자만 접근 가능)
- 앱이 생성한 세션 토큰 파일 검증
- 토큰 경로: `~/Library/Application Support/CrabProxy/session.token`

### 로그 스트리밍

- 제어/명령 채널과 로그 스트리밍 채널을 **단일 UDS 연결** 위에서 JSON-RPC notification으로 전송
- `daemon.logs.subscribe` 호출 시 daemon이 해당 연결에 `daemon.logs.event` notification을 push
- 재연결 시 로그 유실 구간 복구: `daemon.logs.tail(after_id)` 로 마지막 수신 ID 이후 로그 백필
- Backpressure 정책:
  - daemon 측 클라이언트별 전송 큐 최대 크기: 10,000건
  - 큐 초과 시 오래된 로그부터 drop, `logs.overflow` notification으로 클라이언트에 알림
  - 클라이언트는 overflow 수신 시 `logs.tail`로 누락분 보충

### 상태 영속화

- daemon authoritative: 룰/설정은 daemon이 소유
- 저장 위치: `~/Library/Application Support/CrabProxy/state.json`
- 포맷: JSON (사람이 읽을 수 있고, 디버깅 용이)
- 저장 시점: 상태 변경 시 debounce (500ms) 후 디스크 기록
- 앱은 캐시 및 뷰 전용, daemon 재시작 시 파일에서 복원

### 다중 클라이언트 동시 접근

- 기본 정책: **Last-Write-Wins**
- 모든 상태 변경 시 daemon이 연결된 전체 클라이언트에 `state.changed` notification 브로드캐스트
- 클라이언트는 notification 수신 시 최신 상태를 `get` 호출로 갱신
- 향후 필요 시 낙관적 잠금(revision 기반) 도입 가능하도록 응답에 `revision` 필드 예약

### CrabProxyHelper (XPC) 연동

- `CrabProxyHelper`는 기존과 동일하게 유지 (PF 제어, 인증서 설치/제거는 root 권한 필요)
- 변경점: XPC 호출 주체가 앱 → `crabd`로 이동
  - `crabd`가 PF 활성화/비활성화, 인증서 설치/제거를 XPC로 요청
  - 앱은 UI에서 daemon API(`daemon.enable_pf`, `daemon.install_cert` 등)를 호출
- XPC 보안 검증: `CrabProxyHelper`의 code-signing 검증 대상에 `crabd` 바이너리 추가
- 대안 검토: `crabd`가 직접 XPC를 호출하기 어려운 경우, 앱이 XPC 브리지 역할 유지

### JSON-RPC 라이브러리 선택

- 1순위: **자체 경량 구현** (UDS + JSON-RPC 2.0 notification)
  - 이유: 외부 프레임워크 대비 바이너리 크기 최소화, UDS notification 스트리밍 커스터마이즈 용이
  - `serde_json` + `tokio` 기반으로 구현, `crab-ipc` 크레이트에 격리
- 2순위: `jsonrpsee` (Parity)
  - 이유: 성숙도 높으나 의존성 트리가 크고, UDS notification 커스터마이즈 유연성이 제한적
- Gate 0에서 프로토타입 구현 후 최종 결정

## 5) Daemon 생명주기

### 시작 (Launch)

| 시나리오 | 시작 주체 | 방식 |
|---------|----------|------|
| 앱 실행 시 | CrabProxyMacApp | 앱이 `crabd` 프로세스를 직접 spawn, 소켓 연결 대기 |
| CLI 단독 사용 | 사용자 | `crabctl start-daemon` 또는 `crabd` 직접 실행 |
| MCP 단독 사용 | crab-mcp | `crabd`가 이미 실행 중이어야 함 (미실행 시 에러 + 안내) |
| 부팅 시 자동 시작 | launchd (선택) | `~/Library/LaunchAgents/com.sangcomz.crabd.plist` 등록 (향후) |

### 연결

- 앱/CLI/MCP가 시작 시 소켓에 연결 시도
- 연결 실패 시: 재시도 (최대 5회, 지수 백오프 100ms~3s)
- daemon이 이미 실행 중이면 기존 인스턴스에 연결
- 버전 핸드셰이크 실패 시: 연결 거부 + "앱/daemon 업데이트 필요" 안내

### 종료

- `daemon.shutdown` RPC 호출 시 graceful shutdown
- 앱 종료 시: daemon은 계속 실행 (CLI/MCP 접근 유지)
- 모든 클라이언트 연결 해제 후 일정 시간(5분) 경과 시 자동 종료 (설정 가능)
- `crabd --no-auto-exit` 플래그로 자동 종료 비활성화 가능

### 장애 복구

- 앱이 daemon 프로세스 crash 감지 시: 자동 재시작 + 재연결 + 상태 파일에서 복원
- 소켓 파일 잔존 (stale socket): 연결 실패 시 PID 파일 확인 → 프로세스 없으면 소켓 삭제 후 재시작
- PID 파일 경로: `~/Library/Application Support/CrabProxy/crabd.pid`

## 6) API 계약 (v2)

### 시스템

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `system.ping` | 헬스체크 | - |
| `system.version` | 프로토콜/엔진 버전 조회 | - |
| `system.handshake` | 버전 협상 + 세션 수립 | `{protocol_version, client_type}` |

### 프록시 제어

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `proxy.start` | 프록시 시작 | - |
| `proxy.stop` | 프록시 중지 | - |
| `proxy.status` | 실행 상태 조회 | - |
| `proxy.replay` | 캡처된 요청 재전송 | `{request_id}` |

### 네트워크 설정

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `config.set_listen` | 리슨 주소/포트 설정 | `{addr, port}` |
| `config.get_listen` | 리슨 주소/포트 조회 | - |
| `config.set_transparent` | 투명 프록시 설정 | `{enabled, port}` |
| `config.get_transparent` | 투명 프록시 상태 조회 | - |

### 검사/스로틀

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `config.set_inspect` | 바디 검사 활성화/비활성화 | `{enabled}` |
| `config.get_inspect` | 바디 검사 상태 조회 | - |
| `config.set_throttle` | 스로틀 전체 설정 | `{enabled, latency_ms, downstream_bps, upstream_bps, only_selected_hosts, selected_hosts[]}` |
| `config.get_throttle` | 스로틀 상태 조회 | - |

### 클라이언트 접근 제어

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `config.set_client_allowlist` | 허용 IP 목록 전체 교체 | `{enabled, ips[]}` |
| `config.get_client_allowlist` | 허용 IP 목록 조회 | - |

### 룰 관리

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `rules.apply` | 룰 전체 교체 적용 | `{allow[], map_local[], map_remote[], status_rewrite[]}` |
| `rules.get` | 현재 룰 전체 조회 | - |

### CA 인증서

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `ca.load` | CA 인증서/키 로드 | `{cert_path, key_path}` |
| `ca.generate` | CA 인증서 생성 | `{algorithm?, output_dir}` |
| `ca.status` | CA 로드 상태 조회 | - |

### 시스템 통합 (XPC 브리지)

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `system.enable_pf` | PF 활성화 (XPC 경유) | `{pf_conf, cert_path}` |
| `system.disable_pf` | PF 비활성화 (XPC 경유) | - |
| `system.install_cert` | 시스템 인증서 설치 (XPC 경유) | `{cert_path}` |
| `system.remove_cert` | 시스템 인증서 제거 (XPC 경유) | `{common_name}` |
| `system.check_cert` | 시스템 인증서 확인 (XPC 경유) | `{common_name}` |

### 로그

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `logs.subscribe` | 실시간 로그 스트림 구독 | `{filter?}` |
| `logs.unsubscribe` | 로그 스트림 구독 해제 | - |
| `logs.tail` | 과거 로그 조회 (백필) | `{after_id?, limit?}` |
| `logs.clear` | 로그 초기화 | - |

### Notification (daemon → client, 단방향)

| 이벤트 | 설명 |
|--------|------|
| `logs.event` | 실시간 로그 항목 |
| `logs.overflow` | 로그 큐 오버플로우 알림 |
| `state.changed` | 상태/설정 변경 알림 (다중 클라이언트 동기화) |
| `proxy.status_changed` | 프록시 시작/중지 상태 변경 |

### Daemon 제어

| 메서드 | 설명 | 파라미터 |
|--------|------|----------|
| `daemon.shutdown` | daemon graceful 종료 | - |
| `daemon.doctor` | 진단 정보 수집 | - |

### 공통 응답 형식

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "revision": 42,
    "data": { ... }
  }
}
```

- `revision`: 상태 변경 카운터 (향후 낙관적 잠금 확장 예약)

### 에러 코드 체계

| 코드 | 이름 | 설명 |
|------|------|------|
| -32700 | Parse error | JSON 파싱 실패 |
| -32600 | Invalid request | 잘못된 JSON-RPC 요청 |
| -32601 | Method not found | 존재하지 않는 메서드 |
| -32602 | Invalid params | 파라미터 오류 |
| -32603 | Internal error | 내부 오류 |
| 1 | PROXY_ALREADY_RUNNING | 이미 실행 중 |
| 2 | PROXY_NOT_RUNNING | 실행 중이 아님 |
| 3 | CA_NOT_LOADED | CA 미로드 |
| 4 | CA_ERROR | CA 관련 오류 |
| 5 | RULE_INVALID | 룰 검증 실패 |
| 6 | VERSION_MISMATCH | 프로토콜 버전 불일치 |
| 7 | XPC_UNAVAILABLE | XPC helper 사용 불가 |
| 8 | IO_ERROR | 파일/네트워크 I/O 오류 |

## 7) 리포 구조 (Cargo Workspace)

### 변경 전

```
CrabProxy/
├── crab-mitm/
│   ├── Cargo.toml          # 단일 크레이트
│   ├── src/
│   │   ├── lib.rs
│   │   ├── main.rs
│   │   ├── ffi.rs
│   │   ├── proxy.rs
│   │   ├── ...
│   │   └── proxy/
│   └── include/
│       └── crab_mitm.h
└── CrabProxyMacApp/
```

### 변경 후

```
CrabProxy/
├── Cargo.toml                  # workspace root (신규)
├── crab-mitm/
│   ├── Cargo.toml              # 프록시 엔진 라이브러리
│   ├── src/
│   │   ├── lib.rs
│   │   ├── ffi.rs              # FFI (fallback 유지)
│   │   ├── proxy.rs
│   │   ├── ca.rs
│   │   ├── config.rs
│   │   ├── rules.rs
│   │   └── proxy/
│   └── include/
│       └── crab_mitm.h
├── crab-ipc/                   # 공통 IPC 프로토콜 (신규)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── protocol.rs         # JSON-RPC 메시지 정의
│       ├── codec.rs            # UDS 프레임 인코딩/디코딩
│       ├── server.rs           # IPC 서버 (daemon용)
│       ├── client.rs           # IPC 클라이언트 (앱/CLI/MCP용)
│       └── error.rs            # 에러 코드 및 타입
├── crabd/                      # daemon 바이너리 (신규)
│   ├── Cargo.toml              # depends: crab-mitm, crab-ipc
│   └── src/
│       ├── main.rs             # 진입점, 시그널 핸들링
│       ├── state.rs            # 상태 관리 및 영속화
│       ├── session.rs          # 클라이언트 세션/연결 관리
│       └── xpc_bridge.rs       # CrabProxyHelper XPC 연동
├── crabctl/                    # CLI 바이너리 (신규)
│   ├── Cargo.toml              # depends: crab-ipc
│   └── src/
│       └── main.rs
├── crab-mcp/                   # MCP 서버 바이너리 (신규)
│   ├── Cargo.toml              # depends: crab-ipc
│   └── src/
│       ├── main.rs
│       └── tools.rs            # MCP tool 정의
└── CrabProxyMacApp/
    └── Sources/
        └── CrabProxyMacApp/
            ├── ProxyViewModel.swift    # FFI 호출 → IPC 호출로 교체
            ├── RustProxyEngine.swift   # fallback 용도로 축소
            ├── DaemonClient.swift      # IPC 클라이언트 (신규)
            ├── DaemonLifecycle.swift    # daemon 시작/감시 (신규)
            └── ...
```

### Workspace Cargo.toml

```toml
[workspace]
members = [
    "crab-mitm",
    "crab-ipc",
    "crabd",
    "crabctl",
    "crab-mcp",
]
resolver = "2"
```

## 8) 상태 마이그레이션 전략

### 현재 상태 저장 방식

앱 `ProxyViewModel`이 `UserDefaults`에 저장하는 항목:
- 룰: `allowRules`, `mapLocalRules`, `mapRemoteRules`, `statusRewriteRules`
- 스로틀: `throttleEnabled`, `throttleLatencyMs`, `throttleDownstreamKbps`, `throttleUpstreamKbps`, `throttleOnlySelectedHosts`, `throttleSelectedHosts`
- 검사: `inspectBodies`
- 네트워크: `allowLANConnections`, `lanClientAllowlist`

### 마이그레이션 흐름

1. 앱 업데이트 후 첫 실행 시 `engine_mode` 확인
2. `engine_mode=daemon`이고 `state.json`이 없으면:
   - `UserDefaults`에서 기존 설정 읽기
   - daemon 연결 후 `rules.apply`, `config.set_*` 호출로 설정 이전
   - daemon이 `state.json`에 저장
   - `UserDefaults`에 `migrated_to_daemon=true` 마킹
3. 이후 앱은 `UserDefaults`에 설정을 쓰지 않음 (daemon이 authoritative)

### Daemon 상태 파일 형식

```json
{
  "version": 1,
  "listen": { "addr": "127.0.0.1", "port": 9090 },
  "inspect": { "enabled": true },
  "throttle": {
    "enabled": false,
    "latency_ms": 0,
    "downstream_bps": 0,
    "upstream_bps": 0,
    "only_selected_hosts": false,
    "selected_hosts": []
  },
  "client_allowlist": { "enabled": false, "ips": [] },
  "transparent": { "enabled": false, "port": 0 },
  "rules": {
    "allow": [],
    "map_local": [],
    "map_remote": [],
    "status_rewrite": []
  },
  "ca": { "cert_path": "...", "key_path": "..." }
}
```

- `version` 필드로 포맷 호환성 관리
- 하위 호환: 새 필드 추가 시 기본값 사용, 알 수 없는 필드 무시

## 9) 앱 관점 변화

### 장점

- 앱/CLI/MCP가 같은 엔진 상태를 공유 가능
- 앱 재시작과 엔진 생명주기를 분리해 안정성 향상
- MCP 연동이 자연스러워져 IDE/AI 자동화 확장 용이
- daemon 재시작 시 상태 자동 복원

### 단점/비용

- IPC/프로세스 관리 복잡도 증가
- 버전 불일치, 소켓 권한, 재연결 시나리오 대응 필요
- 초기 마이그레이션 기간 동안 QA 범위 확대
- XPC 호출 경로 변경에 따른 코드사인 검증 업데이트

### 성능 영향

- 제어/로그 경로에 IPC 오버헤드는 존재 (로컬 UDS이므로 < 1ms)
- 실제 프록시 데이터 경로는 daemon 내부 처리 중심이므로 체감 저하는 제한적
- 로그 폭주 구간은 배치 전송/backpressure로 제어

## 10) 구현 워크스트림

### WS-A: Cargo Workspace 및 IPC 프로토콜

- Workspace 루트 `Cargo.toml` 생성
- `crab-ipc` 크레이트: JSON-RPC 메시지 타입, UDS 코덱, 서버/클라이언트 공통 코드
- 에러 코드 체계 및 타임아웃 표준화
- 버전 협상/호환성 검사
- JSON-RPC 라이브러리 프로토타입 (자체 구현 vs `jsonrpsee` 비교)

### WS-B: Rust daemon 코어

- `crabd` 진입점 및 런타임/상태 머신
- 기존 proxy/rules/inspect/throttle/replay를 daemon 상태로 통합
- `state.json` 영속화 및 시작 시 복원
- 클라이언트 세션 관리, 다중 연결, notification 브로드캐스트
- 자동 종료 타이머 (클라이언트 부재 시)
- PID 파일 관리 및 stale socket 정리
- 크래시 복구/헬스체크/진단 로그

### WS-C: Mac App 전환

- `DaemonClient.swift`: IPC 클라이언트 구현
- `DaemonLifecycle.swift`: daemon spawn, 감시, crash 복구
- `ProxyViewModel`의 엔진 호출을 IPC 호출로 교체
- 연결 상태 배지, 재시도, 실패 시 가이드 메시지
- `UserDefaults` → daemon 마이그레이션 로직
- `engine_mode` 플래그: daemon/FFI 전환 토글 (릴리즈 초기 안전장치)
- XPC 호출 주체 변경 대응 (code-signing 검증 업데이트)

### WS-D: CLI + MCP

- `crabctl`: start-daemon/stop/status/rules/logs/replay/doctor
- `crab-mcp`: stdio MCP 서버, tool → IPC 브리지
- IDE 연결 시 읽기/제어 권한 정책 정리

### WS-E: 배포/운영

- 앱 번들 내 바이너리 배치 경로 확정
- 코드사인/notarization 파이프라인 반영 (`crabd` 바이너리 포함)
- `CrabProxyHelper` code-signing 검증 대상에 `crabd` 추가
- `doctor` 진단 명령 제공 (소켓 상태, PID, 버전, XPC 연결 등)

## 11) 리포 변경 포인트 (예상)

### 신규 파일

- `/Cargo.toml` (workspace root)
- `/crab-ipc/Cargo.toml`, `/crab-ipc/src/*`
- `/crabd/Cargo.toml`, `/crabd/src/*`
- `/crabctl/Cargo.toml`, `/crabctl/src/*`
- `/crab-mcp/Cargo.toml`, `/crab-mcp/src/*`
- `/CrabProxyMacApp/Sources/CrabProxyMacApp/DaemonClient.swift`
- `/CrabProxyMacApp/Sources/CrabProxyMacApp/DaemonLifecycle.swift`

### 수정 파일

- `/crab-mitm/Cargo.toml` (workspace member로 전환)
- `/CrabProxyMacApp/Sources/CrabProxyMacApp/ProxyViewModel.swift` (IPC 호출로 교체)
- `/CrabProxyMacApp/Sources/CrabProxyMacApp/RustProxyEngine.swift` (fallback 용도 축소)
- `/CrabProxyMacApp/Sources/CrabProxyMacApp/HelperClient.swift` (XPC 브리지 조정)
- `/CrabProxyMacApp/Package.swift` (빌드 타겟 업데이트)
- `/CrabProxyMacApp/Sources/CrabProxyHelper/main.swift` (code-signing 검증 대상 추가)
- `/README.md`, `/README.ko.md`
- `/crab-mitm/README.md`, `/crab-mitm/README.ko.md`

## 12) 원샷 실행 플랜 (내부 게이트 포함)

### Gate 0: 설계 고정 (D+2~3)

- RPC 스키마 최종 확정 (이 문서의 API 계약 기반)
- JSON-RPC 라이브러리 프로토타입 비교 → 최종 선택
- 에러코드, 생명주기(앱-데몬), 인증 정책 확정
- XPC 호출 주체 변경 방식 확정 (daemon 직접 호출 vs 앱 브리지)
- 산출물: API 스펙 문서, 상태 전이 다이어그램, 실패 처리표

### Gate 1: IPC + Engine 독립화 (D+7~9)

- `crab-ipc` 크레이트 완성 (코덱, 서버, 클라이언트, 테스트)
- `crabd` + `crabctl`만으로 start/stop/rules/status/logs 동작
- `state.json` 영속화/복원 동작 확인
- 산출물: Rust 단위/통합 테스트 통과, 로컬 E2E 스크립트

### Gate 2: App 전환 (D+13~15)

- `DaemonClient.swift`, `DaemonLifecycle.swift` 완성
- 앱 주요 기능이 IPC 경로로 동작
- `UserDefaults` → daemon 마이그레이션 동작 확인
- `engine_mode` 토글로 FFI/daemon 전환 확인
- 산출물: Start/Stop, Rules(Map Local/Map Remote/Rewrite), Logs, Replay 회귀 통과

### Gate 3: MCP 연동 (D+17~19)

- `crab-mcp` tool 세트 구현, IDE 클라이언트 연동 검증
- 산출물: MCP 시나리오 테스트 및 권한 정책 검증

### Gate 4: 하드닝/릴리즈 (D+21~26)

- 재연결/timeout/권한 실패/버전 불일치/daemon 재시작 처리
- 다중 클라이언트 동시 접근 시나리오 테스트
- XPC code-signing 검증 업데이트 및 테스트
- 코드사인/notarization 파이프라인 실행
- 산출물: 릴리즈 체크리스트, 전환 안전장치 검증, 배포 문서

## 13) 테스트 전략

### 자동화

- 단위: RPC 파서/검증, 룰 매핑, 상태 전이, 상태 파일 직렬화/역직렬화
- 통합: `crabd + crabctl`, `crabd + app`, `crabd + mcp`
- 회귀: Start/Stop, Map Local/Map Remote, Rewrite, Replay, Throttle
- 다중 클라이언트: 2개 이상의 클라이언트가 동시 연결/변경 시 state.changed 수신 확인

### 장애/복구

- daemon kill → 앱 자동 재시작 및 상태 복원
- stale socket → PID 확인 → 정리 → 재시작
- 소켓 권한 오류 → 사용자 안내 메시지
- 응답 timeout 및 malformed payload
- 앱 재실행 후 세션 복구
- XPC helper 비가용 시 graceful degradation

### 마이그레이션

- `UserDefaults`에 기존 설정이 있는 상태에서 daemon 모드 첫 전환 시 정상 이전 확인
- 이미 `state.json`이 있는 상태에서 재마이그레이션 방지 확인
- `state.json` 버전 업그레이드 시 하위 호환 확인

## 14) 프리릴리즈 전환 전략

### 롤아웃

- 내부 플래그: `engine_mode=daemon` 기본 ON
- 베타 채널에서 우선 검증 후 일반 배포

### 전환 안전장치

- 릴리즈 전까지 `engine_mode` 플래그로 daemon/FFI 경로 전환 가능 상태 유지
- 데이터 포맷은 전방 호환 우선
- daemon 비활성화 시에도 기존 핵심 기능 유지 (FFI fallback)

## 15) 주요 리스크와 대응

| 리스크 | 대응 |
|--------|------|
| 버전 불일치 | 핸드셰이크에서 즉시 차단 + 업그레이드 안내 |
| 권한/소켓 실패 | `doctor` 진단 + 자동 재시도 + 수동 복구 버튼 |
| 로그 폭주 | 배치 전송, 큐 크기 제한(10K), overflow notification, UI 샘플링 |
| 배포 이슈 | 초기부터 번들 구조/서명 파이프라인 고정 |
| 기능 회귀 | 핵심 시나리오 CI + 수동 체크리스트 병행 |
| XPC 브리지 실패 | code-signing 검증 사전 확인, fallback으로 앱 경유 XPC 유지 |
| 다중 클라이언트 충돌 | Last-Write-Wins + state.changed 브로드캐스트, 향후 revision 기반 잠금 확장 |
| 상태 파일 손상 | 기록 전 임시 파일 → 원자적 rename, 백업 파일 유지 |
| stale socket/PID | PID 파일 검증 → 프로세스 부재 시 자동 정리 |

## 16) 일정 가이드 (병렬 작업 기준)

| 단계 | 기간 | 비고 |
|------|------|------|
| 설계/스펙 고정 (Gate 0) | 2~3일 | JSON-RPC 라이브러리 프로토타입 포함 |
| IPC + daemon 코어 (Gate 1) | 5~7일 | workspace 구성 + crab-ipc + crabd |
| 앱 IPC 전환 (Gate 2) | 5~7일 | 마이그레이션 로직 포함으로 v1 대비 +1~2일 |
| CLI/MCP (Gate 3) | 3~4일 | Gate 1 완료 후 병렬 진행 가능 |
| 하드닝/QA/릴리즈 (Gate 4) | 5~7일 | 다중 클라이언트/XPC 검증 추가로 v1 대비 +1~2일 |
| **총합** | **약 3.5~4.5주** | |

## 17) 최종 제안

- "한 번에 3단계"는 가능하다.
- 단, 외부 릴리즈는 1회로 하되 내부는 Gate 방식으로 끊어서 리스크를 통제한다.
- 우선순위: `IPC 프로토콜 확정 > daemon 안정화 > 앱 전환 > MCP 확장`
- Gate 0에서 JSON-RPC 라이브러리와 XPC 호출 주체를 반드시 확정하고 넘어간다.
- 상태 마이그레이션은 Gate 2에서 빠짐없이 검증한다.
