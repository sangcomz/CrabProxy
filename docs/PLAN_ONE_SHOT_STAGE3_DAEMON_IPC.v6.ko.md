# Crab Proxy One-Shot 전환 계획서 v6 (Quality First)

## 0) 결론 요약 (고정 의사결정)

본 문서는 구현 복잡도보다 품질을 우선한다. 아래 3개 결정은 고정한다.

- D1. XPC 호출 주체: `crabd` 직접 호출 (앱 브리지 제거)
- D2. IPC 인증: `UDS 권한 + HMAC scope 토큰 + peer uid` 검증
- D3. FFI fallback: 제거 (`daemon` 단일 실행 경로)

핵심 원칙은 "단일 제어 평면, 단일 상태 소스, fail-closed 보안"이다.

---

## 1) 목표와 비목표

### 목표

- 현재 `FFI 인프로세스` 구조에서 `daemon + IPC + MCP` 3단계 목표 상태로 한 번에 전환
- `CrabProxyMacApp`, `crabctl`, `crab-mcp`가 동일한 `crabd` 상태를 공유
- MCP에서 `map_local`/`map_remote`/`status_rewrite` 조회/수정(`rules.get`, `rules.patch`) 가능
- 사용자 환경에서 Rust 설치 없이 앱 설치만으로 동작
- 프리릴리즈 단계에서 품질 게이트를 통과한 후 단일 릴리즈로 전환

### 비목표

- 원격(네트워크) 제어 API 공개
- 멀티 호스트 분산 제어
- FFI 병행 운영
- 기존 `crab-mitm` CLI 바이너리(`run`/`ca` 서브커맨드) 즉시 제거 (호환 기간 없음)

---

## 2) 품질 우선 원칙

- Single Source of Truth: 룰/상태/로그는 daemon authoritative
- Single Control Plane: 앱/CLI/MCP는 동일 IPC 계약 사용
- Fail Closed: 인증/권한/버전 검증 실패 시 기능 축소가 아니라 요청 거부
- Deterministic Lifecycle: daemon 시작/종료 정책은 launchd 기준으로 단일화
- Observability First: 장애 재현 가능하도록 진단 API/로그/메트릭 기본 제공
- Compatibility Discipline: 버전 협상 + 스키마 마이그레이션 정책을 코드로 강제

---

## 3) 목표 아키텍처

```text
┌────────────────────┐
│ CrabProxyMacApp    │
└─────────┬──────────┘
          │
┌─────────▼──────────┐      ┌────────────────────┐
│      crabctl       │      │      crab-mcp      │
└─────────┬──────────┘      └─────────┬──────────┘
          └──────────────┬────────────┘
                         │
                   UDS + JSON-RPC
                         │
                  ┌──────▼───────┐
                  │    crabd     │
                  │ (LaunchAgent)│
                  │ engine+state │
                  └──────┬───────┘
                         │ XPC (Swift helper binary)
                  ┌──────▼────────────────┐
                  │   CrabProxyHelper     │
                  │ (PF/인증서, root)     │
                  └───────────────────────┘
```

핵심 변화:
- 앱 내부 FFI 호출 제거
- 권한 작업은 `crabd -> Helper` 직접 호출 (Swift XPC 브리지 바이너리 경유)
- 앱은 순수 클라이언트(UI) 역할로 축소

---

## 4) ADR (Architecture Decision Record)

### ADR-001: `crabd`가 Helper를 직접 호출

결정:
- XPC privileged 작업(PF/인증서)은 `crabd` 단일 주체가 수행

채택 이유:
- CLI/MCP가 앱 없이도 동일 기능 수행 가능
- 권한 작업 진입점을 단일화해 감사/보안 정책 명확화
- 앱 생명주기와 시스템 제어 기능을 분리

구현 방식:
- `crabd`는 Rust 바이너리이므로 직접 `NSXPCConnection` 호출 불가
- **Swift XPC 브리지 바이너리** (`crabd-xpc-bridge`)를 별도 빌드
  - 역할: `crabd`의 subprocess로 실행, stdin/stdout JSON 프로토콜로 명령 수신, `NSXPCConnection`으로 Helper 호출, 결과 반환
  - 코드사인: 앱 번들 내 포함, 동일 team identifier로 서명
  - Helper 검증 대상: `crabd-xpc-bridge`의 designated requirement 추가
- `crabd`는 XPC 명령 필요 시 `crabd-xpc-bridge`를 subprocess spawn → JSON 명령 전달 → 결과 수신
- 대안 (Gate 0에서 프로토타입 비교):
  - A안: Swift XPC 브리지 바이너리 (위 설명, 1순위)
  - B안: Rust에서 `objc` 크레이트로 Objective-C 런타임 직접 호출 (복잡도 높음, 2순위)
- Gate 0 산출물에 XPC 브리지 프로토타입 포함 (PoC 구현 후 방식 확정)

대가/주의점:
- 추가 바이너리 (`crabd-xpc-bridge`) 관리 및 코드사인 필요
- Helper의 클라이언트 코드서명 검증 정책 업데이트 필요
- launchd/번들 ID/서명 파이프라인 변경 범위 확대

수용 기준:
- Helper가 허용한 서명된 `crabd-xpc-bridge`만 XPC 연결 허용
- 앱이 직접 Helper 호출하지 않아도 기능 동등성 유지
- XPC 브리지 프로세스 실패 시 `crabd`가 적절한 에러 반환

### ADR-002: UDS + HMAC scope 토큰 + peer uid 인증

결정:
- IPC 인증을 파일 권한 기반 + **HMAC scope 토큰** + **peer uid 검증**으로 구성

채택 이유:
- 동일 사용자 내 다른 프로세스 오남용 위험 축소
- MCP 권한을 룰 편집 범위로 제한하면서도(예: `rules.patch`) 안전하게 기능 제공 가능
- 클라이언트 구분/세션 폐기/회전 정책 설계 가능

대가/주의점:
- 토큰 생성/회전/배포 정책 구현 필요
- 클라이언트별 토큰 파일 분리 관리 필요

수용 기준:
- handshake 실패 시 제어 API 접근 불가 (fail-closed)
- 토큰 탈락/만료/회전 시 재인증 동작 검증
- `client_type` 자체는 권한판단 근거로 사용하지 않음 (표시/진단 용도만)
- scope가 다른 토큰으로 비허용 API 호출 시 `PERMISSION_DENIED` 반환

### ADR-003: FFI fallback 제거

결정:
- 런타임 fallback 경로를 제공하지 않음

채택 이유:
- split-brain/dual-write/상태 불일치 리스크 제거
- 테스트 매트릭스 축소로 품질 신뢰도 상승
- 운영/문서/지원 경로 단순화

대가/주의점:
- daemon 경로 문제 시 즉시 우회 수단 없음
- 따라서 릴리즈 전 하드닝 기준이 더 높아짐

수용 기준:
- 프리릴리즈 게이트에서 장애/복구/부하/권한 시나리오 통과

---

## 5) 보안 모델 (필수)

### 5.1 IPC 채널

- 소켓 경로: `~/Library/Application Support/CrabProxy/run/crabd.sock`
- 디렉터리 권한: `0700`
- 소켓 권한: `0600`
- peer credential 검사: `LOCAL_PEERCRED`로 연결 peer의 uid 획득, daemon uid와 동일한지 검증

### 5.2 Scope 정의

4개의 scope를 정의하며, 상위 scope는 하위 scope를 포함하지 않는 **독립적 권한 단위**이다.

| scope | 설명 |
|-------|------|
| `read` | 상태/설정/룰/로그 조회, 헬스체크 |
| `rules.write` | 룰 부분 수정 (`rules.patch`) |
| `control` | 프록시 제어, 설정 변경, 룰 전체 교체, CA 관리 |
| `admin` | helper 시스템 작업, daemon 종료, 토큰 회전 |

### 5.3 Scope → API 메서드 매핑

| 필요 scope | 메서드 |
|------------|--------|
| `read` | `system.ping`, `system.version`, `proxy.status`, `config.get`, `rules.get`, `logs.subscribe`, `logs.unsubscribe`, `logs.tail`, `logs.clear`, `ca.status`, `daemon.doctor` |
| `rules.write` | `rules.patch` |
| `control` | `config.patch`, `rules.apply`, `proxy.start`, `proxy.stop`, `proxy.replay`, `ca.load`, `ca.generate` |
| `admin` | `helper.enable_pf`, `helper.disable_pf`, `helper.install_cert`, `helper.remove_cert`, `helper.check_cert`, `daemon.shutdown`, `system.rotate_token` |

- `system.handshake`는 인증 전 호출이므로 scope 검사 대상 아님
- 하나의 API 호출에 필요한 scope를 세션이 보유하지 않으면 `9 PERMISSION_DENIED` 반환

### 5.4 세션 토큰 (HMAC 기반)

#### 토큰 형식

```
base64(json_payload) + "." + base64(hmac_signature)
```

payload 구조:
```json
{
  "scopes": ["read", "rules.write"],
  "iat": 1700000000,
  "jti": "random-unique-id"
}
```

- `scopes`: 이 토큰에 부여된 scope 목록
- `iat`: 발급 시각 (Unix timestamp)
- `jti`: 토큰 고유 ID (회전 시 폐기 대상 식별용)

#### 서명 방식

- 알고리즘: HMAC-SHA256
- 키: daemon 시작 시 CSPRNG로 생성 (256-bit), 메모리에만 보관
- 검증: daemon이 수신한 토큰의 payload를 동일 키로 재서명 → 서명 일치 확인

#### 클라이언트별 토큰 파일

daemon 시작 시 아래 3개 토큰 파일을 생성:

| 파일 | 경로 | 포함 scopes |
|------|------|-------------|
| `app.token` | `~/Library/Application Support/CrabProxy/run/app.token` | `read`, `rules.write`, `control`, `admin` |
| `cli.token` | `~/Library/Application Support/CrabProxy/run/cli.token` | `read`, `rules.write`, `control`, `admin` |
| `mcp.token` | `~/Library/Application Support/CrabProxy/run/mcp.token` | `read`, `rules.write` |

- 각 파일 권한: `0600`
- 클라이언트는 자신에게 해당하는 토큰 파일을 읽어 `system.handshake`에 전달
- `crabctl`은 `cli.token`, `crab-mcp`는 `mcp.token`, 앱은 `app.token` 사용

#### 토큰 생성 흐름

1. `crabd` 시작
2. CSPRNG로 256-bit HMAC 키 생성 (파일 저장 안 함, 메모리만)
3. 3개 토큰 파일 각각에 대해:
   - payload JSON 구성 (scopes, iat, jti)
   - HMAC-SHA256 서명 생성
   - `base64(payload).base64(signature)` 형식으로 토큰 파일에 기록
4. 파일 권한 `0600` 설정

#### 회전 정책

- daemon 재시작 시: 새 HMAC 키 생성 → 모든 토큰 자동 무효화 + 새 토큰 파일 생성
- `system.rotate_token` 호출 시:
  - **전체 토큰 회전** (새 HMAC 키 생성, 모든 기존 세션 무효화)
  - 호출자 포함 모든 연결된 클라이언트에 `SESSION_EXPIRED` 반환
  - 클라이언트는 새 토큰 파일을 읽어 재연결
  - `admin` scope 필요

### 5.5 인증 성공 조건

모두 만족해야 인증 성공 (`system.handshake` 처리 시):

1. UDS 소켓 파일 권한 `0600` + 디렉터리 `0700` 확인
2. `LOCAL_PEERCRED`로 peer uid 획득 → daemon uid와 동일 확인
3. 토큰 HMAC 서명 검증 통과
4. 토큰 `jti`가 폐기 목록에 없음 확인
5. `protocol_version` 호환 통과

하나라도 실패하면 즉시 연결 거부. 세션 수립 후 daemon은 토큰에 포함된 scopes를 세션에 기록하고, 이후 모든 API 호출에서 scope 검사를 수행한다.

### 5.6 XPC 권한

- Helper는 허용 식별자 화이트리스트 기반 검증
- 기본 허용 대상: `crabd-xpc-bridge`
- 검증 항목: bundle identifier + team identifier + designated requirement
- helper 메서드는 최소 권한 원칙으로 분리(`enable_pf`, `disable_pf`, `install_cert`, `remove_cert`, `check_cert`)

### 5.7 XPC 브리지 무결성

- `crabd`는 `crabd-xpc-bridge`를 **절대 경로**로만 실행
- 실행 전 bridge 바이너리의 code-signing requirement를 검증
- bridge subprocess 실행 시 환경변수 최소화 (`PATH` 의존 금지)
- 검증 실패 또는 bridge 시작 실패 시 `XPC_UNAVAILABLE` 반환

---

## 6) Daemon 생명주기 (품질 우선 정책)

### 시작/유지

- canonical owner: `launchd LaunchAgent`
- 앱/CLI/MCP는 daemon 미실행 시 `launchctl kickstart`로 시작 요청
- 중복 spawn 금지 (launchd 단일 인스턴스 보장)

### 종료

- 기본 정책: 클라이언트/프록시 상태와 무관하게 daemon 유지
- 명시적 종료만 허용: `daemon.shutdown`
- idle auto-exit 정책은 v6 범위에서 제외 (생명주기 단순화/예측가능성 우선)

### 장애 복구

- launchd가 crash restart 담당 (`KeepAlive = true`)
- 클라이언트 재연결 전략:
  - 최대 재시도: 10회
  - 백오프: 지수 백오프, 초기 100ms, 최대 5s, jitter ±20%
  - 10회 실패 시: 연결 포기 + 사용자에게 진단 안내 (daemon 상태 확인 유도)
- 재연결 성공 시 `logs.tail(after_id)` 로 유실 구간 자동 백필
- stale socket/PID 수동 로직은 최소화 (launchd 소유권 우선)

### 운영 안내 사항

- `KeepAlive = true`이므로 한 번 시작된 daemon은 시스템 재부팅 후에도 자동 시작됨
- 앱 최초 설치/LaunchAgent 등록 시 사용자에게 백그라운드 daemon 동작을 안내
- 앱 완전 제거 시 LaunchAgent plist 삭제 가이드 제공:
  - `launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.sangcomz.crabd.plist`
  - `rm ~/Library/LaunchAgents/com.sangcomz.crabd.plist`
- `daemon.doctor` 출력에 LaunchAgent 등록 상태 포함

---

## 7) 상태/로그 저장 모델

### 7.1 상태 저장

- 저장소: `state.sqlite3` (WAL)
- 위치: `~/Library/Application Support/CrabProxy/data/state.sqlite3`
- 이유: 원자성, 크래시 복구, 스키마 마이그레이션 일관성

### 7.2 스키마 버전

- `schema_version` 테이블로 명시 관리
- 앱/daemon 버전과 독립적으로 DB 마이그레이션 실행

### 7.3 로그 저장

- 구조: in-memory ring buffer + SQLite append
- in-memory ring: 최근 로그 빠른 조회용 (최대 5,000건)
- SQLite `logs` 테이블: 영속 저장, `logs.tail` 조회 대상

운영 정책:

| 항목 | 값 | 비고 |
|------|-----|------|
| 최대 로그 건수 | 100,000건 | 초과 시 FIFO 삭제 |
| 최대 DB 크기 | 500MB | 초과 시 가장 오래된 로그부터 삭제 |
| 로테이션 주기 | 건수/크기 임계 중 먼저 도달 시 | 삭제는 배치(1,000건 단위) |
| daemon 재시작 시 | 로그 유지 (영속) | in-memory ring은 SQLite에서 재로드 |
| `logs.clear` 호출 시 | 전체 삭제 (in-memory + SQLite) | |

Backpressure:
- 클라이언트별 전송 큐 최대 크기: 10,000건
- 큐 초과 시 오래된 로그부터 drop + `logs.overflow` notification 전송
- 클라이언트는 overflow 수신 시 `logs.tail(after_id)` 로 누락분 보충

---

## 8) 룰 ID 체계

### 설계

`rules.patch`가 개별 룰을 식별하기 위해 모든 룰에 고유 ID를 부여한다.

- 형식: UUID v4 (예: `"550e8400-e29b-41d4-a716-446655440000"`)
- 생성 시점: 룰이 처음 추가될 때 daemon이 자동 생성
- 클라이언트가 `rules.apply` 또는 `rules.patch(op: "upsert")`로 새 룰 전달 시:
  - `id` 필드가 없으면 daemon이 UUID 자동 부여
  - `id` 필드가 있으면 해당 ID로 upsert (기존 룰 덮어쓰기)

### 룰 순서 (매칭 우선순위)

- 룰 매칭은 **배열 내 순서** (index 0이 최우선)
- `rules.apply`는 전달된 배열 순서 그대로 적용
- `rules.patch`의 `upsert` 연산:
  - 기존 ID가 있으면 해당 위치에서 교체 (순서 유지)
  - 새 ID면 해당 set 배열의 **끝에 추가**
- 순서 변경이 필요한 경우: `rules.apply`로 전체 교체 (MCP는 비허용, 앱/CLI만 가능)

### 마이그레이션 시 ID 부여

- 기존 `UserDefaults`의 룰에는 ID가 없음
- 마이그레이션 시 daemon이 각 룰에 UUID를 자동 부여
- 순서는 `UserDefaults`에 저장된 배열 순서 그대로 유지

### 룰 데이터 구조 예시

```json
{
  "allow": [
    { "id": "uuid-1", "pattern": "*.example.com", "enabled": true }
  ],
  "map_local": [
    { "id": "uuid-2", "pattern": "/api/v1/mock", "local_path": "/tmp/mock.json", "status_code": 200, "enabled": true }
  ],
  "map_remote": [
    { "id": "uuid-3", "source_pattern": "https://api.prod.com/*", "destination": "https://api.staging.com/*", "enabled": true }
  ],
  "status_rewrite": [
    { "id": "uuid-4", "pattern": "/health", "status_code": 200, "enabled": true }
  ]
}
```

---

## 9) API 계약 v6

네임스페이스는 아래로 고정:
- `system.*`, `proxy.*`, `config.*`, `rules.*`, `logs.*`, `ca.*`, `helper.*`, `daemon.*`

### 9.1 시스템

| 메서드 | scope | 설명 | 파라미터 | 응답 |
|--------|-------|------|----------|------|
| `system.ping` | `read` | 헬스체크 | - | `{ "pong": true }` |
| `system.version` | `read` | 버전 조회 | - | `{ "engine": "1.1.0", "protocol": 1 }` |
| `system.handshake` | (없음) | 세션 수립 | `{ "protocol_version": 1, "token": "...", "client_type?": "app"\|"cli"\|"mcp" }` | `{ "session_id": "...", "protocol_version": 1, "scopes": ["read", "rules.write"] }` |
| `system.rotate_token` | `admin` | 토큰 전체 회전 | - | `{ "rotated": true }` |

### 9.2 프록시 제어

| 메서드 | scope | 설명 | 파라미터 | 응답 |
|--------|-------|------|----------|------|
| `proxy.start` | `control` | 프록시 시작 | - | `{ "status": "running" }` |
| `proxy.stop` | `control` | 프록시 중지 | - | `{ "status": "stopped" }` |
| `proxy.status` | `read` | 상태 조회 | - | `{ "status": "running"\|"stopped", "uptime_secs": 3600 }` |
| `proxy.replay` | `control` | 요청 재전송 | `{ "request_id": "..." }` | `{ "replayed": true }` |

### 9.3 설정 (`config.get` / `config.patch`)

**`config.get`** (scope: `read`): 전체 설정 조회

응답:
```json
{
  "revision": 42,
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
  "transparent": { "enabled": false, "port": 0 }
}
```

**`config.patch`** (scope: `control`): 부분 설정 변경 (JSON Merge Patch, RFC 7396 기반 확장)

규칙:
- 전달된 키만 변경, 생략된 키는 기존 값 유지
- 명시적으로 `null`을 전달하면 해당 키를 기본값으로 초기화 (v6 확장 규칙, RFC 7396과 다름에 주의)
- 중첩 객체도 동일 규칙 (merge, 덮어쓰기 아님)
- 구현 시 표준 RFC 7396 라이브러리를 직접 사용하지 않고, `null` = 기본값 복원 로직을 별도 구현

예시 1 - throttle만 변경:
```json
{
  "method": "config.patch",
  "params": {
    "throttle": { "enabled": true, "latency_ms": 200 }
  }
}
// 결과: throttle.enabled=true, throttle.latency_ms=200
//       throttle.downstream_bps 등 나머지는 기존 값 유지
//       listen, inspect 등 다른 섹션도 변경 없음
```

예시 2 - listen 주소와 inspect 동시 변경:
```json
{
  "method": "config.patch",
  "params": {
    "listen": { "port": 8080 },
    "inspect": { "enabled": false }
  }
}
// 결과: listen.port=8080, listen.addr=기존 값 유지
//       inspect.enabled=false
```

예시 3 - client_allowlist 초기화:
```json
{
  "method": "config.patch",
  "params": {
    "client_allowlist": null
  }
}
// 결과: client_allowlist를 기본값 { "enabled": false, "ips": [] }으로 복원
```

### 9.4 룰 관리

| 메서드 | scope | 설명 | 파라미터 | 응답 |
|--------|-------|------|----------|------|
| `rules.get` | `read` | 전체 룰 조회 | - | `{ "revision": 42, "allow": [...], "map_local": [...], "map_remote": [...], "status_rewrite": [...] }` |
| `rules.patch` | `rules.write` | 룰 부분 수정 | `{ "expected_revision": 42, "ops": [...] }` | `{ "revision": 43 }` |
| `rules.apply` | `control` | 룰 전체 교체 | `{ "allow": [...], "map_local": [...], "map_remote": [...], "status_rewrite": [...] }` | `{ "revision": 43 }` |

`rules.patch` ops 형식:
```json
{
  "expected_revision": 42,
  "ops": [
    { "op": "upsert", "set": "map_local", "rule": { "id?": "uuid-2", "pattern": "/api/mock", "local_path": "/tmp/m.json", "status_code": 200, "enabled": true } },
    { "op": "remove", "set": "map_remote", "id": "uuid-3" }
  ]
}
```

- `op: "upsert"`: `rule.id`가 있으면 교체, 없으면 끝에 추가 (daemon이 UUID 자동 부여)
- `op: "remove"`: 해당 `id`의 룰 삭제
- `expected_revision` 불일치 시 `13 REVISION_CONFLICT` 반환
- MCP 기본 권한은 `rules.patch` 중심으로 설계 (전체 교체 `rules.apply`는 `control` scope 필요)

### 9.5 로그

| 메서드 | scope | 설명 | 파라미터 | 응답 |
|--------|-------|------|----------|------|
| `logs.subscribe` | `read` | 실시간 스트림 구독 | `{ "filter?": "..." }` | `{ "subscribed": true }` |
| `logs.unsubscribe` | `read` | 구독 해제 | - | `{ "unsubscribed": true }` |
| `logs.tail` | `read` | 과거 로그 조회 | `{ "after_id?": "...", "limit?": 100 }` | `{ "entries": [...], "has_more": true }` |
| `logs.clear` | `read` | 로그 전체 삭제 | - | `{ "cleared": true }` |

### 9.6 CA 인증서

| 메서드 | scope | 설명 | 파라미터 | 응답 |
|--------|-------|------|----------|------|
| `ca.status` | `read` | CA 로드 상태 | - | `{ "loaded": true, "cert_path": "...", "common_name": "..." }` |
| `ca.load` | `control` | CA 로드 | `{ "cert_path": "...", "key_path": "..." }` | `{ "loaded": true }` |
| `ca.generate` | `control` | CA 생성 | `{ "algorithm?": "ecdsa"\|"rsa", "output_dir": "..." }` | `{ "cert_path": "...", "key_path": "..." }` |

### 9.7 시스템 통합 (XPC 브리지)

| 메서드 | scope | 설명 | 파라미터 | 응답 |
|--------|-------|------|----------|------|
| `helper.enable_pf` | `admin` | PF 활성화 | `{ "pf_conf": "...", "cert_path": "..." }` | `{ "enabled": true }` |
| `helper.disable_pf` | `admin` | PF 비활성화 | - | `{ "disabled": true }` |
| `helper.install_cert` | `admin` | 인증서 설치 | `{ "cert_path": "..." }` | `{ "installed": true }` |
| `helper.remove_cert` | `admin` | 인증서 제거 | `{ "common_name": "..." }` | `{ "removed": true }` |
| `helper.check_cert` | `admin` | 인증서 확인 | `{ "common_name": "..." }` | `{ "exists": true }` |

### 9.8 Daemon 제어

| 메서드 | scope | 설명 | 파라미터 | 응답 |
|--------|-------|------|----------|------|
| `daemon.shutdown` | `admin` | graceful 종료 | - | `{ "shutting_down": true }` |
| `daemon.doctor` | `read` | 진단 정보 수집 | - | `{ "socket": "ok", "state_db": "ok", "helper_xpc": "ok", "ca": "loaded", "launch_agent": "registered", ... }` |

### 9.9 Notification (daemon -> client, 단방향)

| 이벤트 | 설명 | payload |
|--------|------|---------|
| `logs.event` | 실시간 로그 항목 | `{ "id": "...", "timestamp": "...", ... }` |
| `logs.overflow` | 로그 큐 오버플로우 | `{ "dropped_count": 150, "oldest_available_id": "..." }` |
| `state.changed` | 설정/룰 변경 알림 | `{ "revision": 43, "changed_keys": ["throttle", "rules"] }` |
| `proxy.status_changed` | 프록시 상태 변경 | `{ "status": "running"\|"stopped" }` |

### 9.10 응답 공통 형식

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

- `revision`: 상태 변경 단조 증가값 (설정/룰 변경 시 증가)
- `request_id`: 추적용 서버 로그 상관 ID (에러 응답에도 포함)

### 9.11 에러 코드 체계

#### JSON-RPC 표준 에러

| 코드 | 이름 | 설명 |
|------|------|------|
| -32700 | Parse error | JSON 파싱 실패 |
| -32600 | Invalid request | 잘못된 JSON-RPC 요청 |
| -32601 | Method not found | 존재하지 않는 메서드 |
| -32602 | Invalid params | 파라미터 오류 |
| -32603 | Internal error | 서버 내부 오류 |

#### 애플리케이션 에러

| 코드 | 이름 | 설명 |
|------|------|------|
| 1 | PROXY_ALREADY_RUNNING | 프록시가 이미 실행 중 |
| 2 | PROXY_NOT_RUNNING | 프록시가 실행 중이 아님 |
| 3 | CA_NOT_LOADED | CA 인증서 미로드 상태 |
| 4 | CA_ERROR | CA 생성/로드 실패 |
| 5 | RULE_INVALID | 룰 검증 실패 (패턴 오류, 경로 없음 등) |
| 6 | VERSION_MISMATCH | 프로토콜 버전 불일치 |
| 7 | XPC_UNAVAILABLE | XPC Helper 사용 불가 |
| 8 | IO_ERROR | 파일/네트워크 I/O 오류 |
| 9 | PERMISSION_DENIED | 세션 scope에 허용되지 않는 작업 |
| 10 | AUTH_FAILED | 인증 실패 (토큰 HMAC 검증 실패, uid 불일치 등) |
| 11 | SESSION_EXPIRED | 세션 만료 (토큰 회전 후 기존 세션) |
| 12 | STATE_MIGRATION_REQUIRED | 상태 마이그레이션 필요 |
| 13 | REVISION_CONFLICT | `expected_revision` 불일치로 인한 갱신 충돌 |
| 14 | RULE_NOT_FOUND | `rules.patch` remove 시 해당 ID의 룰이 없음 |

에러 응답 형식:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": 10,
    "message": "AUTH_FAILED",
    "data": {
      "detail": "HMAC signature verification failed",
      "request_id": "req-abc-123"
    }
  }
}
```

---

## 10) 다중 클라이언트 동시성

### 정책: 기본 Last-Write-Wins + 선택적 낙관적 잠금

- 동시에 여러 클라이언트가 설정/룰을 변경할 수 있음
- `config.patch`/`rules.apply`는 **마지막 도착 요청 적용** (Last-Write-Wins)
- `rules.patch`는 `expected_revision`으로 충돌 검출 (낙관적 잠금)
- 모든 상태 변경 시 연결된 전체 클라이언트에 `state.changed` notification 브로드캐스트

### 클라이언트 동기화 흐름

1. 클라이언트 A가 `config.patch`로 throttle 변경
2. daemon이 변경 적용, `revision` 증가 (42 -> 43)
3. daemon이 모든 클라이언트에 `state.changed { revision: 43, changed_keys: ["throttle"] }` 전송
4. 다른 클라이언트들은 notification 수신 후 `config.get`으로 최신 상태 갱신
5. 클라이언트 UI에 변경 사항 반영

### `revision` 필드 용도

- 현재: 변경 추적 및 클라이언트 캐시 무효화
- 낙관적 잠금: `rules.patch(expected_revision)`에서 즉시 사용
  - 불일치 시 `REVISION_CONFLICT` 반환
  - 클라이언트는 `rules.get` 재조회 후 재시도

### 경합 시나리오

| 시나리오 | 동작 | 비고 |
|---------|------|------|
| 앱과 CLI가 동시에 룰 변경 | `rules.patch` + `expected_revision`으로 충돌 검출 | 실패 측은 재조회 후 재적용 |
| MCP가 config 읽기 중 다른 클라이언트가 변경 | 읽기는 변경 전/후 스냅샷 중 하나 반환 | 일관성 보장 (SQLite 트랜잭션) |
| 로그 subscribe 중 다른 클라이언트가 `logs.clear` | subscribe 중인 클라이언트에 clear 이후 새 로그만 전송 | overflow 아닌 정상 동작 |

---

## 11) 리포 구조

```text
CrabProxy/
├── Cargo.toml                        # workspace root
├── crab-mitm/                        # proxy engine library
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs                    # 라이브러리 진입점
│   │   ├── proxy.rs                  # 프록시 엔진 코어
│   │   ├── ca.rs                     # CA 관리
│   │   ├── config.rs                 # 설정 파싱
│   │   ├── rules.rs                  # 룰 매칭 (룰 ID 체계 추가)
│   │   └── proxy/                    # 프록시 서브모듈
│   └── include/
│       └── crab_mitm.h               # 제거 대상 (FFI 헤더)
├── crab-ipc/                         # 공통 IPC 프로토콜 (신규)
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs
│       ├── protocol.rs               # JSON-RPC 메시지 타입 정의
│       ├── codec.rs                  # UDS 프레임 인코딩/디코딩
│       ├── server.rs                 # IPC 서버 (crabd용)
│       ├── client.rs                 # IPC 클라이언트 (앱/CLI/MCP용)
│       ├── auth.rs                   # HMAC 토큰 생성/검증
│       └── error.rs                  # 에러 코드 및 타입
├── crabd/                            # daemon 바이너리 (신규)
│   ├── Cargo.toml                    # depends: crab-mitm, crab-ipc
│   └── src/
│       ├── main.rs                   # 진입점, 시그널 핸들링
│       ├── state.rs                  # 상태 관리, SQLite 영속화
│       ├── session.rs                # 클라이언트 세션/scope 관리
│       └── xpc_bridge.rs            # crabd-xpc-bridge subprocess 관리
├── crabctl/                          # CLI 바이너리 (신규)
│   ├── Cargo.toml                    # depends: crab-ipc
│   └── src/
│       └── main.rs
├── crab-mcp/                         # MCP 서버 바이너리 (신규)
│   ├── Cargo.toml                    # depends: crab-ipc
│   └── src/
│       ├── main.rs
│       └── tools.rs                  # MCP tool 정의
└── CrabProxyMacApp/
    └── Sources/
        ├── CrabProxyMacApp/
        │   ├── DaemonClient.swift         # IPC 클라이언트 (신규)
        │   ├── DaemonLifecycle.swift       # daemon 시작/감시 (신규)
        │   ├── ProxyViewModel.swift        # IPC 기반으로 교체
        │   ├── RustProxyEngine.swift       # 제거 대상
        │   └── ...
        ├── CrabProxyHelper/
        │   └── main.swift                  # code-signing 검증 대상 업데이트
        └── CrabXPCBridge/                  # XPC 브리지 (신규)
            └── main.swift                  # stdin/stdout JSON + NSXPCConnection
```

삭제 대상 (전환 완료 시):
- `crab-mitm/src/ffi.rs`
- `crab-mitm/src/main.rs` (기존 CLI)
- `crab-mitm/include/crab_mitm.h`
- `CrabProxyMacApp/Sources/CrabProxyMacApp/RustProxyEngine.swift`
- `CrabProxyMacApp/Sources/CCrabMitm/` (FFI C 모듈)

---

## 12) 데이터 마이그레이션

- 전환 시점 1회 마이그레이션만 수행
- 소스: 앱 `UserDefaults`
- 대상: daemon state DB (SQLite)
- 완료 마크: `migration.v6.completed = true` (daemon 저장소에 기록)

규칙:
- 성공 전까지 daemon 모드 활성화 금지
- 실패 시 앱에서 명확한 복구 가이드 출력
- 재시도는 idempotent해야 함

마이그레이션 흐름:
1. 앱 첫 실행 시 daemon 연결
2. daemon에 `migration.v6.completed` 확인
3. 미완료인 경우: 앱이 `UserDefaults`에서 설정 읽기 → `config.patch` + `rules.apply`로 daemon에 전달
4. daemon이 룰에 UUID 자동 부여 후 저장, `migration.v6.completed = true` 기록
5. 이후 앱은 `UserDefaults`에 설정을 쓰지 않음

---

## 13) 실행 계획 (내부 게이트)

### Gate 0: 설계 고정 (D+3)

- ADR-001/002/003 승인
- API 스펙 v6 최종 확정 (scope 매핑, 토큰 형식, 룰 ID 포함)
- 에러 코드 체계 확정
- Helper 보안 정책(허용 식별자/요구사항) 확정
- **XPC 브리지 프로토타입 구현** (A안 Swift 브리지 vs B안 objc 크레이트 비교)
- JSON-RPC 라이브러리 프로토타입 (자체 구현 vs `jsonrpsee` 비교 → 확정)
- HMAC 토큰 생성/검증 프로토타입

산출물:
- API 스펙 v6 확정본
- 보안 모델 문서 (scope 매핑, 토큰 형식 포함)
- 상태/로그 저장 스키마 문서
- 룰 ID 체계 확정 문서
- XPC 브리지 PoC + 방식 확정 결과

### Gate 1: 플랫폼 기반 (D+10)

- workspace + `crab-ipc` + `crabd` 골격 완성
- launchd 기반 lifecycle
- HMAC 토큰 생성/검증 + scope 기반 접근 제어 구현
- handshake + peer uid 검증 구현
- `crabd-xpc-bridge` 구현

산출물:
- IPC 통합 테스트
- 인증/scope 실패 케이스 테스트 (wrong scope → PERMISSION_DENIED)
- XPC 브리지 통합 테스트

### Gate 2: 엔진/권한 통합 (D+18)

- proxy/rules/config/log/replay를 daemon 상태와 통합
- 룰 ID 체계 구현 (UUID 자동 부여, upsert/remove)
- `crabd -> xpc-bridge -> Helper` 전체 경로 구현
- state SQLite + logs tail 복구 경로 완성
- 다중 클라이언트 동시 접근 테스트

산출물:
- 엔드투엔드 제어 테스트
- XPC 보안 검증 테스트
- 동시성 시나리오 테스트
- 룰 ID upsert/remove 테스트

### Gate 3: 클라이언트 전환 (D+24)

- 앱 IPC 전환 완료
- `crabctl`, `crab-mcp` IPC 연동 완료
- UserDefaults -> daemon 마이그레이션 완료 (룰 UUID 자동 부여 포함)
- scope 기반 접근 제어 검증 (MCP에서 `rules.patch` 성공, `rules.apply` 거부)

산출물:
- app/cli/mcp 상호운용 테스트
- 마이그레이션 테스트 리포트
- MCP scope 제한 동작 테스트

### Gate 4: 하드닝 (D+31)

- 장애 주입(crash, timeout, malformed, auth fail, wrong scope)
- 부하 테스트(log burst, 동시 클라이언트)
- 토큰 회전 시 전체 세션 만료 + 재연결 검증
- 코드사인/notarization 검증 (`crabd`, `crabd-xpc-bridge` 포함)
- FFI 코드/파일 삭제 및 빌드 검증

산출물:
- release candidate 품질 리포트
- blocker 0개 확인
- 삭제 대상 파일 정리 확인

---

## 14) 테스트 전략 (품질 기준)

### 14.1 기능

- Start/Stop/Status/Rules/Map Local/Map Remote/Rewrite/Replay
- Throttle/Inspect/Allowlist/Transparent/CA 전체 시나리오
- `config.patch` 부분 업데이트 / null 초기화 동작
- `rules.patch` upsert(신규 추가 + 기존 교체) / remove / REVISION_CONFLICT
- 룰 ID 자동 부여 / 순서 유지

### 14.2 보안

- 무토큰/오토큰/변조토큰 → `AUTH_FAILED`
- HMAC 키 불일치 → `AUTH_FAILED`
- peer uid 불일치 → `AUTH_FAILED`
- `mcp.token`으로 `rules.apply` 호출 → `PERMISSION_DENIED`
- `mcp.token`으로 `helper.*` 호출 → `PERMISSION_DENIED`
- `mcp.token`으로 `rules.patch` 호출 → 성공
- 비허용 바이너리의 Helper XPC 접근 거부
- 토큰 회전 후 기존 세션 `SESSION_EXPIRED` 반환
- 회전 후 새 토큰 파일로 재연결 성공

### 14.3 복구

- daemon crash 후 launchd 재기동 + 클라이언트 재연결 (10회 백오프)
- 로그 overflow 후 `logs.tail` 복구
- XPC 브리지 프로세스 crash 후 `crabd` 재spawn
- 마이그레이션 중 중단/재시도 idempotency

### 14.4 동시성

- 앱 + CLI 동시 `config.patch` → Last-Write-Wins 동작 확인
- 앱 + CLI 동시 `rules.patch`(동일 `expected_revision`) → `REVISION_CONFLICT` 검출 확인
- 앱 + CLI 동시 `rules.apply` → `state.changed` 브로드캐스트 확인
- 3개 클라이언트(앱+CLI+MCP) 동시 연결/해제 반복

### 14.5 성능/부하

- 동시 클라이언트 N개(앱+CLI+MCP)에서 제어 일관성
- 로그 burst 처리량과 지연 (목표: 10,000 req/s에서 로그 지연 < 100ms)
- SQLite 로그 쓰기 병목 확인 (100,000건 저장 후 tail 응답 시간)
- 장시간 soak test (>= 24h)

---

## 15) 프리릴리즈 운영 전략 (No Fallback)

- 내부 카나리: 개발/QA/소수 사용자 순으로 점진 확장
- 릴리즈 블로커 기준:
  - P0/P1 결함 0건
  - 보안 결함 0건
  - 데이터 손실 재현 0건
- fallback 경로 없음: 결함은 수정 후 재배포 원칙

---

## 16) 일정 가이드 (품질 우선)

| 단계 | 기간 | 비고 |
|------|------|------|
| Gate 0: 설계 고정 | 3일 | XPC 브리지 PoC + HMAC 프로토타입 포함 |
| Gate 1: 플랫폼 기반 | 7일 | workspace + IPC + 토큰/scope + XPC 브리지 |
| Gate 2: 엔진/권한 통합 | 8일 | 룰 ID + 동시성 테스트 포함 |
| Gate 3: 클라이언트 전환 | 6일 | 마이그레이션 + scope 접근 제어 |
| Gate 4: 하드닝 | 7일 | FFI 삭제 + 토큰 회전 + 최종 검증 |
| **총합** | **약 4.5~5.5주** | |

---

## 17) 완료 정의 (Definition of Done)

아래 조건을 모두 충족해야 v6 전환 완료로 본다.

- FFI 코드 경로 및 파일 제거 완료 (`ffi.rs`, `crab_mitm.h`, `RustProxyEngine.swift`, `CCrabMitm`)
- 기존 `crab-mitm` CLI 바이너리 (`main.rs`) 제거 완료
- 앱/CLI/MCP가 동일 daemon 상태를 읽고 제어함
- `crabd -> xpc-bridge -> Helper` privileged 경로가 보안 검증과 함께 동작함
- HMAC scope 토큰 기반 인증 및 scope 기반 접근 제어가 동작함
- `system.handshake` 실패가 fail-closed로 동작함 (uid, HMAC, protocol_version 검증)
- MCP에서 `rules.patch` 성공, `rules.apply`/`helper.*`/`config.patch` 거부됨
- `config.patch`가 RFC 7396 기반 확장 규칙(`null`=기본값 복원)대로 동작함
- 룰 ID(UUID) 체계가 동작하고, `rules.patch` upsert/remove가 정상 작동함
- 다중 클라이언트 동시 접근 시 `state.changed` 브로드캐스트 및 일관성 유지
- 토큰 회전 시 전체 세션 만료 및 재연결 동작
- 로그 저장소 크기 제한/로테이션 동작
- 마이그레이션/복구/부하/보안 테스트가 게이트 기준을 통과함
- 운영 문서(README, 진단 가이드, 장애 대응 플로우, LaunchAgent 관리 안내) 반영 완료

---

## 18) 주요 리스크와 대응

| 리스크 | 대응 |
|--------|------|
| 버전 불일치 | 핸드셰이크에서 즉시 차단 + 업그레이드 안내 (`VERSION_MISMATCH`) |
| 권한/소켓 실패 | `daemon.doctor` 진단 + 재연결 백오프 + 사용자 안내 |
| 로그 폭주 | 큐 크기 제한(10K) + overflow notification + SQLite 로테이션(100K건/500MB) |
| 배포 이슈 | 초기부터 번들 구조/서명 파이프라인 고정 (`crabd`, `crabd-xpc-bridge` 포함) |
| 기능 회귀 | 핵심 시나리오 CI + 수동 체크리스트 병행 |
| XPC 브리지 실패 | `crabd`가 브리지 프로세스 crash 감지 후 재spawn, 실패 시 `XPC_UNAVAILABLE` 반환 |
| 다중 클라이언트 충돌 | `config.patch`/`rules.apply` LWW + `rules.patch(expected_revision)` 충돌 검출 + `state.changed` 브로드캐스트 |
| SQLite 손상 | WAL 모드 + 정기 `PRAGMA integrity_check` (doctor 명령), 복구 불가 시 초기화 |
| MCP 보안 오남용 | HMAC scope 토큰으로 `rules.write` scope만 부여, `control`/`admin` 접근 차단 |
| 토큰 유출 | 파일 권한 `0600`, uid 이중 검증, 유출 감지 시 `system.rotate_token`으로 즉시 무효화 |
| LaunchAgent 좀비화 | `daemon.doctor`에 LaunchAgent 상태 포함, 앱 제거 가이드에 plist 삭제 절차 명시 |

---

## 19) 최종 제안

- 본 전환은 "복잡도 최소"가 아니라 "품질 최대" 전략이다.
- 따라서 초기 개발 비용은 증가하지만, 전환 후 운영 리스크와 상태 불일치 리스크를 구조적으로 제거한다.
- v5 대비 보강된 부분: scope→API 매핑 명시, HMAC 토큰 형식/생성 흐름 확정, peer identity를 peer uid로 명확화, 룰 ID 체계(UUID/순서/마이그레이션), 토큰 회전 동작 범위 확정, LaunchAgent 운영 안내.
- 본 문서 기준으로 진행 시, 장기적으로 MCP/자동화 확장에 가장 안정적인 기반을 확보할 수 있다.
