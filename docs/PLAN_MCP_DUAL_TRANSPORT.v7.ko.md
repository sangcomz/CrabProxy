# PLAN: MCP Dual Transport (stdio + Streamable HTTP) v7

## v6 → v7 변경 요약

| # | v6 이슈 | v7 반영 |
|---|---|---|
| 1 | stdio thread 종료 경로에서 hang 가능 (`join` 무기한 대기) | **종료 정책 확정**: signal/HTTP fatal 경로에서는 stdio thread 무한 join 금지(즉시 종료 경로), EOF 경로에서만 join |
| 2 | `run_both` 예시가 `JoinHandle` 소유 규칙상 컴파일 불가 | **`JoinSet` 기반 supervisor로 재작성**(move 충돌 없는 패턴) |
| 3 | stdio channel 타입/사용법 불일치 (`Value` vs `StdioRequest`, sync thread에서 async `send`) | **채널 계약 고정**: `mpsc::Sender<StdioRequest>::blocking_send` + `std::sync::mpsc::Sender<Option<Value>>` 응답 채널 |
| 4 | 앱 기본 `--ensure-daemon false` 정책 위험 | **앱 기본값 변경**: `--ensure-daemon true` 기본. readiness 확인 시에만 선택적으로 false |
| 5 | CORS 세부 응답 규약 미완성 | `Vary: Origin` 추가, JSON 응답 Content-Type 규약 유지 |

---

## 1. 목표

1. 단일 바이너리(`crab-mcp`)에서 `stdio`와 Streamable HTTP를 모두 지원한다.
2. 두 transport에서 동일한 MCP 도구 집합(32개)과 동작/에러 규약을 보장한다.
3. macOS 앱에서 HTTP MCP 서버를 시작/중지하고 endpoint/token을 확인할 수 있게 한다.
4. 기존 stdio 워크플로우 회귀를 0으로 유지한다.

## 2. 비목표 (v7 범위 제외)

1. 인터넷 공개 바인딩(공인 네트워크 노출).
2. 멀티 유저/조직 인증 모델.
3. crabd IPC 프로토콜 자체 개편.
4. `GET /mcp` SSE notification 채널 및 `DELETE /mcp` 세션 종료.
5. 응답 body spool 원본 조회(현재는 preview 중심).

---

## 3. 현재 상태 (코드 기준)

### 3.1 핵심 파일

| 파일 | 줄 수 | 역할 |
|---|---:|---|
| `src/bin/crab-mcp.rs` | 1486 | stdio MCP 서버, 도구 정의/실행, traffic 집계 |
| `src/daemon/mod.rs` | 1681 | daemon IPC, 인증/scope, RPC dispatch |
| `src/ipc.rs` | 168 | IPC 타입 |
| `src/proxy.rs` | 2380 | 프록시 엔진 |
| `src/rules.rs` | 453 | 룰 타입/매칭 |

### 3.2 현재 제약

| # | 제약 | 코드 위치 | v7 영향 |
|---|---|---|---|
| 1 | `DaemonBridge.call(&mut self)` + `runtime.block_on(send_rpc(...))` | `crab-mcp.rs:46-64` | async `&self` 전환 |
| 2 | 런타임 `new_current_thread()` | `crab-mcp.rs:84` | `new_multi_thread()` 전환 |
| 3 | `ensure_daemon_started` blocking (spawn + sleep 폴링) | `daemon/mod.rs:1651-1677` | `spawn_blocking` 격리 |
| 4 | token read sync I/O | `daemon/mod.rs:1641-1649` | `tokio::fs` 전환 |
| 5 | stdio lock 타입 `!Send` | `crab-mcp.rs:98-101` | 전용 OS thread + channel |
| 6 | `initialize.protocolVersion` 미검증 | `crab-mcp.rs:148` | lenient 유지 |
| 7 | principal/token 기본 체계 `app|cli|mcp` | `daemon/mod.rs:1559-1563` | `mcp` token 공유 |

---

## 4. 목표 아키텍처

```text
                        ┌──────────────────────────────────────┐
                        │          std::thread                  │
IDE/Codex ──stdin───>   │  StdioTransport (sync framing)        │
           <──stdout──  │  - blocking read/write                │
                        │  - blocking_send(request)             │
                        └──────────────┬───────────────────────┘
                                       │ tokio mpsc
                                       v
                        ┌──────────────────────────┐
                        │       McpCore (async)     │──IPC──> crabd
                        │  Arc<McpCore>, Send+Sync  │
                        └──────────────────────────┘
                                       ^
                                       │
                        ┌──────────────┴───────────────────────┐
IDE/Tool ──HTTP──>      │  HttpTransport (tokio task)           │
                        │  hyper + auth + CORS + session        │
                        └──────────────────────────────────────┘
```

원칙:

1. `McpCore`에 도구 정의/검증/실행/에러 매핑을 집중한다.
2. stdio/HTTP는 transport adapter 역할만 수행한다.
3. HTTP 세션과 crabd 연결 세션을 분리한다.
4. stdio는 sync I/O를 유지하되 async Core와는 channel로 연결한다.

---

## 5. 설계 결정

### 5.1 MCP 프로토콜 버전 정책

**결정: lenient 유지 (회귀 0 우선)**

| 입력 | 동작 |
|---|---|
| `2024-11-05` | 정상 |
| 다른 버전 | 경고 로그 후 정상 |
| 누락 | 정상 |

설명:
1. 현행 동작과의 호환을 우선한다.
2. strict 전환은 로그 근거 축적 후 별도 릴리즈에서 판단한다.

### 5.2 Streamable HTTP 세션 정책

1. `initialize` 성공 시 `Mcp-Session-Id` 발급.
2. 이후 `POST /mcp`는 동일 `Mcp-Session-Id` 사용.
3. 세션 저장 항목: session_id, created_at, last_activity, client_info, capabilities.
4. 저장 금지 항목: crabd bridge session/connection state.
5. TTL 30분, 60초 간격 만료 청소.

자료구조:

```rust
struct HttpSession {
    id: String,
    created_at: Instant,
    last_activity: Instant,
    client_info: Option<Value>,
    capabilities: Option<Value>,
}

struct SessionManager {
    sessions: Arc<RwLock<HashMap<String, HttpSession>>>,
    ttl: Duration,
}
```

### 5.3 HTTP 엔드포인트/응답 규약

| Method | Path | 요청 Content-Type | 응답 Content-Type | 설명 |
|---|---|---|---|---|
| `POST` | `/mcp` | `application/json` | `application/json` (요청 처리 시) | JSON-RPC |
| `OPTIONS` | `/mcp` | - | body 없음 | CORS preflight |
| `GET` | `/healthz` | - | `application/json` | liveness |

#### 5.3.1 Notification 처리

| 상황 | 응답 |
|---|---|
| 유효한 notification(id 없음) | `204 No Content` |
| 알 수 없는 notification(id 없음) | `204 No Content` + warn log |
| notification + session header 누락 | `400` |

### 5.4 인증/CORS

1. bind 기본값 `127.0.0.1`.
2. `Authorization: Bearer <token>` 필수 (`mcp.token`, 0600).
3. `Origin` 존재 시 `localhost`/`127.0.0.1`만 허용.
4. CORS 허용 origin은 exact reflection.

Preflight 헤더:

1. `Access-Control-Allow-Origin`
2. `Access-Control-Allow-Methods: POST, OPTIONS`
3. `Access-Control-Allow-Headers: Authorization, Content-Type, Mcp-Session-Id`
4. `Access-Control-Max-Age: 86400`
5. `Vary: Origin`

금지:

1. `Allow-Methods`, `Allow-Headers` 같은 비표준 축약형.
2. `Access-Control-Allow-Origin: http://localhost:*` 패턴.

### 5.5 McpBridge 동시성/안정성

구조:

```rust
struct McpBridge {
    socket_path: PathBuf,
    daemon_path: PathBuf,
    token_path: PathBuf,
    principal: String,
    ensure_daemon: bool,
    daemon_start_lock: tokio::sync::Mutex<()>,
}
```

알고리즘:

```text
async fn call(&self, method, params)
  if ensure_daemon:
    quick check(can_connect_socket)
    lock(daemon_start_lock)
    quick check again
    if still down: spawn_blocking(ensure_daemon_started)
  token = tokio::fs::read_to_string(token_path).await
  send_rpc(...).await
```

규칙:
1. `&self` API 유지(공유 가능).
2. daemon start는 double-check + mutex 보호.
3. blocking start는 `spawn_blocking`으로 격리.
4. token read는 async 파일 I/O 사용.

### 5.6 stdio transport 전략 (수정본)

#### 5.6.1 채널 계약 (일관성 고정)

```rust
struct StdioRequest {
    message: Value,
    response_tx: std::sync::mpsc::Sender<Option<Value>>,
}

let (request_tx, request_rx) = tokio::sync::mpsc::channel::<StdioRequest>(16);
```

stdio thread:

```rust
loop {
    let message = read_framed_message(&mut reader)?;          // blocking
    let (resp_tx, resp_rx) = std::sync::mpsc::channel();
    request_tx.blocking_send(StdioRequest {
        message,
        response_tx: resp_tx,
    })?;
    let response = resp_rx.recv()?;                           // blocking
    if let Some(value) = response {
        write_framed_message(&mut writer, &value)?;
    }
}
```

async dispatch task:

```rust
while let Some(req) = request_rx.recv().await {
    let response = core.handle_message(req.message).await;
    let _ = req.response_tx.send(response);
}
```

#### 5.6.2 종료 정책 (hang 방지)

1. stdio EOF/parse error 경로: stdio thread 종료를 확인하고 join 수행.
2. signal/HTTP fatal 경로: **stdio thread join을 기다리지 않는다**.
3. 이유: `stdin.lock()` blocking read는 외부 입력 없으면 즉시 중단 불가이며, 무한 join은 프로세스 종료를 지연시킨다.
4. 프로세스 종료 시 OS가 thread를 정리하므로 leak로 보지 않는다.

### 5.7 런타임 모델

| 항목 | 현재 | v7 |
|---|---|---|
| tokio runtime | `new_current_thread()` | `new_multi_thread()` |
| bridge API | `fn call(&mut self, ...)` | `async fn call(&self, ...)` |
| send path | `runtime.block_on(send_rpc(...))` | `send_rpc(...).await` |
| token read | sync fs | `tokio::fs` |
| stdio I/O | main thread sync | 전용 std::thread + `blocking_send` |
| core ownership | 단일 소유 | `Arc<McpCore>` |

### 5.8 `both` supervisor (컴파일 가능한 패턴)

정책:
1. stdio EOF는 비치명(HTTP 계속).
2. HTTP fatal은 치명(Fail-Fast, exit 1).

패턴:

```rust
enum TaskEvent {
    StdioDispatch(Result<()>),
    Http(Result<()>),
}

async fn run_both(core: Arc<McpCore>, cfg: HttpConfig) -> Result<ExitCode> {
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    // stdio thread 시작 (sync)
    let stdio_thread = start_stdio_thread(/* request_tx clone */);

    // async tasks를 JoinSet으로 관리
    let mut set = tokio::task::JoinSet::new();
    let core_s = Arc::clone(&core);
    set.spawn(async move { TaskEvent::StdioDispatch(run_stdio_dispatch(core_s).await) });

    let core_h = Arc::clone(&core);
    set.spawn(async move { TaskEvent::Http(run_http(core_h, cfg, shutdown_rx).await) });

    let mut stdio_done = false;

    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                let _ = shutdown_tx.send(true);
                // signal 경로: stdio join 무한 대기 금지
                return Ok(ExitCode::SUCCESS);
            }
            joined = set.join_next() => {
                let Some(joined) = joined else { break; };
                match joined? {
                    TaskEvent::StdioDispatch(Ok(())) => {
                        stdio_done = true;
                        // stdio EOF면 http 결과를 계속 대기
                    }
                    TaskEvent::StdioDispatch(Err(_)) => {
                        stdio_done = true;
                    }
                    TaskEvent::Http(Ok(())) => {
                        return Ok(ExitCode::SUCCESS);
                    }
                    TaskEvent::Http(Err(_)) => {
                        // HTTP fatal: fail-fast
                        return Ok(ExitCode::FAILURE);
                    }
                }
            }
        }
    }

    if stdio_done {
        let _ = stdio_thread.join(); // EOF로 끝난 경우에만 join
    }

    Ok(ExitCode::SUCCESS)
}
```

exit code:

| 상황 | 코드 |
|---|---:|
| 정상 종료(signal, EOF 후 http 정상 종료) | 0 |
| HTTP bind 실패/HTTP fatal | 1 |
| 시작 단계 daemon unreachable | 1 |
| panic | 101 |

### 5.9 CLI 호환성 정책

#### 5.9.1 기존 옵션 유지

| 옵션 | 상태 |
|---|---|
| `--socket` | 유지 |
| `--daemon-path` | 유지 |
| `--principal` | 유지 (`mcp` 기본) |
| `--token-path` | 유지 |
| `--ensure-daemon` | 유지 (`true` 기본) |

#### 5.9.2 신규 옵션

| 옵션 | 기본값 |
|---|---|
| `--transport` | `stdio` |
| `--http-bind` | `127.0.0.1` |
| `--http-port` | `3847` |

#### 5.9.3 모드별 유효성

| 옵션 | stdio | http | both |
|---|---|---|---|
| `--socket` | 사용 | 사용 | 사용 |
| `--daemon-path` | 사용 | 사용 | 사용 |
| `--principal` | 사용 | 사용 | 사용 |
| `--token-path` | 사용 | 사용 | 사용 |
| `--ensure-daemon` | 사용 | 사용 | 사용 |
| `--http-bind` | 무시(경고 1회) | 사용 | 사용 |
| `--http-port` | 무시(경고 1회) | 사용 | 사용 |

#### 5.9.4 앱(`MCPHttpService`)의 `ensure-daemon` 정책 (수정)

1. 기본 실행값: `--ensure-daemon true`.
2. 앱이 daemon readiness를 명시적으로 확인한 경우에만 `--ensure-daemon false`를 선택적으로 사용.
3. readiness 확인 실패 시 항상 `true`로 실행(첫 요청 실패 방지).

### 5.10 에러 규약

JSON-RPC:

| 상황 | code |
|---|---:|
| Method not found | -32601 |
| Invalid params | -32602 |
| Daemon unreachable | -32603 |
| Forbidden scope | -32001 |
| Proxy not running | -32002 |
| Proxy already running | -32003 |
| Tool execution failed | -32004 |

HTTP:

| 상황 | status | body |
|---|---:|---|
| token 누락/무효 | 401 | `{"error":"invalid or missing token"}` |
| origin 거부 | 403 | `{"error":"origin not allowed"}` |
| content-type 불일치 | 415 | `{"error":"expected application/json"}` |
| session 누락(initialize 외) | 400 | `{"error":"missing Mcp-Session-Id header"}` |
| session 무효/만료 | 401 | `{"error":"session expired or invalid"}` |
| notification 처리 | 204 | empty |

---

## 6. MCP 도구 목록 (32개)

### 6.1 System (3)
1. `crab_ping`
2. `crab_version`
3. `crab_daemon_doctor`

### 6.2 Proxy Control (3)
1. `crab_proxy_status`
2. `crab_proxy_start`
3. `crab_proxy_stop`

### 6.3 Engine Config (7)
1. `crab_engine_config_get`
2. `crab_engine_set_listen_addr`
3. `crab_engine_set_inspect_enabled`
4. `crab_engine_set_throttle`
5. `crab_engine_set_client_allowlist`
6. `crab_engine_set_transparent`
7. `crab_engine_load_ca`

### 6.4 Logs/Traffic (3)
1. `crab_logs_tail`
2. `crab_traffic_tail`
3. `crab_traffic_get`

### 6.5 Rules Read (5)
1. `crab_rules_dump`
2. `crab_rules_list_allow`
3. `crab_rules_list_map_local`
4. `crab_rules_list_map_remote`
5. `crab_rules_list_status_rewrite`

### 6.6 Rules Write (10)
1. `crab_rules_clear`
2. `crab_rules_add_allow`
3. `crab_rules_remove_allow`
4. `crab_rules_add_map_local_text`
5. `crab_rules_add_map_local_file`
6. `crab_rules_remove_map_local`
7. `crab_rules_add_map_remote`
8. `crab_rules_remove_map_remote`
9. `crab_rules_add_status_rewrite`
10. `crab_rules_remove_status_rewrite`

### 6.7 Advanced (1)
1. `crab_rpc`

합계: 32개

---

## 7. 구현 계획 (WS)

### WS1. Core/Bridge 분리

1. `src/mcp/{core,tools,bridge,traffic,types,error}.rs` 생성.
2. `McpBridge.call` async `&self` 전환.
3. `daemon_start_lock` + double-check + `spawn_blocking` 반영.
4. token read async 전환.

### WS2. stdio transport 구현

1. `src/mcp/transport_stdio.rs`에 stdio thread + channel 구조 구현.
2. `StdioRequest` 타입 고정(요청 + std mpsc 응답 sender).
3. `blocking_send` 사용.
4. 종료 정책 구현(EOF 경로 join, signal/fatal 경로 non-blocking 종료).

### WS3. HTTP transport 구현

1. `src/mcp/transport_http.rs` 구현.
2. auth/origin/cors/session/notification(204) 반영.
3. 포트 충돌 시 3848~3857 fallback.
4. graceful shutdown(최대 5초).

### WS4. both supervisor 구현

1. `JoinSet` 기반 task supervision.
2. HTTP fatal fail-fast(exit 1).
3. signal 처리 시 stdio 무한 join 금지.

### WS5. 앱 연동

1. `MCPHttpService.swift` 추가.
2. `ProxyViewModel.swift`, `SettingsView.swift`, `CrabProxyMacApp.swift` 수정.
3. 앱 기본 `--ensure-daemon true`, readiness 확인 시에만 false 선택.

---

## 8. 테스트 전략

### 8.1 단위 테스트

1. tool arg validation(32개).
2. error mapping(JSON-RPC/HTTP).
3. CORS 헤더명/값 + `Vary: Origin` 검증.
4. session TTL/청소.
5. bridge start-once 경합(동시 요청 spawn 1회).
6. stdio channel 계약 테스트(`blocking_send`/response round-trip).

### 8.2 통합 테스트

1. stdio initialize/list/call 회귀.
2. HTTP initialize/list/call.
3. notification → 204.
4. parity diff(32개 샘플).
5. HTTP bind 실패 → fallback 확인.
6. both: HTTP fatal → exit 1.
7. both: signal 시 즉시 종료(무한 대기 없음).

### 8.3 E2E

1. 앱 HTTP MCP ON → IDE 연결 → rules/traffic 조회.
2. 앱 종료 시 MCP 종료.
3. stdio EOF 후 HTTP 지속.
4. app daemon 미기동 상태에서도 기본 설정(`ensure-daemon=true`)으로 첫 요청 성공.

---

## 9. 리스크와 대응

| 리스크 | 영향 | 대응 |
|---|---|---|
| transport 결과 불일치 | 사용자 혼란 | `McpCore` 단일화 + parity 자동 테스트 |
| daemon start 경합 | 중복 spawn | `daemon_start_lock` + double-check |
| signal 시 stdio hang | 종료 지연 | non-blocking 종료 정책(무한 join 금지) |
| HTTP 부분 장애 은닉 | 운영성 저하 | HTTP fatal fail-fast |
| CLI 옵션 회귀 | 기존 사용자 중단 | 기존 옵션 유지 + 회귀 테스트 |

---

## 10. Gate / DoD

### Gate 1
1. `src/mcp/*` 분리 완료.
2. bridge async 전환 + start-once 보호 완료.
3. stdio 회귀 테스트 통과.

### Gate 2
1. HTTP transport + auth + session + CORS + notification(204) 완료.
2. parity 테스트 통과.

### Gate 3
1. both supervisor(`JoinSet`) 완료.
2. signal/HTTP fatal 종료 정책 검증 완료.
3. 앱 연동 완료.

### 최종 DoD
1. stdio/HTTP 실사용 가능.
2. 32개 도구 동등성 보장.
3. 기존 CLI 옵션 호환 유지.
4. 보안 기본값(localhost + bearer + origin + CORS strict) 충족.
5. 회귀/통합/E2E 테스트 통과.

---

## 11. 오픈 이슈

1. protocol version strict 전환 시점(로그 근거 기반).
2. HTTP fatal 시 앱 자동 재시작(backoff) 정책.
3. SSE(`GET /mcp`) 및 notification/backpressure 설계.
