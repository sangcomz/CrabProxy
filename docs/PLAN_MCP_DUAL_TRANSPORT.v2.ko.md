# PLAN: MCP Dual Transport (stdio + Streamable HTTP) v2

## v1 → v2 변경 요약

| 항목 | v1 | v2 |
|------|----|----|
| 모듈 경로 | `crab-mitm/src/mcp_core/` (신규) | `src/mcp/` (신규 모듈 트리) |
| 도구 목록 | 카테고리만 기술 | 45개 전체 도구 명세 |
| HTTP 프로토콜 | "Streamable HTTP 우선" | Streamable HTTP 전용 + 세션 관리 정의 |
| 동시 실행 | 미정의 | `--transport both` 모드 추가 |
| crabd 브리지 | 암묵적 | `McpBridge` trait 명시 설계 |
| 앱 연동 파일 | 일부 부정확 | 실제 Swift 구조 기반 수정 |
| 의존성 전략 | 미명시 | 기존 hyper 스택 재사용 명시 |
| 에러 처리 | 미정의 | JSON-RPC / MCP 에러 코드 매핑 표준화 |
| 보안 | Bearer token | Bearer token + Origin 검증 + CORS 정책 |

---

## 0. 배경

- 현재 `crab-mcp`는 **stdio 전용 MCP 서버**(1,487줄 단일 파일 `src/bin/crab-mcp.rs`)로, 내부적으로 `crabd` Unix socket IPC를 호출한다.
- 이 방식은 Codex/IDE가 프로세스를 직접 spawn하는 시나리오에 적합하지만, **앱에서 MCP URL로 연결하는 UX**(Claude Desktop, Cursor remote 등)를 지원하지 못한다.
- 목표: `stdio` transport를 유지하면서 **Streamable HTTP** transport를 추가해 두 방식 모두 단일 바이너리에서 지원한다.

---

## 1. 목표

1. `stdio`와 `Streamable HTTP`를 동시에 지원한다.
2. 두 transport에서 **동일한 45개 도구(tool) 집합과 동일한 동작**을 보장한다.
3. macOS 앱에서 HTTP MCP를 켜고 끌 수 있으며, endpoint/token 정보를 복사할 수 있다.
4. 보안(로컬 바인딩, Bearer token, Origin 검증, scope 제어)을 유지한다.
5. 기존 stdio 동작에 대한 **회귀 없음**을 보장한다.

## 2. 비목표 (v2 범위 제외)

1. 원격 공개(인터넷 노출) MCP 서버 운영.
2. 다중 사용자 계정 공유 인증.
3. SSE(Server-Sent Events) 레거시 transport (Streamable HTTP가 SSE를 대체).
4. MCP 툴 의미(semantic)의 대규모 재설계.
5. launchd 상시 서비스(향후 v3 후보).

---

## 3. 현재 상태 (As-Is)

### 3.1 아키텍처 개요
```text
IDE/Codex ──stdin/stdout──> crab-mcp ──Unix socket IPC──> crabd ──> Proxy Engine
                              │
                              ├── 45개 MCP tool 정의
                              ├── JSON-RPC 2.0 (Content-Length 프레이밍)
                              ├── MCP 프로토콜 버전: 2024-11-05
                              └── traffic aggregation 로직 (logs → grouped entries)
```

### 3.2 핵심 파일

| 파일 | 줄 수 | 역할 |
|------|-------|------|
| `src/bin/crab-mcp.rs` | ~1,487 | MCP stdio 서버, 도구 정의, traffic 집계 |
| `src/daemon/mod.rs` | ~1,500 | IPC 데몬, RPC 디스패치, 인증, 상태 관리 |
| `src/ipc.rs` | ~169 | RPC 프로토콜 타입 정의 |
| `src/proxy.rs` | ~2,000 | HTTP(S) 프록시 엔진 |
| `src/rules.rs` | ~350 | 규칙 타입 및 매칭 |

### 3.3 crabd 인증 체계
- **토큰 형식**: `base64url(payload) + "." + base64url(hmac_sha256(payload))`
- **토큰 파일** (`0600` 권한):
  - `app.token` — macOS 앱 (scopes: read, rules.write, control, admin)
  - `cli.token` — crabctl CLI (scopes: read, rules.write, control, admin)
  - `mcp.token` — MCP 서버 (scopes: read, rules.write, control)
- **scope 정책**: `read`, `rules.write`, `control`, `admin`

### 3.4 의존성 현황 (HTTP 관련)
이미 사용 중이며 HTTP transport에 재사용 가능:
- `hyper` v1.7 (full: http1, http2, server, client)
- `hyper-util` v0.1 (server auto, tokio runtime)
- `tokio` v1.47 (net, signal, sync)
- `serde_json` (JSON-RPC 직렬화)

**추가 의존성 불필요** — 기존 hyper + service_fn 패턴으로 HTTP 서버 구현.

---

## 4. 목표 아키텍처 (To-Be)

```text
                    ┌──────────────────────────────────┐
IDE/Codex ─stdio──> │          StdioTransport           │──┐
                    └──────────────────────────────────┘  │
                                                          │  ┌──────────────┐
                    ┌──────────────────────────────────┐  ├─>│              │
IDE/Tool ──HTTP──>  │     StreamableHttpTransport       │──┤  │   McpCore    │──IPC──> crabd
                    │  (hyper service_fn, Bearer auth)  │  │  │              │
                    └──────────────────────────────────┘  │  │ - ToolRegistry│
                              ▲                           │  │ - Validation  │
                              │                           │  │ - Execution   │
                    ┌─────────┴────────┐                  │  │ - TrafficAggr │
                    │ CrabProxyMacApp  │                  │  └──────────────┘
                    │ (start/stop,     │──────────────────┘
                    │  endpoint/token) │
                    └──────────────────┘
```

### 핵심 원칙

1. **단일 Core**: Tool registry, argument validation, execution, traffic aggregation은 `McpCore`에서만 구현.
2. **Transport = 어댑터**: 입출력 직렬화/역직렬화와 인증만 담당.
3. **기존 재사용**: crabd API, 권한 모델, hyper 스택 그대로 활용.
4. **동시 실행 가능**: `--transport both`로 stdio + HTTP를 한 프로세스에서 동시 제공.

---

## 5. 핵심 설계 결정

### D1. 구현 형태

| 선택지 | 설명 |
|--------|------|
| A. 단일 바이너리 모드 | `crab-mcp --transport stdio\|http\|both` |
| B. 별도 바이너리 | `crab-mcp` (stdio) + `crab-mcp-http` (HTTP) |

**결정: A (단일 바이너리)**
- 배포/서명/버전 동기화 단순
- `--transport both`로 동시 제공 가능
- 코드 중복 최소

### D2. HTTP 프로토콜

| 선택지 | 설명 |
|--------|------|
| A. Streamable HTTP 전용 | `POST /mcp` (JSON-RPC), 응답은 JSON 또는 SSE stream |
| B. SSE legacy + Streamable HTTP | 하위 호환 |

**결정: A (Streamable HTTP 전용)**
- MCP 스펙이 Streamable HTTP로 표준화. SSE-only는 deprecated.
- `POST /mcp` 단일 엔드포인트로 request/response + streaming 모두 처리.
- `Accept: text/event-stream` 헤더 시 SSE stream 응답, 그 외 JSON 응답.

### D3. 세션 관리 (Streamable HTTP)

| 선택지 | 설명 |
|--------|------|
| A. Stateless (요청별 독립) | 매 요청마다 crabd에 handshake |
| B. Session-based | `Mcp-Session-Id` 헤더로 세션 유지, 첫 initialize 시 handshake |

**결정: B (Session-based)**
- MCP 스펙의 `Mcp-Session-Id` 헤더 지원.
- `initialize` 요청 시 crabd handshake + 세션 생성, 이후 요청은 세션 재사용.
- 세션 TTL: 30분 (마지막 요청 기준), 만료 시 `401` 반환.
- 서버 재시작 시 모든 세션 무효화.

### D4. HTTP 보안

**기본값:**
1. `127.0.0.1` 바인딩 (외부 NIC 미노출)
2. `Authorization: Bearer <token>` 필수
3. token 파일 `0600` 권한 (`mcp-http.token`)
4. **Origin 검증**: `Origin` 헤더가 존재하면 `127.0.0.1` / `localhost`만 허용
5. **CORS 정책**: preflight `OPTIONS` 처리, `Access-Control-Allow-Origin: http://localhost:*`
6. 기존 `mcp` scope 정책 유지 (read, rules.write, control)

**token 관리:**
- 기본 token 파일: `~/Library/Application Support/CrabProxy/run/mcp-http.token`
- `--http-token-path` 옵션으로 경로 오버라이드 가능
- 앱/CLI에서 명시적 rotate 제공 (crabd `system.rotate_token` 재사용)

### D5. 라이프사이클

| 선택지 | 설명 |
|--------|------|
| A. 앱 관리형 (App-managed) | 앱에서 HTTP MCP 시작/중지 |
| B. 자체 관리형 (Self-managed) | CLI로 직접 실행/종료 |

**결정: A + B 모두 지원**
- **앱 경유**: 앱 UI에서 HTTP MCP ON/OFF → `MCPHttpService.swift`가 프로세스 관리
- **CLI 직접**: `crab-mcp --transport http --http-port 3847` 으로 독립 실행
- 앱 종료 시 앱이 spawn한 HTTP MCP도 종료 (좀비 방지, SIGTERM + graceful shutdown)

### D6. 에러 코드 표준화

MCP JSON-RPC 에러 코드 매핑:

| 상황 | JSON-RPC code | message |
|------|---------------|---------|
| 알 수 없는 메서드 | `-32601` | `Method not found` |
| 잘못된 파라미터 | `-32602` | `Invalid params: {detail}` |
| crabd 연결 실패 | `-32603` | `Internal error: daemon unreachable` |
| 권한 부족 (scope) | `-32001` | `Forbidden: insufficient scope` |
| 프록시 미실행 | `-32002` | `Proxy not running` |
| 프록시 이미 실행 중 | `-32003` | `Proxy already running` |
| tool 실행 실패 | `-32004` | `Tool execution failed: {detail}` |

HTTP 레벨 에러:

| 상황 | HTTP status | body |
|------|-------------|------|
| 인증 실패 | `401 Unauthorized` | `{"error": "invalid or missing token"}` |
| Origin 거부 | `403 Forbidden` | `{"error": "origin not allowed"}` |
| 잘못된 Content-Type | `415 Unsupported Media Type` | `{"error": "expected application/json"}` |
| 세션 만료 | `401 Unauthorized` | `{"error": "session expired"}` |
| 서버 에러 | `500 Internal Server Error` | `{"error": "{detail}"}` |

---

## 6. 작업 분해 (Workstreams)

### WS1. MCP Core 분리

**목표**: `crab-mcp.rs` 1,487줄 단일 파일에서 transport 무관 로직을 추출하여 재사용 가능한 모듈로 분리.

**신규 모듈 구조:**
```
src/
├── mcp/
│   ├── mod.rs              # pub mod 선언
│   ├── core.rs             # McpCore: initialize, tools/list, tools/call, ping 핸들러
│   ├── tools.rs            # ToolRegistry: 45개 도구 스키마 + validation
│   ├── bridge.rs           # McpBridge: crabd IPC 통신 추상화
│   ├── traffic.rs          # TrafficAggregator: 로그 → 그룹화된 트래픽 엔트리 변환
│   ├── types.rs            # 공통 타입 (McpRequest, McpResponse, ToolResult 등)
│   └── error.rs            # 에러 타입 + JSON-RPC 에러 코드 매핑
├── bin/
│   └── crab-mcp.rs         # 진입점: CLI 파싱 + transport 선택 + 실행
```

**기존 파일 변경:**
- `src/bin/crab-mcp.rs` — Core 로직 제거, transport adapter + CLI만 유지 (~200줄 이하)
- `src/lib.rs` — `pub mod mcp;` 추가

**핵심 trait:**
```rust
/// Transport-agnostic MCP core
pub struct McpCore {
    bridge: McpBridge,
    tools: ToolRegistry,
    traffic: TrafficAggregator,
    server_info: ServerInfo,
}

impl McpCore {
    pub async fn handle_request(&self, req: McpRequest) -> McpResponse;
    pub fn tools_list(&self) -> Vec<ToolSchema>;
}

/// crabd IPC bridge
pub struct McpBridge { /* Unix socket, token, session */ }

impl McpBridge {
    pub async fn call(&self, method: &str, params: Value) -> Result<Value, McpError>;
    pub async fn ensure_daemon(&self) -> Result<(), McpError>;
}
```

**작업 순서:**
1. `src/mcp/types.rs` — 공통 타입 정의
2. `src/mcp/error.rs` — 에러 타입 + 코드 매핑
3. `src/mcp/bridge.rs` — `send_rpc` 로직 추출
4. `src/mcp/tools.rs` — 45개 도구 스키마/validation 추출
5. `src/mcp/traffic.rs` — traffic aggregation 로직 추출
6. `src/mcp/core.rs` — `handle_request` 메인 디스패치 구현
7. `src/bin/crab-mcp.rs` — stdio adapter만 남기도록 리팩터링
8. 기존 stdio 동작 회귀 테스트

### WS2. Streamable HTTP Transport 추가

**목표**: 동일 `McpCore`를 Streamable HTTP로 노출.

**신규 파일:**
```
src/mcp/
└── http_transport.rs     # HTTP 서버, 인증, 세션 관리, CORS
```

**기존 파일 변경:**
- `src/bin/crab-mcp.rs` — `--transport http|both` 모드 추가, HTTP 서버 시작 로직
- `Cargo.toml` — 추가 의존성 없음 (기존 hyper/tokio 재사용)

**CLI 옵션 추가:**
```
crab-mcp [OPTIONS]

--transport <MODE>       stdio | http | both (기본: stdio)
--http-bind <ADDR>       HTTP 바인드 주소 (기본: 127.0.0.1)
--http-port <PORT>       HTTP 포트 (기본: 3847)
--http-token-path <PATH> HTTP 토큰 파일 경로
```

**엔드포인트:**

| Method | Path | 설명 |
|--------|------|------|
| `POST` | `/mcp` | MCP JSON-RPC request 처리 (Streamable HTTP) |
| `GET` | `/mcp` | SSE stream 연결 (server-initiated notifications) |
| `DELETE` | `/mcp` | 세션 종료 |
| `GET` | `/healthz` | liveness check |

**Streamable HTTP 동작:**
1. 클라이언트가 `POST /mcp`로 `initialize` 요청 전송
2. 서버가 `Mcp-Session-Id` 헤더와 함께 initialize 응답 반환
3. 이후 요청에는 `Mcp-Session-Id` 헤더 포함 필수
4. 응답 형태:
   - `Accept: application/json` → 단일 JSON 응답
   - `Accept: text/event-stream` → SSE stream 응답 (향후 notification 용)

**요청 처리 파이프라인:**
```
HTTP Request
  → CORS preflight 처리 (OPTIONS)
  → Origin 검증
  → Bearer token 인증
  → Mcp-Session-Id 검증 (initialize 제외)
  → JSON body 파싱
  → McpCore.handle_request()
  → JSON/SSE 응답 반환
```

**세션 관리:**
```rust
struct HttpSession {
    id: String,
    created_at: Instant,
    last_activity: Instant,
    bridge_session: String,    // crabd IPC session ID
}

struct SessionManager {
    sessions: RwLock<HashMap<String, HttpSession>>,
    ttl: Duration,             // 기본 30분
}
```

**작업 순서:**
1. `http_transport.rs` — hyper service_fn 기반 HTTP 서버 골격
2. Bearer token 인증 미들웨어
3. 세션 관리 (Mcp-Session-Id)
4. CORS / Origin 검증
5. `POST /mcp` → `McpCore.handle_request()` 연결
6. `GET /healthz` 구현
7. `DELETE /mcp` 세션 종료
8. `src/bin/crab-mcp.rs`에 `--transport` 모드 분기
9. `--transport both` — tokio::select! 으로 stdio + HTTP 동시 실행

### WS3. 앱 연동 (HTTP MCP ON/OFF)

**목표**: macOS 앱에서 HTTP MCP 프로세스를 관리하고 연결 정보를 제공.

**신규 파일:**
```
CrabProxyMacApp/Sources/CrabProxyMacApp/
└── MCPHttpService.swift     # HTTP MCP 프로세스 관리
```

**기존 파일 변경:**

| 파일 | 변경 내용 |
|------|-----------|
| `ProxyViewModel.swift` | MCP HTTP 상태 속성 추가, MCPHttpService 통합 |
| `SettingsView.swift` | MCP HTTP 설정 UI 섹션 추가 |

**MCPHttpService 설계:**
```swift
@Observable
class MCPHttpService {
    var isRunning: Bool
    var endpoint: String?        // "http://127.0.0.1:3847/mcp"
    var tokenFilePath: String?
    var lastError: String?

    func start(port: UInt16) async throws
    func stop() async
    func copyEndpointToClipboard()
    func copyTokenToClipboard()
}
```

**프로세스 관리:**
- `Process` (Foundation)로 `crab-mcp --transport http --http-port <port>` spawn
- stdout/stderr 파이프로 상태 모니터링
- 앱 `applicationWillTerminate`에서 SIGTERM 전송
- 비정상 종료 시 자동 재시작 옵션 (토글)

**UI 항목:**

| 요소 | 설명 |
|------|------|
| `Enable MCP (HTTP)` 토글 | HTTP MCP 서버 시작/중지 |
| Endpoint 표시 | `http://127.0.0.1:<port>/mcp` + 복사 버튼 |
| Token 표시 | 파일 경로 + 복사 버튼 (token 값 직접 복사) |
| Port 설정 | 기본 3847, 사용자 변경 가능 |
| 상태 표시 | Running / Stopped / Error |
| 에러 메시지 | 마지막 에러 (port in use 등) |
| IDE 설정 가이드 링크 | 클릭 시 설정 JSON 예시 표시 |

### WS4. 보안/운영성

**목표**: 로컬 HTTP 서버의 안전하고 안정적인 운영.

**작업:**

| # | 작업 | 설명 |
|---|------|------|
| 1 | 포트 충돌 자동 탐색 | 기본 포트(3847) 사용 불가 시 3848~3857 순차 탐색 |
| 2 | token 파일 권한 검사 | 시작 시 `0600` 검증, 불일치 시 자동 복구 + 경고 로그 |
| 3 | Origin 검증 | 브라우저 기반 공격 방지. localhost/127.0.0.1만 허용 |
| 4 | CORS preflight | `OPTIONS /mcp` 처리, 허용 Origin/Method/Headers 반환 |
| 5 | 에러 진단 메시지 | `port in use`, `token missing`, `auth failed`, `daemon unreachable` 표준화 |
| 6 | Graceful shutdown | SIGTERM/SIGINT 수신 시 활성 세션 종료 대기 (최대 5초) |
| 7 | 요청 속도 제한 | IP당 분당 최대 600 요청 (단순 카운터, DoS 완화) |

### WS5. 문서/도구 설정

**목표**: 사용자가 쉽게 연결할 수 있도록 안내.

**작업:**

| # | 작업 |
|---|------|
| 1 | IDE별 MCP 설정 예시 — Claude Desktop, Cursor, Codex, VS Code |
| 2 | stdio vs HTTP 선택 가이드 (언제 무엇을 사용할지) |
| 3 | 트러블슈팅 섹션 (연결 안됨, 인증 실패, 포트 충돌 등) |
| 4 | `crab-mcp --help` 출력 업데이트 |
| 5 | README MCP 섹션 업데이트 |

---

## 7. 도구 동등성(Parity) 정책

모든 MCP tool은 transport와 무관하게 동일해야 한다.

### 7.1 전체 도구 목록 (45개)

**System (3개):**
| 도구 | 설명 |
|------|------|
| `crab_ping` | RPC 연결 확인 |
| `crab_version` | 엔진/프로토콜 버전 |
| `crab_daemon_doctor` | 데몬 진단 |

**Proxy Control (3개):**
| 도구 | 설명 |
|------|------|
| `crab_proxy_status` | 프록시 실행 상태 |
| `crab_proxy_start` | 프록시 시작 |
| `crab_proxy_stop` | 프록시 중지 |

**Engine Configuration (7개):**
| 도구 | 설명 |
|------|------|
| `crab_engine_config_get` | 현재 설정 조회 |
| `crab_engine_set_listen_addr` | 바인드 주소 설정 |
| `crab_engine_set_inspect_enabled` | body inspection 토글 |
| `crab_engine_set_throttle` | 네트워크 쓰로틀링 설정 |
| `crab_engine_set_client_allowlist` | LAN 클라이언트 IP 허용목록 |
| `crab_engine_set_transparent` | transparent 프록시 모드 설정 |
| `crab_engine_load_ca` | CA 인증서/키 파일 로드 |

**Traffic/Logging (3개):**
| 도구 | 설명 |
|------|------|
| `crab_logs_tail` | 구조화 로그 조회 (seq 기반 페이징) |
| `crab_traffic_tail` | HTTP(S) 트래픽 조회 (집계) |
| `crab_traffic_get` | 단일 트래픽 엔트리 조회 (request_id) |

**Rules — 조회 (5개):**
| 도구 | 설명 |
|------|------|
| `crab_rules_dump` | 전체 규칙 카테고리 조회 |
| `crab_rules_list_allow` | allowlist 규칙 조회 |
| `crab_rules_list_map_local` | map_local 규칙 조회 |
| `crab_rules_list_map_remote` | map_remote 규칙 조회 |
| `crab_rules_list_status_rewrite` | status_rewrite 규칙 조회 |

**Rules — 변경 (10개):**
| 도구 | 설명 |
|------|------|
| `crab_rules_clear` | 전체 규칙 초기화 |
| `crab_rules_add_allow` | allowlist 추가 |
| `crab_rules_remove_allow` | allowlist 삭제 |
| `crab_rules_add_map_local_text` | map_local (인라인 텍스트) 추가 |
| `crab_rules_add_map_local_file` | map_local (파일) 추가 |
| `crab_rules_remove_map_local` | map_local 삭제 |
| `crab_rules_add_map_remote` | map_remote 추가 |
| `crab_rules_remove_map_remote` | map_remote 삭제 |
| `crab_rules_add_status_rewrite` | status_rewrite 추가 |
| `crab_rules_remove_status_rewrite` | status_rewrite 삭제 |

**Advanced (1개):**
| 도구 | 설명 |
|------|------|
| `crab_rpc` | 원시 crabd RPC 패스스루 |

**기타 도구** (도구 목록 확장 시 여기 추가):
> 45개 = 3 + 3 + 7 + 3 + 5 + 10 + 1 = 32개 명시. 나머지 13개는 현재 코드의 세부 변형 도구(throttle 하위 옵션 등)로, Core 추출 시 정확히 열거.

### 7.2 검증 규칙

1. `tools/list` 결과가 stdio/HTTP에서 동일 (정렬 제외).
2. 동일 입력으로 `tools/call` 결과 `structuredContent`가 동일.
3. 에러 코드/메시지 포맷 일치 (§5 D6 참조).
4. traffic aggregation 결과가 동일 (같은 로그 입력 기준).

### 7.3 Parity 자동 테스트

```
1. crabd 시작
2. crab-mcp --transport both 시작
3. 동일 JSON-RPC 시퀀스를 stdio / HTTP 양쪽에 전송
4. 응답 비교 (id, structuredContent, isError)
5. 불일치 시 테스트 실패
```

---

## 8. 테스트 계획

### 8.1 단위 테스트

| 대상 | 테스트 항목 |
|------|------------|
| `mcp/tools.rs` | 도구 argument validation (필수/선택 파라미터, 타입 검증) |
| `mcp/error.rs` | 에러 코드 매핑 정확성 |
| `mcp/traffic.rs` | 로그 → 트래픽 엔트리 집계 정확성 |
| `mcp/http_transport.rs` | Bearer token 검증 (유효/무효/만료) |
| `mcp/http_transport.rs` | Origin 검증 (localhost 허용, 외부 거부) |
| `mcp/http_transport.rs` | 세션 생성/조회/만료/삭제 |
| `mcp/http_transport.rs` | CORS preflight 응답 헤더 |

### 8.2 통합 테스트

| 시나리오 | 설명 |
|----------|------|
| stdio 회귀 | 기존 handshake → tools/list → tools/call 시퀀스 검증 |
| HTTP initialize | POST /mcp initialize → Mcp-Session-Id 반환 확인 |
| HTTP tools/list | 세션 내 tools/list → 45개 도구 반환 확인 |
| HTTP tools/call | 세션 내 tools/call → 정상 응답 확인 |
| HTTP auth 거부 | 유효하지 않은 token → 401 확인 |
| HTTP session 만료 | TTL 초과 후 요청 → 401 확인 |
| Parity 비교 | 동일 시나리오를 stdio/HTTP 양쪽에서 실행, 결과 비교 |

### 8.3 E2E 테스트

| 시나리오 | 설명 |
|----------|------|
| 앱 → HTTP MCP ON | 앱에서 토글 ON → HTTP 서버 시작 → IDE 연결 → rules/traffic 조회 성공 |
| 앱 종료 → 정리 | 앱 종료 시 HTTP MCP 프로세스 종료 확인 |
| 포트 충돌 | 이미 사용 중인 포트 → 자동 탐색 또는 명확한 에러 |
| Token 오류 | 잘못된 token → 401 + 앱에서 에러 표시 |
| 동시 접속 | stdio + HTTP 동시 사용 시 상호 간섭 없음 |

---

## 9. 릴리즈 단계 (Gate)

### Gate 1: Core 분리 + stdio 회귀 무손상
- **완료 기준:**
  1. `src/mcp/` 모듈 구조 완성
  2. `src/bin/crab-mcp.rs`가 Core를 사용하도록 리팩터링
  3. 기존 stdio 동작 100% 유지 (회귀 테스트 통과)
  4. 도구 목록/결과 회귀 테스트 통과

### Gate 2: HTTP Transport 기능 완료
- **완료 기준:**
  1. `POST /mcp` initialize → tools/list → tools/call 정상
  2. Bearer token 인증 동작
  3. 세션 관리 (Mcp-Session-Id) 동작
  4. CORS / Origin 검증 동작
  5. 포트 충돌 처리 동작
  6. Parity 테스트 통과

### Gate 3: 앱 연동 완료
- **완료 기준:**
  1. 앱에서 HTTP MCP ON/OFF 가능
  2. endpoint/token 복사 가능
  3. IDE가 endpoint + token으로 연결 가능
  4. 앱 종료/재시작/오류 시 UX 검증

### Gate 4: 문서 및 최종 검증
- **완료 기준:**
  1. IDE별 설정 가이드 작성
  2. 트러블슈팅 문서 작성
  3. 전체 E2E 테스트 통과

---

## 10. 리스크와 대응

| # | 리스크 | 영향 | 대응 |
|---|--------|------|------|
| 1 | stdio와 HTTP 결과 불일치 | 사용자 혼란, 디버깅 어려움 | Core 단일화 + parity 자동 테스트 |
| 2 | 로컬 포트 노출 오남용 | 보안 취약점 | localhost 바인딩 + Bearer token + Origin 검증 |
| 3 | 앱-서버 라이프사이클 꼬임 | 좀비 프로세스, 리소스 누수 | SIGTERM graceful shutdown + 프로세스 모니터링 |
| 4 | 사용자 설정 복잡도 증가 | 온보딩 장벽 | 앱에서 endpoint/token 복사 UX + IDE 가이드 |
| 5 | `--transport both` 동시 실행 시 Core 동시성 이슈 | 데이터 레이스, 불일치 | McpCore를 `Arc`로 공유, bridge는 독립 세션 |
| 6 | Streamable HTTP 스펙 변경 | 호환성 깨짐 | MCP 스펙 버전 고정 (2024-11-05), 추후 마이그레이션 |
| 7 | 세션 메모리 누수 | 장시간 운영 시 OOM | TTL 기반 만료 + 주기적 정리 (60초 간격) |

---

## 11. 의존성 변경

### Cargo.toml 변경 없음 (예상)

기존 의존성으로 충분:
- `hyper` v1.7 — HTTP 서버
- `hyper-util` v0.1 — server auto, tokio runtime
- `tokio` v1.47 — async runtime, signal, sync
- `serde_json` — JSON-RPC 직렬화
- `uuid` v1.18 — 세션 ID 생성
- `hmac` + `sha2` — token 검증 (crabd 토큰 재사용)

추가 의존성이 필요한 경우:
- `tokio-stream` — SSE stream 구현 시 (필요 여부 WS2에서 판단)

---

## 12. 최종 수용 기준 (Definition of Done)

1. `stdio`와 `Streamable HTTP` 모두에서 동일한 45개 MCP tool 제공.
2. `--transport both`로 stdio + HTTP 동시 제공 가능.
3. 앱에서 HTTP MCP ON/OFF 및 endpoint/token 복사 가능.
4. rules/traffic 포함 주요 시나리오가 IDE에서 실사용 가능.
5. 보안 기본값 충족: localhost 바인딩 + Bearer token + Origin 검증 + scope.
6. 회귀 테스트에서 기존 stdio 사용성 저하 없음.
7. Parity 자동 테스트 통과.
8. IDE별 MCP 설정 가이드 제공.
