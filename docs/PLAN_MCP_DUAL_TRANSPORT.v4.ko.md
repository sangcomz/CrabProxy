# PLAN: MCP Dual Transport (stdio + Streamable HTTP) v4

## v3 → v4 변경 요약

| # | 리뷰 항목 | v3 상태 | v4 반영 |
|---|----------|---------|---------|
| 1 | tokio 런타임 모델 | 미언급 | WS1에 `current_thread` → `multi_thread` 전환 명시 |
| 2 | `DaemonBridge` `&mut self` 동시성 | 미언급 | WS1에 `&self` 전환 + `Arc` 공유 설계 명시 |
| 3 | bridge sync → async 전환 | 미언급 | WS1에 `block_on` 제거, async-native 전환 명시 |
| 4 | `both` supervisor 구체 전략 | "supervisor 구성" 수준 | `tokio::select!` + `JoinSet` 기반 설계 명시 |
| 5 | HTTP token principal 결정 | `mcp-http.token` 언급, 결정 불명확 | 기존 `mcp` principal/token 공유로 확정, 근거 명시 |
| 6 | `daemon.doctor` 구현 존재 확인 | 미확인 | crabd 구현 확인 완료, 도구 목록에 상태 주석 |
| 7 | 에러 코드 매핑 테이블 | 누락 | §5.7 에러 규약 섹션 복원 |
| 8 | 포트 충돌 자동 탐색 | 누락 | WS2 작업 항목에 포함 |
| 9 | 요청 속도 제한 | 누락 | 비목표(§2)에 명시적 제외 |
| 10 | 리스크 섹션 | 누락 | §10 리스크와 대응 복원 |

---

## 1. 목표

1. 단일 바이너리(`crab-mcp`)에서 `stdio`와 `Streamable HTTP`를 모두 지원한다.
2. 두 transport에서 **동일한 도구 집합(32개)과 동일한 의미/에러 규약**을 제공한다.
3. macOS 앱에서 HTTP MCP 서버를 시작/중지하고 endpoint/token 정보를 확인할 수 있게 한다.
4. 기존 stdio 워크플로우(Codex/IDE spawn 방식) 회귀를 0으로 유지한다.

## 2. 비목표 (v4 범위 제외)

1. 인터넷 공개 바인딩(공인 네트워크 노출) 운영.
2. 멀티 유저/조직 계정 인증 체계.
3. crabd IPC 프로토콜 자체 개편.
4. MCP 도구 의미(룰/트래픽 동작)의 대규모 변경.
5. `GET /mcp` SSE notification 채널 및 `DELETE /mcp` 세션 종료 (v5 후보).
6. IP 기반 요청 속도 제한 (localhost 전용이므로 우선순위 낮음, 필요 시 v5).

---

## 3. 현재 상태 (코드 기준)

### 3.1 핵심 파일

| 파일 | 줄 수 | 역할 |
|------|-------|------|
| `src/bin/crab-mcp.rs` | 1,486 | stdio MCP 서버 + 도구 정의/실행 + traffic 집계 |
| `src/daemon/mod.rs` | 1,681 | IPC 서버, 인증/scope, RPC dispatch |
| `src/ipc.rs` | 168 | RPC 프로토콜 타입 |
| `src/proxy.rs` | 2,380 | HTTP(S) 프록시 엔진 |
| `src/rules.rs` | 453 | 룰 타입/매칭 |
| `src/lib.rs` | 7 | `pub mod` 선언 (ca, config, daemon, ffi, ipc, proxy, rules) |

### 3.2 실제 MCP 도구 수

`crab-mcp.rs`의 `"name": "crab_*"` 정의 기준 **32개**.

### 3.3 crabd 브리지 실제 호출 흐름

```text
DaemonBridge.call(&mut self, method, params)
  1. ensure_daemon_started(daemon_path, socket_path)
  2. read_token_from_file(mcp.token)
  3. self.runtime.block_on(send_rpc(...))
       └─ send_rpc 내부:
           a. UnixStream::connect(socket_path)     ← 매번 새 연결
           b. system.handshake(token, principal)    ← 매번 새 세션
           c. 실제 RPC method 호출
           d. 연결 닫힘
```

**구현 특성 (v4 설계에 직접 영향):**

| 특성 | 현재 코드 | v4 영향 |
|------|-----------|---------|
| `DaemonBridge.call` 시그니처 | `&mut self` | HTTP 동시 요청 불가 → `&self`로 전환 필요 |
| tokio 런타임 | `new_current_thread()` | HTTP 서버 불가 → `new_multi_thread()` 전환 필요 |
| async 호출 방식 | `runtime.block_on(send_rpc(...))` | async 핸들러 내 block_on 금지 → async-native 전환 필요 |
| 연결 수명 | 호출당 1회 연결+해제 | MCP 세션과 crabd 세션은 독립 (변경 불필요) |

### 3.4 crabd 토큰/principal 체계

현재 `write_token_files()`는 3개 principal만 생성:

| principal | 파일 | scopes |
|-----------|------|--------|
| `app` | `app.token` | read, rules.write, control, admin |
| `cli` | `cli.token` | read, rules.write, control, admin |
| `mcp` | `mcp.token` | read, rules.write, control |

`default_token_path_for_principal()`도 `"app" | "cli" | "mcp"`만 허용, 그 외는 에러.

### 3.5 앱 구조

| 파일 | 역할 |
|------|------|
| `ProxyViewModel.swift` | `@MainActor final class ProxyViewModel: ObservableObject` — 상태/제어 |
| `SettingsView.swift` | 설정 UI |
| `CrabProxyMacApp.swift` | 앱 lifecycle (`willTerminate` 훅) |

---

## 4. 목표 아키텍처

```text
                    ┌──────────────────────────────────┐
IDE/Codex ─stdio──> │        StdioTransport (task)      │──┐
                    └──────────────────────────────────┘  │
                                                          │  ┌──────────────┐
                    ┌──────────────────────────────────┐  ├─>│              │
IDE/Tool ──HTTP──>  │    HttpTransport (hyper server)    │──┤  │   McpCore    │──IPC──> crabd
                    │  Bearer auth, Origin, CORS, Session│  │  │              │
                    └──────────────────────────────────┘  │  │ - ToolRegistry│
                              ▲                           │  │ - Validation  │
                              │                           │  │ - Execution   │
                    ┌─────────┴────────┐                  │  │ - TrafficAggr │
                    │ CrabProxyMacApp  │                  │  └──────┬───────┘
                    │ (start/stop,     │──────────────────┘         │
                    │  endpoint/token) │                     Arc<McpCore>
                    └──────────────────┘                  (async, &self, Send+Sync)
```

설계 원칙:

1. **단일 Core**: 도구 정의/검증/실행/에러 매핑을 `McpCore`에 집중. `Arc<McpCore>`로 transport 간 공유.
2. **transport = 어댑터**: 입출력 직렬화/역직렬화와 인증/세션만 담당.
3. **기존 재사용**: crabd API, 권한 모델, hyper 스택, `mcp` principal/token 그대로 활용.
4. **async-native**: bridge를 async로 전환하여 HTTP 핸들러에서 직접 await 가능.

---

## 5. 프로토콜/세션/보안/에러 결정

### 5.1 MCP 프로토콜 버전 정책

1. 서버 광고 버전: `2024-11-05`.
2. `initialize.params.protocolVersion`이 `2024-11-05`가 아니면 `-32602` 반환.
3. 에러 `data`에 `supported: ["2024-11-05"]`를 포함.

### 5.2 Streamable HTTP 세션 정책

**선택: stateful (MCP 레이어만)**

1. `initialize` 성공 시 `Mcp-Session-Id` 발급.
2. 이후 `POST /mcp`는 동일 `Mcp-Session-Id` 사용.
3. 세션 저장 항목: session_id, created_at, last_activity, client_info, capabilities.
4. **저장하지 않는 항목:** crabd bridge session/connection (매 호출마다 새 연결이므로 세션과 무관).
5. TTL: 30분(기본), 만료 시 HTTP 401 + JSON-RPC 에러 본문.
6. 세션 정리: 60초 간격 백그라운드 task가 만료 세션 제거.

### 5.3 HTTP 엔드포인트 (v4 범위)

| Method | Path | 설명 |
|--------|------|------|
| `POST` | `/mcp` | JSON-RPC 요청 처리 (Streamable HTTP) |
| `OPTIONS` | `/mcp` | CORS preflight |
| `GET` | `/healthz` | liveness check |

`GET /mcp` (SSE), `DELETE /mcp` (세션 종료)는 v4 범위 제외 (§2.5).

### 5.4 인증/보안 정책

**token 결정: 기존 `mcp` principal/token 공유**

근거:
1. stdio와 HTTP는 같은 MCP 서버의 다른 transport일 뿐, 권한 범위가 동일하다.
2. crabd의 `default_token_path_for_principal()`은 `"app" | "cli" | "mcp"`만 허용하며, 새 principal 추가는 crabd 변경이 필요하다 (§2.3 비목표: crabd 프로토콜 개편 제외).
3. `mcp.token` 공유로 사용자 설정 단순화 (token 파일 1개만 관리).

**보안 레이어:**

| # | 항목 | 정책 |
|---|------|------|
| 1 | 바인드 주소 | `127.0.0.1` 기본 (외부 NIC 미노출) |
| 2 | 인증 | `Authorization: Bearer <token>` 필수 (`mcp.token`, 권한 0600) |
| 3 | Origin 검증 | `Origin` 헤더 존재 시 `localhost` / `127.0.0.1`만 허용 |
| 4 | CORS | 허용 origin **정확 매칭 반사** (와일드카드 패턴 금지) |
| 5 | scope | 기존 `mcp` scope: `read`, `rules.write`, `control` |
| 6 | token 경로 | `--token-path`로 오버라이드 가능, 기본값은 `mcp.token` 경로 재사용 |

### 5.5 `--transport` 런타임 규칙

**CLI 옵션:**

```
crab-mcp [OPTIONS]

--transport <MODE>       stdio | http | both  (기본: stdio)
--http-bind <ADDR>       HTTP 바인드 주소     (기본: 127.0.0.1)
--http-port <PORT>       HTTP 포트            (기본: 3847)
--token-path <PATH>      토큰 파일 경로       (기본: mcp.token 경로)
```

**수명주기 규칙:**

| 모드 | 시작 조건 | 종료 조건 |
|------|-----------|-----------|
| `stdio` | stdin 준비 | stdin EOF → 프로세스 종료 |
| `http` | 포트 바인드 성공 | SIGINT/SIGTERM → graceful shutdown (최대 5초 대기) |
| `both` | stdio 준비 + 포트 바인드 **모두** 성공 | 아래 상세 규칙 참조 |

**`both` 모드 상세 규칙:**

| 이벤트 | 동작 |
|--------|------|
| stdio EOF | stdio task 종료, HTTP task 계속 유지, 로그 `transport=stdio event=eof` |
| HTTP 바인드 실패 (시작 시) | 프로세스 즉시 종료 (exit 1) |
| HTTP fatal 오류 (런타임) | HTTP task 종료, stdio task 계속 유지, 로그 `transport=http event=fatal` |
| SIGINT/SIGTERM | 모든 task 종료, graceful shutdown |
| stdio EOF + HTTP 종료 (모두 종료) | 프로세스 종료 |

### 5.6 런타임 모델 전환

| 항목 | 현재 (stdio only) | v4 (stdio/http/both) |
|------|-------------------|----------------------|
| tokio Runtime | `new_current_thread()` | `new_multi_thread()` (모든 모드 통일) |
| DaemonBridge 시그니처 | `call(&mut self, ...)` | `call(&self, ...)` |
| DaemonBridge async | `runtime.block_on(send_rpc(...))` | `async fn call(&self, ...) -> Result<Value>` |
| Core 공유 | 단일 소유 | `Arc<McpCore>` (Send + Sync) |

**전환 근거:**
- `send_rpc`는 이미 `async fn`이며, 매 호출마다 새 `UnixStream`을 여는 stateless 구조.
- `&mut self`는 내부 상태 변경이 없는데도 사용되고 있어 `&self`로 전환 가능.
- `runtime.block_on()`을 제거하면 async 핸들러 내에서 직접 `.await` 가능.
- `new_multi_thread()`로 통일하면 stdio-only 모드에서도 약간의 오버헤드가 있지만, 코드 경로 단일화와 테스트 동등성 확보에 유리.

### 5.7 에러 규약

**JSON-RPC 에러 코드 (MCP 레벨):**

| 상황 | code | message |
|------|------|---------|
| 알 수 없는 메서드 | `-32601` | `Method not found` |
| 잘못된 파라미터 | `-32602` | `Invalid params: {detail}` |
| crabd 연결 실패 | `-32603` | `Internal error: daemon unreachable` |
| 권한 부족 (scope) | `-32001` | `Forbidden: insufficient scope` |
| 프록시 미실행 | `-32002` | `Proxy not running` |
| 프록시 이미 실행 중 | `-32003` | `Proxy already running` |
| tool 실행 실패 | `-32004` | `Tool execution failed: {detail}` |
| 프로토콜 버전 불일치 | `-32602` | `Invalid params: unsupported protocol version` |

**HTTP 에러 (transport 레벨):**

| 상황 | HTTP status | body |
|------|-------------|------|
| token 누락/무효 | `401` | `{"error": "invalid or missing token"}` |
| Origin 거부 | `403` | `{"error": "origin not allowed"}` |
| Content-Type 불일치 | `415` | `{"error": "expected application/json"}` |
| 세션 만료/무효 | `401` | `{"error": "session expired or invalid"}` |
| 세션 미제공 (initialize 외) | `400` | `{"error": "missing Mcp-Session-Id header"}` |
| 서버 내부 오류 | `500` | `{"error": "{detail}"}` |

**규칙:** 동일한 tool 호출에 대해 stdio와 HTTP는 JSON-RPC 레벨 에러 코드/메시지가 반드시 동일해야 한다. HTTP-only 에러(401, 403, 415)는 transport 레벨에서만 발생하며 JSON-RPC 응답 이전에 처리된다.

---

## 6. 도구 목록 (32개, 코드 기준)

### 6.1 System (3)

| # | 도구 | crabd method | crabd 구현 |
|---|------|-------------|------------|
| 1 | `crab_ping` | `system.ping` | ✅ |
| 2 | `crab_version` | `system.version` | ✅ |
| 3 | `crab_daemon_doctor` | `daemon.doctor` | ✅ (daemon/mod.rs:1122) |

### 6.2 Proxy Control (3)

| # | 도구 | crabd method | crabd 구현 |
|---|------|-------------|------------|
| 4 | `crab_proxy_status` | `proxy.status` | ✅ |
| 5 | `crab_proxy_start` | `proxy.start` | ✅ |
| 6 | `crab_proxy_stop` | `proxy.stop` | ✅ |

### 6.3 Engine Config (7)

| # | 도구 | crabd method | crabd 구현 |
|---|------|-------------|------------|
| 7 | `crab_engine_config_get` | `engine.config_dump` | ✅ |
| 8 | `crab_engine_set_listen_addr` | `engine.set_listen_addr` | ✅ |
| 9 | `crab_engine_set_inspect_enabled` | `engine.set_inspect_enabled` | ✅ |
| 10 | `crab_engine_set_throttle` | `engine.set_throttle` | ✅ |
| 11 | `crab_engine_set_client_allowlist` | `engine.set_client_allowlist` | ✅ |
| 12 | `crab_engine_set_transparent` | `engine.set_transparent` | ✅ |
| 13 | `crab_engine_load_ca` | `engine.load_ca` | ✅ |

### 6.4 Logs/Traffic (3)

| # | 도구 | crabd method | crabd 구현 |
|---|------|-------------|------------|
| 14 | `crab_logs_tail` | `logs.tail` | ✅ |
| 15 | `crab_traffic_tail` | `logs.tail` + 클라이언트 집계 | ✅ (집계는 MCP side) |
| 16 | `crab_traffic_get` | `logs.tail` + 필터 | ✅ (필터는 MCP side) |

### 6.5 Rules Read (5)

| # | 도구 | crabd method | crabd 구현 |
|---|------|-------------|------------|
| 17 | `crab_rules_dump` | `engine.rules_dump` | ✅ |
| 18 | `crab_rules_list_allow` | `engine.rules_dump` + 필터 | ✅ |
| 19 | `crab_rules_list_map_local` | `engine.rules_dump` + 필터 | ✅ |
| 20 | `crab_rules_list_map_remote` | `engine.rules_dump` + 필터 | ✅ |
| 21 | `crab_rules_list_status_rewrite` | `engine.rules_dump` + 필터 | ✅ |

### 6.6 Rules Write (10)

| # | 도구 | crabd method | crabd 구현 |
|---|------|-------------|------------|
| 22 | `crab_rules_clear` | `engine.rules_clear` | ✅ |
| 23 | `crab_rules_add_allow` | `engine.rules_add_allow` | ✅ |
| 24 | `crab_rules_remove_allow` | `engine.rules_remove_allow` | ✅ |
| 25 | `crab_rules_add_map_local_text` | `engine.rules_add_map_local_text` | ✅ |
| 26 | `crab_rules_add_map_local_file` | `engine.rules_add_map_local_file` | ✅ |
| 27 | `crab_rules_remove_map_local` | `engine.rules_remove_map_local` | ✅ |
| 28 | `crab_rules_add_map_remote` | `engine.rules_add_map_remote` | ✅ |
| 29 | `crab_rules_remove_map_remote` | `engine.rules_remove_map_remote` | ✅ |
| 30 | `crab_rules_add_status_rewrite` | `engine.rules_add_status_rewrite` | ✅ |
| 31 | `crab_rules_remove_status_rewrite` | `engine.rules_remove_status_rewrite` | ✅ |

### 6.7 Advanced (1)

| # | 도구 | crabd method | crabd 구현 |
|---|------|-------------|------------|
| 32 | `crab_rpc` | (동적) | ✅ (passthrough) |

**합계: 3 + 3 + 7 + 3 + 5 + 10 + 1 = 32**

---

## 7. 구현 계획

### WS1. McpCore 분리 + 런타임/브리지 전환

**목표:** `crab-mcp.rs` 1,486줄을 transport 무관 Core와 transport adapter로 분리하고, 동시성 지원을 위한 런타임/브리지 구조 전환.

**목표 구조:**

```text
src/
├── mcp/
│   ├── mod.rs               # pub mod 선언
│   ├── core.rs              # McpCore: handle_request, tools_list
│   ├── tools.rs             # ToolRegistry: 32개 도구 스키마 + validation + call_tool
│   ├── bridge.rs            # McpBridge: async fn call(&self, ...) -> Result<Value>
│   ├── traffic.rs           # TrafficAggregator: logs → grouped traffic entries
│   ├── types.rs             # McpRequest, McpResponse, ToolResult 등 공통 타입
│   ├── error.rs             # McpError + JSON-RPC 에러 코드 매핑 (§5.7)
│   ├── transport_stdio.rs   # stdio framed read/write adapter
│   ├── transport_http.rs    # HTTP server + auth + session + CORS (WS2)
│   └── session.rs           # HttpSessionManager: TTL 기반 세션 (WS2)
├── bin/
│   └── crab-mcp.rs          # CLI 파싱 + transport wiring (~150줄 이하)
├── lib.rs                   # + pub mod mcp;
```

**작업:**

| # | 작업 | 상세 |
|---|------|------|
| 1 | **런타임 전환** | `new_current_thread()` → `new_multi_thread()`. 모든 `--transport` 모드에서 동일 런타임 사용. |
| 2 | **DaemonBridge async 전환** | `block_on(send_rpc(...))` 제거. `async fn call(&self, method, params) -> Result<Value>` 로 변경. `send_rpc`가 이미 async이며 매번 새 연결을 열어 내부 상태가 없으므로 `&self`로 전환 가능. |
| 3 | `types.rs` | 공통 타입 정의 (McpRequest, McpResponse, ToolCallResult 등) |
| 4 | `error.rs` | McpError enum + JSON-RPC 에러 코드 매핑 (§5.7 테이블 기반) |
| 5 | `bridge.rs` | `send_rpc` 기반 async bridge. `Arc<McpBridge>` 로 공유 가능. |
| 6 | `tools.rs` | `tool_definitions()` + `call_tool()` + argument validation 추출 |
| 7 | `traffic.rs` | `crab_traffic_tail` / `crab_traffic_get` 집계 로직 추출 |
| 8 | `core.rs` | `McpCore { bridge, tools, traffic }` + `async fn handle_request(&self, ...)` |
| 9 | `transport_stdio.rs` | 기존 framed read/write + main loop 추출 |
| 10 | `crab-mcp.rs` 정리 | CLI 파싱 + `McpCore` 생성 + transport 실행만 남김 |
| 11 | **stdio 회귀 테스트** | 분리 전/후 동일 입출력 검증 |

**McpBridge 전환 전후:**

```rust
// Before (v3 현재)
struct DaemonBridge {
    socket_path: PathBuf,
    daemon_path: PathBuf,
    token_path: PathBuf,
    principal: String,
    ensure_daemon: bool,
    runtime: tokio::runtime::Runtime,  // ← 제거
}
impl DaemonBridge {
    fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        // ...
        self.runtime.block_on(send_rpc(...))  // ← blocking
    }
}

// After (v4)
struct McpBridge {
    socket_path: PathBuf,
    daemon_path: PathBuf,
    token_path: PathBuf,
    principal: String,
    ensure_daemon: bool,
}
impl McpBridge {
    async fn call(&self, method: &str, params: Value) -> Result<Value> {
        if self.ensure_daemon {
            ensure_daemon_started(&self.daemon_path, &self.socket_path)?;
        }
        let token = read_token_from_file(&self.token_path)?;
        send_rpc(&self.socket_path, &token, &self.principal, method, params).await
    }
}
```

**McpCore 공유:**

```rust
let core = Arc::new(McpCore::new(bridge, tool_registry, traffic_aggregator));

// stdio task
let core_stdio = Arc::clone(&core);
let stdio_handle = tokio::spawn(async move {
    transport_stdio::run(core_stdio, stdin, stdout).await
});

// http task (--transport http | both)
let core_http = Arc::clone(&core);
let http_handle = tokio::spawn(async move {
    transport_http::run(core_http, bind_addr, port, token_path).await
});
```

### WS2. HTTP Transport 구현

**재사용 의존성 (추가 crate 없음):**

- `hyper` v1.7 — HTTP 서버 (`service_fn`)
- `hyper-util` v0.1 — `server::conn::auto::Builder`
- `http-body-util` v0.1 — body 유틸리티
- `tokio` v1.47 — `TcpListener`, `signal`, `sync`
- `serde_json` — JSON-RPC
- `uuid` v1.18 — 세션 ID 생성

**작업:**

| # | 작업 | 상세 |
|---|------|------|
| 1 | `transport_http.rs` 골격 | `hyper::service::service_fn` 기반 TCP 서버. `TcpListener::bind` → accept loop. |
| 2 | Bearer token 인증 | `Authorization` 헤더 파싱 → `mcp.token` 파일 내용과 비교. 불일치 시 401. |
| 3 | Origin 검증 | `Origin` 헤더 존재 시 host가 `localhost` 또는 `127.0.0.1`인지 확인. 불일치 시 403. |
| 4 | CORS preflight | `OPTIONS /mcp` → `Access-Control-Allow-Origin` (요청 Origin 반사), `Allow-Methods: POST`, `Allow-Headers: Authorization, Content-Type, Mcp-Session-Id`. |
| 5 | `POST /mcp` 처리 | Content-Type 검증 → JSON body 파싱 → 세션 검증 → `McpCore.handle_request()` → JSON 응답. |
| 6 | `session.rs` | `HttpSessionManager`: `HashMap<String, HttpSession>` + `RwLock`. 60초 간격 정리 task. |
| 7 | `Mcp-Session-Id` 발급 | `initialize` 요청 성공 시 UUID v4 세션 ID 생성, 응답 헤더에 포함. |
| 8 | `Mcp-Session-Id` 검증 | `initialize` 외 요청에서 헤더 필수. 미제공 시 400, 무효/만료 시 401. |
| 9 | `GET /healthz` | `200 OK` + `{"status": "ok"}`. 인증 불필요. |
| 10 | **포트 충돌 자동 탐색** | 기본 포트(3847) `bind` 실패 시 3848~3857 순차 시도. 모두 실패 시 에러 메시지 + exit 1. |
| 11 | Graceful shutdown | `tokio::signal` 수신 시 새 연결 거부 + 활성 요청 완료 대기 (최대 5초). |

### WS3. `both` 모드 supervisor

**구체 전략: `tokio::select!` 기반**

```rust
// crab-mcp.rs (simplified)
async fn run_both(core: Arc<McpCore>, stdio_io, http_config) -> Result<()> {
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    let core_s = Arc::clone(&core);
    let mut stdio_handle = tokio::spawn(async move {
        transport_stdio::run(core_s, stdin, stdout).await
    });

    let core_h = Arc::clone(&core);
    let rx = shutdown_rx.clone();
    let mut http_handle = tokio::spawn(async move {
        transport_http::run(core_h, http_config, rx).await
    });

    tokio::select! {
        res = &mut stdio_handle => {
            tracing::info!(transport = "stdio", event = "eof", "stdio transport ended");
            // stdio 종료 → HTTP 계속 유지, HTTP 종료 대기
            match http_handle.await {
                Ok(Ok(())) => Ok(()),
                Ok(Err(e)) => Err(e),
                Err(e) => Err(e.into()),
            }
        }
        res = &mut http_handle => {
            match res {
                Ok(Err(e)) => {
                    tracing::error!(transport = "http", event = "fatal", "HTTP fatal: {e}");
                    // HTTP fatal → stdio 계속 유지, stdio 종료 대기
                    stdio_handle.await??;
                    Ok(())
                }
                _ => {
                    // HTTP 정상 종료 (signal) → 전체 종료
                    shutdown_tx.send(true)?;
                    stdio_handle.abort();
                    Ok(())
                }
            }
        }
        _ = tokio::signal::ctrl_c() => {
            tracing::info!(event = "signal", "shutdown signal received");
            shutdown_tx.send(true)?;
            // 두 task 모두 graceful 종료 대기
            let _ = tokio::time::timeout(
                Duration::from_secs(5),
                futures_util::future::join(stdio_handle, http_handle)
            ).await;
            Ok(())
        }
    }
}
```

**종료 상태 코드:**

| 상황 | exit code |
|------|-----------|
| 정상 종료 (signal/EOF) | 0 |
| HTTP 바인드 실패 (시작 시) | 1 |
| crabd 연결 불가 | 1 |
| 예상치 못한 panic | 101 |

**로그 키워드 통일:**

| 필드 | 값 |
|------|-----|
| `transport` | `stdio` \| `http` |
| `event` | `start` \| `stop` \| `eof` \| `fatal` \| `request` \| `session_expired` |

### WS4. 앱 연동 (실제 Swift 구조 기준)

**신규 파일:**

| 파일 | 역할 |
|------|------|
| `MCPHttpService.swift` | HTTP MCP 프로세스 관리 |

**기존 파일 변경:**

| 파일 | 변경 |
|------|------|
| `ProxyViewModel.swift` | `mcpHttpService` 속성 추가, MCP 상태 노출 |
| `SettingsView.swift` | MCP HTTP 설정 UI 섹션 추가 |
| `CrabProxyMacApp.swift` | `willTerminate`에서 MCP 프로세스 종료 호출 |

**MCPHttpService 설계:**

```swift
@MainActor
final class MCPHttpService: ObservableObject {
    @Published var isRunning = false
    @Published var endpoint: String?        // "http://127.0.0.1:3847/mcp"
    @Published var tokenFilePath: String?
    @Published var lastError: String?
    @Published var port: UInt16 = 3847

    private var process: Process?

    func start() { /* spawn crab-mcp --transport http --http-port <port> */ }
    func stop()  { /* SIGTERM → process.waitUntilExit() */ }

    func copyEndpointToClipboard() { /* NSPasteboard */ }
    func copyTokenToClipboard()    { /* read token file → NSPasteboard */ }
}
```

**프로세스 관리:**
- `Process` (Foundation)로 `crab-mcp --transport http --http-port <port>` spawn.
- stdout/stderr 파이프로 상태 모니터링 (`isRunning`, `lastError`).
- `willTerminate`에서 `process.terminate()` (SIGTERM) → `waitUntilExit()`.

**UI 항목:**

| 요소 | 설명 |
|------|------|
| `Enable MCP (HTTP)` 토글 | HTTP MCP 서버 시작/중지 |
| Endpoint 표시 | `http://127.0.0.1:<port>/mcp` + 복사 버튼 |
| Token 표시 | 파일 경로 + 값 복사 버튼 |
| Port 설정 | 기본 3847, 사용자 변경 가능 |
| 상태 | Running / Stopped / Error |
| 에러 메시지 | 마지막 에러 (port in use, daemon unreachable 등) |
| IDE 설정 가이드 | 클릭 시 설정 JSON 예시 표시 |

### WS5. 문서/운영 가이드

| # | 작업 |
|---|------|
| 1 | stdio 연결 가이드 (기존 방식, IDE별 설정 예시) |
| 2 | HTTP 연결 가이드 (endpoint/token 설정, IDE별 예시) |
| 3 | `--transport both` 운용 가이드 |
| 4 | 트러블슈팅 (401, token 권한, 포트 충돌, daemon unreachable, 세션 만료) |
| 5 | `crab-mcp --help` 출력 업데이트 |

---

## 8. 도구 동등성(Parity) 정책

### 8.1 검증 규칙

1. `tools/list` 결과의 도구 집합이 동일 (32개, 정렬 무관).
2. 동일 입력의 `tools/call` 결과 `structuredContent`가 동일.
3. JSON-RPC 에러 코드/메시지 규약이 동일 (§5.7).
4. `crab_traffic_tail` / `crab_traffic_get` 집계 결과가 동일 (같은 로그 입력 기준).

### 8.2 Parity 자동 테스트

```text
1. crabd 시작
2. crab-mcp --transport both 시작
3. 동일 JSON-RPC 시퀀스를 stdio / HTTP 양쪽에 전송
4. 응답 비교 (id, structuredContent, isError)
5. 불일치 시 테스트 실패
```

---

## 9. 테스트 계획

### 9.1 단위 테스트

| 대상 | 테스트 항목 |
|------|------------|
| `tools.rs` | 32개 도구 argument validation (필수/선택, 타입, 범위) |
| `error.rs` | 에러 코드 매핑 (§5.7 테이블의 모든 케이스) |
| `traffic.rs` | 로그 → 트래픽 엔트리 집계 정확성 |
| `bridge.rs` | `McpBridge.call(&self, ...)` async 동작 검증 |
| `transport_http.rs` | Bearer token 검증 (유효/무효/누락) |
| `transport_http.rs` | Origin 검증 (localhost 허용, 외부 거부, 헤더 없음 허용) |
| `session.rs` | 세션 생성/조회/만료/정리 |
| `transport_http.rs` | CORS preflight 응답 헤더 |

### 9.2 통합 테스트

| 시나리오 | 설명 |
|----------|------|
| stdio 회귀 | 기존 initialize → tools/list → tools/call 시퀀스 검증 |
| HTTP initialize | `POST /mcp` initialize → `Mcp-Session-Id` 반환 확인 |
| HTTP tools/list | 세션 내 tools/list → 32개 도구 반환 확인 |
| HTTP tools/call | 세션 내 tools/call → 정상 응답 확인 |
| HTTP auth 거부 | 무효 token → 401 확인 |
| HTTP session 만료 | TTL 초과 후 요청 → 401 확인 |
| HTTP 포트 충돌 | 사용 중 포트 → 자동 탐색 또는 에러 메시지 확인 |
| Parity 비교 | 32개 도구 샘플을 stdio/HTTP 양쪽에서 실행, 결과 diff |

### 9.3 E2E 테스트

| 시나리오 | 설명 |
|----------|------|
| 앱 → HTTP MCP ON | 앱에서 토글 → HTTP 서버 시작 → IDE 연결 → rules/traffic 조회 |
| 앱 종료 → 정리 | 앱 종료 시 HTTP MCP 프로세스 종료 확인 |
| both 모드 stdio EOF | stdio EOF 후 HTTP 계속 동작 확인 |
| both 모드 동시 접속 | stdio + HTTP 동시 tool 호출 시 상호 간섭 없음 |

---

## 10. 리스크와 대응

| # | 리스크 | 영향 | 대응 |
|---|--------|------|------|
| 1 | stdio/HTTP 결과 불일치 | 사용자 혼란, 디버깅 어려움 | Core 단일화 + parity 자동 테스트 |
| 2 | `Arc<McpCore>` 동시성 문제 | 데이터 레이스, 불일치 | bridge가 stateless(매번 새 연결)이므로 내부 lock 불필요. traffic 집계만 주의. |
| 3 | 로컬 포트 노출 오남용 | 보안 취약점 | localhost 바인딩 + Bearer token + Origin 검증 |
| 4 | 앱-서버 라이프사이클 꼬임 | 좀비 프로세스, 리소스 누수 | SIGTERM graceful shutdown + `willTerminate` 훅 + 프로세스 모니터링 |
| 5 | 세션 메모리 누수 | 장시간 운영 시 OOM | TTL 30분 + 60초 간격 정리 task |
| 6 | `new_multi_thread()` 전환 회귀 | stdio-only 모드에서 예상치 못한 동작 변경 | 전환 후 기존 stdio 테스트 전량 실행 |
| 7 | MCP 프로토콜 스펙 변경 | 호환성 깨짐 | `2024-11-05` 버전 고정, 새 버전 대응은 별도 작업 |

---

## 11. 릴리즈 단계 (Gate)

### Gate 1: Core 분리 + 런타임 전환 + stdio 회귀 무손상

**완료 기준:**
1. `src/mcp/` 모듈 구조 완성.
2. `McpBridge`가 `async fn call(&self, ...)` 시그니처로 동작.
3. tokio `new_multi_thread()` 런타임으로 전환.
4. `crab-mcp --transport stdio`가 기존과 100% 동일하게 동작.
5. 도구 목록/결과 회귀 테스트 통과.

### Gate 2: HTTP Transport 기능 완료

**완료 기준:**
1. `POST /mcp` initialize → tools/list → tools/call 정상.
2. Bearer token 인증 동작.
3. 세션 관리 (`Mcp-Session-Id`) 동작.
4. CORS / Origin 검증 동작.
5. 포트 충돌 자동 탐색 동작.
6. Parity 테스트 (stdio vs HTTP) 통과.

### Gate 3: `both` 모드 + 앱 연동 완료

**완료 기준:**
1. `--transport both` 모드에서 stdio + HTTP 동시 제공.
2. stdio EOF → HTTP 계속 유지 동작 확인.
3. 앱에서 HTTP MCP ON/OFF 가능.
4. endpoint/token 복사 가능.
5. 앱 종료 시 MCP 프로세스 종료 확인.

### Gate 4: 문서 및 최종 검증

**완료 기준:**
1. IDE별 설정 가이드 (Claude Desktop, Cursor, Codex) 작성.
2. 트러블슈팅 문서 작성.
3. 전체 E2E 테스트 통과.

---

## 12. 최종 수용 기준 (DoD)

1. `stdio`와 `Streamable HTTP` 모두에서 동일한 32개 MCP tool 제공.
2. `--transport both`로 stdio + HTTP 동시 제공 가능.
3. 앱에서 HTTP MCP ON/OFF 및 endpoint/token 복사 가능.
4. rules/traffic 포함 주요 시나리오가 IDE에서 실사용 가능.
5. 보안 기본값 충족: localhost 바인딩 + Bearer token + Origin 검증 + scope.
6. 회귀 테스트에서 기존 stdio 사용성 저하 없음.
7. Parity 자동 테스트 통과 (32개 도구, 에러 코드 포함).
8. IDE별 MCP 설정 가이드 제공.

---

## 13. 오픈 이슈

1. `initialize`에서 `2024-11-05` 외 버전을 허용할지 (엄격 모드 vs 호환 모드).
2. HTTP 세션 저장소를 메모리만 사용할지(현재안) 또는 선택적 영속 저장을 둘지.
3. `GET /mcp` SSE/notification 채널을 v5로 미룰지 여부.
4. `ensure_daemon_started`의 blocking 파일시스템 호출을 `tokio::task::spawn_blocking`으로 감쌀지, 또는 async로 재작성할지.

---

## 14. 일정 (러프)

| WS | 작업 | 예상 |
|----|------|------|
| WS1 | Core 분리 + 런타임/브리지 전환 | 2~3일 |
| WS2 | HTTP Transport 구현 | 2~3일 |
| WS3 | both 모드 supervisor | 1일 |
| WS4 | 앱 연동 | 1~1.5일 |
| WS5 | 문서/가이드 | 0.5일 |

총 6.5~9일 (병렬도에 따라 변동).
