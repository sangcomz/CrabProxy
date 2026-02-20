# PLAN: MCP Dual Transport (stdio + Streamable HTTP) v6

## v5 → v6 변경 요약

| # | v5 리뷰 지적 | v6 반영 |
|---|---|---|
| 1 | stdio sync I/O + `!Send` StdinLock 처리 미정 | **§5.6 stdio transport 전략** 신설: 전용 OS 스레드 + channel 방식 확정, 근거/대안 비교 포함 |
| 2 | `read_token_from_file` blocking 미언급 | §5.5.3 bridge 알고리즘에 `tokio::fs::read_to_string` 전환 명시 |
| 3 | `initialize` protocolVersion 검증 = 신규 동작, 회귀 위험 | **§5.1에서 결정 확정**: 경고 로그 + 허용(lenient) 정책. 오픈 이슈에서 승격 |
| 4 | `both` supervisor 구체 코드 누락 | **§5.8 supervisor 구현 패턴** 복원: stdio 스레드 + HTTP task + signal 처리 예시 |
| 5 | HTTP 응답 Content-Type 미명시 | §5.3 엔드포인트 테이블에 응답 헤더 추가 |
| 6 | `--ensure-daemon` + HTTP 모드 관계 | §5.9.3 모드별 유효성에 `ensure-daemon` 동작 추가 |
| 7 | HTTP notification 응답 코드 미정의 | **§5.3.1 notification 처리 정책** 신설 |
| 8 | 세션 저장소 자료구조 미명시 | §5.2에 `RwLock<HashMap>` 구조 명시 |

---

## 1. 목표

1. 단일 바이너리(`crab-mcp`)에서 `stdio`와 Streamable HTTP를 모두 지원한다.
2. 두 transport에서 동일한 MCP 도구 집합(32개)과 동작/에러 규약을 보장한다.
3. macOS 앱에서 HTTP MCP 서버를 시작/중지하고 endpoint/token을 확인할 수 있게 한다.
4. 기존 stdio 워크플로우 회귀를 0으로 유지한다.

## 2. 비목표 (v6 범위 제외)

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
| `src/bin/crab-mcp.rs` | 1,486 | stdio MCP 서버, 도구 정의/실행, traffic 집계 |
| `src/daemon/mod.rs` | 1,681 | daemon IPC, 인증/scope, RPC dispatch |
| `src/ipc.rs` | 168 | IPC 타입 |
| `src/proxy.rs` | 2,380 | 프록시 엔진 |
| `src/rules.rs` | 453 | 룰 타입/매칭 |

### 3.2 현재 제약

| # | 제약 | 코드 위치 | v6 영향 |
|---|------|-----------|---------|
| 1 | `DaemonBridge.call(&mut self)` + `runtime.block_on(send_rpc(...))` | `crab-mcp.rs:46-64` | async `&self`로 전환 필요 |
| 2 | 런타임 `new_current_thread()` | `crab-mcp.rs:84` | `new_multi_thread()`로 전환 필요 |
| 3 | `ensure_daemon_started`: blocking (spawn + sleep 폴링 최대 3초) | `daemon/mod.rs:1651-1677` | `spawn_blocking` 격리 필요 |
| 4 | `read_token_from_file`: sync `fs::read_to_string` | `daemon/mod.rs:1641-1649` | `tokio::fs` 전환 또는 허용 범위 판단 필요 |
| 5 | `StdinLock` / `StdoutLock`: `!Send` | `crab-mcp.rs:98-101` | tokio task로 이동 불가 → 전용 스레드 필요 |
| 6 | `initialize`에서 `protocolVersion` 미검증 | `crab-mcp.rs:148` | 신규 동작 추가 시 회귀 위험 판단 필요 |
| 7 | principal/token 기본 체계: `app\|cli\|mcp` 3개 | `daemon/mod.rs:1559-1563` | HTTP에서 기존 `mcp` token 공유 |

---

## 4. 목표 아키텍처

```text
                        ┌──────────────────────────────────────┐
                        │          전용 OS 스레드               │
IDE/Codex ──stdin───>   │  StdioTransport                      │
           <──stdout──  │  (sync read/write + channel bridge)  │
                        └──────────────┬───────────────────────┘
                                       │ mpsc channel
                                       v
                        ┌──────────────────────────┐
                        │       McpCore (async)     │──IPC──> crabd
                        │  Arc<McpCore>, Send+Sync  │
                        │  - ToolRegistry (32개)    │
                        │  - Validation             │
                        │  - TrafficAggregator      │
                        └──────────────────────────┘
                                       ^
                                       │ direct async call
                        ┌──────────────┴───────────────────────┐
IDE/Tool ──HTTP──>      │  HttpTransport (tokio task)           │
                        │  hyper service_fn                     │
                        │  Bearer auth, Origin, CORS, Session   │
                        └──────────────────────────────────────┘
                                       ^
                                       │
                        ┌──────────────┴───────────┐
                        │     CrabProxyMacApp       │
                        │  (HTTP MCP process mgmt)  │
                        └──────────────────────────┘
```

설계 원칙:

1. 도구 정의/검증/실행/에러 매핑은 `McpCore`에 집중한다.
2. stdio/HTTP는 transport adapter 역할만 담당한다.
3. HTTP 세션과 crabd 연결 세션을 분리한다.
4. **stdio는 sync I/O 특성을 유지**하되, channel을 통해 async Core에 연결한다.

---

## 5. 설계 결정

### 5.1 MCP 프로토콜 버전 정책 (v6 확정)

**결정: lenient 정책 (경고 + 허용)**

| 동작 | 설명 |
|------|------|
| 서버 광고 버전 | `2024-11-05` |
| 클라이언트가 `2024-11-05` 전송 | 정상 처리 |
| 클라이언트가 다른 버전 전송 | **경고 로그** 출력 후 정상 처리 |
| 클라이언트가 버전 미전송 | 정상 처리 (버전 필드 무시) |

근거:

1. 현재 코드(`crab-mcp.rs:148`)는 `protocolVersion`을 검증하지 않고 바로 응답한다. strict 정책을 적용하면 기존에 동작하던 클라이언트가 거부될 수 있어 **§1.4 "회귀 0" 목표에 위배**된다.
2. lenient 정책은 기존 동작과 호환되면서, 경고 로그로 불일치를 관측할 수 있다.
3. strict 전환은 충분한 경고 기간(로그 수집) 후 별도 마이너 릴리즈에서 결정한다.

### 5.2 Streamable HTTP 세션 정책

1. `initialize` 성공 시 `Mcp-Session-Id` 발급.
2. 이후 `POST /mcp` 요청은 같은 `Mcp-Session-Id` 사용.
3. 세션 저장 항목: session_id, created_at, last_activity, client_info, capabilities.
4. 저장 금지 항목: crabd bridge session/connection state.
5. TTL: 30분, 60초 간격 청소 task.

**세션 저장소 자료구조:**

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
    ttl: Duration,  // 기본 30분
}
```

- `RwLock`을 사용하여 읽기(세션 조회)는 동시 허용, 쓰기(생성/삭제)만 배타 처리.
- 청소 task: `tokio::spawn`으로 60초 간격 실행, `write lock` 획득 후 만료 세션 제거.

### 5.3 HTTP 엔드포인트

| Method | Path | 요청 Content-Type | 응답 Content-Type | 설명 |
|---|---|---|---|---|
| `POST` | `/mcp` | `application/json` (필수) | `application/json` | JSON-RPC 요청/응답 |
| `OPTIONS` | `/mcp` | (없음) | (없음, 헤더만) | CORS preflight |
| `GET` | `/healthz` | (없음) | `application/json` | liveness check |

#### 5.3.1 Notification 처리 정책

MCP 클라이언트는 `initialize` 성공 후 `notifications/initialized`를 `POST /mcp`로 전송한다 (JSON-RPC notification: `id` 없음).

| 상황 | HTTP 응답 |
|------|-----------|
| 유효한 notification (`notifications/initialized` 등) | `204 No Content` (body 없음) |
| 알 수 없는 notification (id 없는 미지 method) | `204 No Content` (무시, 로그 기록) |
| notification인데 `Mcp-Session-Id` 누락 | `400 Bad Request` |

근거: JSON-RPC notification은 응답을 기대하지 않으므로 `204`가 적합. 현재 stdio에서도 notification에 대해 응답을 보내지 않는다 (`crab-mcp.rs:141-144`: `return None`).

### 5.4 인증/CORS

1. bind 기본값 `127.0.0.1`.
2. `Authorization: Bearer <token>` 필수 (`mcp.token`, 0600).
3. `Origin` 헤더 존재 시 `localhost`/`127.0.0.1`만 허용.
4. CORS 허용 origin: exact match reflection.

**Preflight 응답 헤더 (정식 이름):**

| 헤더 | 값 |
|------|-----|
| `Access-Control-Allow-Origin` | 요청 Origin 반사 (허용 시) |
| `Access-Control-Allow-Methods` | `POST, OPTIONS` |
| `Access-Control-Allow-Headers` | `Authorization, Content-Type, Mcp-Session-Id` |
| `Access-Control-Max-Age` | `86400` |

금지:

1. `Allow-Methods`, `Allow-Headers` 등 비표준 축약형 사용 금지.
2. `Access-Control-Allow-Origin: http://localhost:*` 와일드카드 패턴 금지.

### 5.5 McpBridge 동시성/안정성

#### 5.5.1 목표

1. `call(&self)` 전환으로 HTTP 동시 요청 처리 가능.
2. daemon 미기동 상태에서 동시 요청이 들어와도 중복 spawn/race 방지.
3. blocking 작업이 async executor를 막지 않도록 격리.

#### 5.5.2 구조

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

#### 5.5.3 알고리즘

```text
async fn call(&self, method, params) -> Result<Value>
  1. if ensure_daemon:
       a) quick check: can_connect_socket(socket_path) → 성공이면 skip
       b) lock 획득 (daemon_start_lock.lock().await)
       c) 2차 check: can_connect_socket → 여전히 실패하면
          spawn_blocking(ensure_daemon_started) 실행
       d) lock 해제
  2. token = tokio::fs::read_to_string(token_path).await  ← async file I/O
  3. send_rpc(socket_path, token, principal, method, params).await
```

변경점 vs v5:
- `read_token_from_file` 대신 `tokio::fs::read_to_string` + trim + empty check로 전환. sync file I/O를 async executor에서 실행하지 않음.

#### 5.5.4 실행 규칙

1. bridge 내부 mutable state를 두지 않는다 (`&self`).
2. start 보호는 process-local `tokio::sync::Mutex`로 충분하다.
3. `ensure_daemon_started`는 `spawn_blocking`으로 실행한다.
4. token 읽기는 `tokio::fs`로 async 수행한다.
5. lock 임계구역은 daemon start 로직으로 최소화한다.

### 5.6 stdio transport 전략 (v6 핵심)

#### 5.6.1 문제

현재 stdio 루프의 핵심 타입:

```rust
let stdin = io::stdin();
let mut reader = BufReader::new(stdin.lock());   // StdinLock<'_> — !Send
let mut writer = BufWriter::new(stdout.lock());  // StdoutLock<'_> — !Send
```

- `StdinLock`/`StdoutLock`은 `!Send`이므로 `tokio::spawn`에 넘길 수 없다.
- bridge가 `async fn call(&self)`로 전환되면, sync stdio 루프 안에서 `.await`를 호출할 수 없다.

#### 5.6.2 대안 비교

| 방식 | 장점 | 단점 |
|------|------|------|
| A. 전용 OS 스레드 + channel | framing 로직 변경 없음. sync/async 경계 명확 | channel 오버헤드 (무시 가능 수준) |
| B. `tokio::io::stdin()` async 전환 | 순수 async. `tokio::spawn` 가능 | framing 로직 전체 재작성. `tokio::io::stdin()`은 내부적으로 `spawn_blocking` 사용하므로 성능 이점 미미 |
| C. `spawn_blocking` + 내부 `block_on` | 최소 변경 | `spawn_blocking` 안에서 `block_on`은 anti-pattern. 중첩 runtime 위험 |

#### 5.6.3 결정: A. 전용 OS 스레드 + channel

```text
┌─────────── std::thread ────────────┐     ┌─────── tokio runtime ──────┐
│                                     │     │                            │
│  stdin.lock() → BufReader           │     │                            │
│  loop {                             │     │                            │
│    msg = read_framed_message()      │     │                            │
│    request_tx.send(msg) ──────────────────>  recv → McpCore.handle()  │
│    response = response_rx.recv() <─────────  send ← result            │
│    write_framed_message(response)   │     │                            │
│  }                                  │     │                            │
│  stdout.lock() → BufWriter          │     │                            │
└─────────────────────────────────────┘     └────────────────────────────┘
```

**채널 타입:**

```rust
// 요청: stdio thread → async runtime
let (request_tx, request_rx) = tokio::sync::mpsc::channel::<Value>(16);

// 응답: async runtime → stdio thread
// 요청당 1:1 응답이므로 oneshot 사용
// request_tx가 보내는 메시지에 oneshot::Sender를 포함
struct StdioRequest {
    message: Value,
    response_tx: tokio::sync::oneshot::Sender<Option<Value>>,
}
```

**stdio-only 모드 최적화:**

`--transport stdio`일 때도 동일한 스레드 + channel 구조를 사용한다. 이유:
1. bridge가 async이므로 어떤 모드에서든 async runtime이 필요.
2. 코드 경로 단일화로 stdio-only와 both의 동작 차이를 제거.
3. channel 오버헤드는 IPC(Unix socket) 왕복 대비 무시 가능.

#### 5.6.4 stdio thread 종료 규칙

| 이벤트 | 동작 |
|--------|------|
| stdin EOF (`read_framed_message` returns `None`) | `request_tx` drop → async 측에서 `None` 수신 → stdio task 완료 |
| framing parse 에러 | 에러 응답 write 후 thread 종료 |
| `response_rx.recv()` 에러 (async 측 종료) | thread 종료 |
| shutdown signal (async 측에서 전파) | `request_tx` drop으로 thread에 전파 |

### 5.7 런타임 모델

| 항목 | 현재 | v6 |
|---|---|---|
| tokio runtime | `new_current_thread()` | `new_multi_thread()` |
| bridge API | `fn call(&mut self, ...)` | `async fn call(&self, ...)` |
| send path | `runtime.block_on(send_rpc(...))` | `send_rpc(...).await` |
| token read | sync `fs::read_to_string` | `tokio::fs::read_to_string` |
| core ownership | 단일 소유 | `Arc<McpCore>` (Send + Sync) |
| stdio I/O | main thread sync loop | 전용 OS 스레드 + channel |

### 5.8 `both` 모드 supervisor (v6 구현 패턴)

**정책:** stdio EOF는 비치명, **HTTP fatal은 치명(Fail-Fast)**

| 이벤트 | 동작 | exit |
|---|---|---:|
| stdio EOF | stdio 완료, HTTP 계속 서비스 | 0 (HTTP 종료 시) |
| HTTP bind 실패 (시작) | 즉시 종료 | 1 |
| HTTP fatal (런타임) | 전체 프로세스 종료 (Fail-Fast) | 1 |
| SIGINT/SIGTERM | graceful shutdown (최대 5초) | 0 |

**구현 패턴:**

```rust
async fn run_both(core: Arc<McpCore>, http_config: HttpConfig) -> Result<ExitCode> {
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    // --- stdio: 전용 OS 스레드 + channel ---
    let (request_tx, mut request_rx) = mpsc::channel::<StdioRequest>(16);
    let stdio_thread = std::thread::spawn(move || {
        stdio_thread_main(request_tx)  // sync read/write loop
    });

    // stdio 요청 처리 async task
    let core_s = Arc::clone(&core);
    let stdio_task = tokio::spawn(async move {
        while let Some(req) = request_rx.recv().await {
            let response = core_s.handle_message(req.message).await;
            let _ = req.response_tx.send(response);
        }
        tracing::info!(transport = "stdio", event = "eof");
    });

    // --- HTTP: tokio task ---
    let core_h = Arc::clone(&core);
    let http_shutdown_rx = shutdown_rx.clone();
    let http_task = tokio::spawn(async move {
        transport_http::run(core_h, http_config, http_shutdown_rx).await
    });

    // --- supervisor ---
    let exit_code = tokio::select! {
        // stdio task 완료 (EOF 또는 에러)
        _ = stdio_task => {
            tracing::info!(event = "stdio_done", "stdio ended, waiting for HTTP or signal");
            tokio::select! {
                res = http_task => match res {
                    Ok(Ok(())) => ExitCode::SUCCESS,
                    _ => ExitCode::FAILURE,
                },
                _ = tokio::signal::ctrl_c() => {
                    shutdown_tx.send(true)?;
                    ExitCode::SUCCESS
                }
            }
        }
        // HTTP task 완료 (fatal 또는 정상 종료)
        res = &mut http_task => {
            match res {
                Ok(Ok(())) => {
                    // signal에 의한 정상 종료
                    tracing::info!(event = "http_done");
                    ExitCode::SUCCESS
                }
                _ => {
                    // HTTP fatal → Fail-Fast
                    tracing::error!(transport = "http", event = "fatal");
                    ExitCode::FAILURE
                }
            }
        }
        // signal
        _ = tokio::signal::ctrl_c() => {
            tracing::info!(event = "signal", "shutdown signal");
            shutdown_tx.send(true)?;
            let _ = tokio::time::timeout(
                Duration::from_secs(5),
                async {
                    let _ = http_task.await;
                    // stdio thread는 request_tx drop으로 자연 종료
                }
            ).await;
            ExitCode::SUCCESS
        }
    };

    // stdio thread join (이미 종료되었거나 곧 종료)
    let _ = stdio_thread.join();
    Ok(exit_code)
}
```

**종료 상태 코드:**

| 상황 | exit code |
|------|-----------|
| 정상 종료 (signal, EOF 후 HTTP 정상 종료) | 0 |
| HTTP 바인드 실패 | 1 |
| HTTP fatal (런타임) | 1 |
| crabd 연결 불가 (시작 시) | 1 |
| 예상치 못한 panic | 101 |

**로그 키워드:**

| 필드 | 값 |
|------|-----|
| `transport` | `stdio` \| `http` |
| `event` | `start` \| `stop` \| `eof` \| `fatal` \| `request` \| `session_expired` |

### 5.9 CLI 호환성 정책

#### 5.9.1 기존 옵션 유지 (Breaking change 금지)

| 옵션 | 기본값 | 상태 |
|---|---|---|
| `--socket` | `~/Library/.../crabd.sock` | 유지 |
| `--daemon-path` | 실행 파일 인접 `crabd` | 유지 |
| `--principal` | `mcp` | 유지 |
| `--token-path` | `mcp.token` 경로 | 유지 |
| `--ensure-daemon` | `true` | 유지 |

#### 5.9.2 신규 옵션

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--transport` | `stdio` | `stdio\|http\|both` |
| `--http-bind` | `127.0.0.1` | HTTP listen address |
| `--http-port` | `3847` | HTTP listen port |

#### 5.9.3 모드별 옵션 유효성

| 옵션 | stdio | http | both |
|---|---|---|---|
| `--socket` | 사용 | 사용 | 사용 |
| `--daemon-path` | 사용 | 사용 | 사용 |
| `--principal` | 사용 | 사용 | 사용 |
| `--token-path` | 사용 | 사용 | 사용 |
| `--ensure-daemon` | 사용 (기본 `true`) | 사용 (기본 `true`). 앱이 crabd를 별도 관리하면 `false` 권장 | 사용 |
| `--http-bind` | 무시 (경고 1회) | 사용 | 사용 |
| `--http-port` | 무시 (경고 1회) | 사용 | 사용 |

`--ensure-daemon`과 HTTP 모드:
- HTTP 모드에서도 기본값 `true`이므로 첫 요청 시 daemon auto-start가 발생한다.
- 앱(`CrabProxyMacApp`)이 이미 crabd를 관리하는 환경에서는 `--ensure-daemon false`로 실행하여 이중 spawn을 방지한다.
- 앱의 `MCPHttpService`가 MCP 프로세스를 spawn할 때 `--ensure-daemon false`를 기본으로 전달한다.

### 5.10 에러 규약

#### JSON-RPC (MCP 레벨)

| 상황 | code | message |
|---|---:|---|
| Method not found | -32601 | `Method not found` |
| Invalid params | -32602 | `Invalid params: {detail}` |
| Daemon unreachable | -32603 | `Internal error: daemon unreachable` |
| Forbidden scope | -32001 | `Forbidden: insufficient scope` |
| Proxy not running | -32002 | `Proxy not running` |
| Proxy already running | -32003 | `Proxy already running` |
| Tool execution failed | -32004 | `Tool execution failed: {detail}` |

#### HTTP transport 레벨

| 상황 | status | Content-Type | body |
|---|---:|---|---|
| token 누락/무효 | 401 | `application/json` | `{"error":"invalid or missing token"}` |
| origin 거부 | 403 | `application/json` | `{"error":"origin not allowed"}` |
| content-type 불일치 | 415 | `application/json` | `{"error":"expected application/json"}` |
| session 누락 (initialize 외) | 400 | `application/json` | `{"error":"missing Mcp-Session-Id header"}` |
| session 무효/만료 | 401 | `application/json` | `{"error":"session expired or invalid"}` |
| notification 수신 | 204 | (없음) | (없음) |

---

## 6. MCP 도구 목록 (32개 고정)

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

## 7. 구현 계획 (Workstreams)

### WS1. Core 분리 + Bridge/Runtime 전환

**목표 구조:**

```text
src/mcp/
  mod.rs
  core.rs               # McpCore: handle_request, handle_message
  tools.rs              # ToolRegistry: 32개 도구 스키마 + validation + call_tool
  bridge.rs             # McpBridge: async fn call(&self, ...) + daemon_start_lock
  traffic.rs            # TrafficAggregator: logs → grouped entries
  types.rs              # McpRequest, McpResponse, StdioRequest 등
  error.rs              # McpError + JSON-RPC 에러 코드 매핑
  transport_stdio.rs    # 전용 OS 스레드 stdio loop + channel 연결
  transport_http.rs     # hyper HTTP server (WS2)
  session.rs            # SessionManager (WS2)
src/bin/
  crab-mcp.rs           # CLI 파싱 + transport wiring (~150줄)
src/lib.rs              # + pub mod mcp;
```

**작업:**

| # | 작업 | 상세 |
|---|------|------|
| 1 | 런타임 전환 | `new_current_thread()` → `new_multi_thread()` |
| 2 | `types.rs` | 공통 타입: `McpRequest`, `McpResponse`, `StdioRequest` |
| 3 | `error.rs` | `McpError` enum + §5.10 에러 코드 매핑 |
| 4 | `bridge.rs` | `async fn call(&self, ...)` + `daemon_start_lock` + `tokio::fs` token read |
| 5 | `tools.rs` | `tool_definitions()` + `call_tool()` + arg validation 헬퍼 추출 |
| 6 | `traffic.rs` | `TrafficAggregate` + `aggregate_traffic_entries` + `traffic_tail/get` 추출 |
| 7 | `core.rs` | `McpCore { bridge, tools }` + `handle_message()` (initialize, ping, tools/list, tools/call 디스패치) |
| 8 | `transport_stdio.rs` | 전용 OS 스레드 + mpsc/oneshot channel + framing (§5.6.3) |
| 9 | `crab-mcp.rs` 정리 | CLI 파싱 + `McpCore` 생성 + transport 선택/실행 |
| 10 | stdio 회귀 테스트 | 분리 전/후 동일 입출력 검증 |

### WS2. HTTP transport 추가

**재사용 의존성 (추가 crate 없음):**

- `hyper` v1.7, `hyper-util` v0.1, `http-body-util` v0.1
- `tokio` v1.47, `serde_json`, `uuid` v1.18

**작업:**

| # | 작업 | 상세 |
|---|------|------|
| 1 | `transport_http.rs` 골격 | `hyper::service::service_fn` + `TcpListener` |
| 2 | Bearer token 인증 | `Authorization` 파싱 → `mcp.token` 비교. 불일치 시 401 |
| 3 | Origin 검증 | `localhost`/`127.0.0.1`만 허용. 불일치 시 403 |
| 4 | CORS preflight | §5.4 정식 헤더명 준수 |
| 5 | `POST /mcp` 처리 | Content-Type 검증 → JSON 파싱 → 세션 검증 → `McpCore.handle_message()` → JSON 응답 (Content-Type: `application/json`) |
| 6 | Notification 처리 | id 없는 JSON-RPC → 204 No Content (§5.3.1) |
| 7 | `session.rs` | `SessionManager` + `RwLock<HashMap>` + 60초 청소 task |
| 8 | `Mcp-Session-Id` 발급/검증 | initialize 시 발급, 이후 필수. 미제공 400, 무효/만료 401 |
| 9 | `GET /healthz` | 200 + `{"status":"ok"}`. 인증 불필요 |
| 10 | 포트 충돌 자동 탐색 | 3847 실패 시 3848~3857 순차 시도. 모두 실패 시 에러 + exit 1 |
| 11 | Graceful shutdown | `watch::Receiver<bool>` 수신 시 새 연결 거부 + 활성 요청 완료 대기 (최대 5초) |

### WS3. `both` supervisor

| # | 작업 | 상세 |
|---|------|------|
| 1 | supervisor 구현 | §5.8 패턴 기반: stdio thread + HTTP task + `tokio::select!` |
| 2 | HTTP fatal fail-fast | HTTP task 비정상 완료 시 exit 1 |
| 3 | signal 처리 | SIGINT/SIGTERM → `watch` 전파 + 5초 graceful |
| 4 | 로그 키워드 통일 | `transport=stdio\|http`, `event=start\|stop\|eof\|fatal` |

### WS4. 앱 연동

| # | 작업 | 상세 |
|---|------|------|
| 1 | `MCPHttpService.swift` 신규 | `ObservableObject`, `Process` spawn/terminate |
| 2 | `ProxyViewModel.swift` 변경 | `mcpHttpService` 속성 추가 |
| 3 | `SettingsView.swift` 변경 | MCP HTTP UI 섹션 (토글, endpoint, token, port, status) |
| 4 | `CrabProxyMacApp.swift` 변경 | `willTerminate`에서 MCP 종료 |
| 5 | 앱 spawn 시 옵션 | `crab-mcp --transport http --http-port <port> --ensure-daemon false` |

### WS5. 문서/운영

| # | 작업 |
|---|------|
| 1 | stdio/HTTP/both 연결 가이드 |
| 2 | IDE 설정 예시 (Claude Desktop, Cursor, Codex) |
| 3 | 트러블슈팅 (401, CORS, 포트 충돌, daemon unreachable, 세션 만료) |
| 4 | `crab-mcp --help` 업데이트 |

---

## 8. 테스트 전략

### 8.1 단위 테스트

| # | 대상 | 항목 |
|---|------|------|
| 1 | `tools.rs` | 32개 도구 arg validation (필수/선택, 타입, 범위) |
| 2 | `error.rs` | 에러 코드 매핑 (§5.10 전체) |
| 3 | `traffic.rs` | 로그 → 트래픽 엔트리 집계 정확성 |
| 4 | `transport_http.rs` | CORS preflight 헤더명 검증 (`Access-Control-Allow-*`) |
| 5 | `transport_http.rs` | Bearer token 검증 (유효/무효/누락) |
| 6 | `transport_http.rs` | Origin 검증 (localhost 허용, 외부 거부, 헤더 없음 허용) |
| 7 | `transport_http.rs` | notification → 204 응답 검증 |
| 8 | `session.rs` | 세션 생성/조회/만료/청소 |
| 9 | `bridge.rs` | start-once 경합 테스트 (동시 20요청 → daemon spawn 1회 보장) |
| 10 | `transport_stdio.rs` | channel 왕복: 요청 전송 → 응답 수신 정상 동작 |

### 8.2 통합 테스트

| # | 시나리오 |
|---|----------|
| 1 | stdio initialize/list/call 회귀 |
| 2 | HTTP initialize/list/call |
| 3 | HTTP notification → 204 |
| 4 | parity diff (32개 도구 샘플, stdio vs HTTP) |
| 5 | HTTP bind 실패 → fallback 포트 탐색 |
| 6 | `both` 모드: HTTP fatal → exit 1 |
| 7 | `both` 모드: stdio EOF → HTTP 계속 |
| 8 | protocolVersion 불일치 → 경고 로그 + 정상 처리 |

### 8.3 E2E

| # | 시나리오 |
|---|----------|
| 1 | 앱에서 HTTP MCP ON → IDE 연결 → rules/traffic 조회 |
| 2 | 앱 종료 시 MCP 프로세스 종료 확인 |
| 3 | stdio EOF 이후 HTTP 서비스 지속 확인 |
| 4 | 동시 접속: stdio + HTTP 동시 tool 호출, 상호 간섭 없음 |

---

## 9. 리스크와 대응

| # | 리스크 | 영향 | 대응 |
|---|--------|------|------|
| 1 | transport 결과 불일치 | 사용자 혼란 | `McpCore` 단일화 + parity 자동 테스트 |
| 2 | daemon start 경합 | 중복 spawn | `daemon_start_lock` + double-check |
| 3 | blocking I/O가 runtime 정체 | tail latency 증가 | `spawn_blocking` (daemon start), `tokio::fs` (token read) |
| 4 | HTTP 부분 장애 은닉 | 운영 관측성 저하 | HTTP fatal fail-fast + 상위 재시작 |
| 5 | CLI 옵션 회귀 | 기존 사용자 중단 | 기존 옵션 유지 + 회귀 테스트 |
| 6 | stdio thread + channel 오버헤드 | 성능 저하 | IPC 왕복(~ms) 대비 channel(<μs)은 무시 가능 |
| 7 | 세션 메모리 누수 | 장기 운영 시 OOM | TTL 30분 + 60초 청소 task |
| 8 | protocolVersion lenient 정책으로 비호환 클라이언트 감지 지연 | 호환성 문제 잠복 | 경고 로그 모니터링 후 strict 전환 시점 결정 |

---

## 10. Gate / DoD

### Gate 1: Core 분리 + stdio 회귀 무손상

1. `src/mcp/*` 모듈 구조 완성.
2. `McpBridge`: `async fn call(&self, ...)` + `daemon_start_lock` + `tokio::fs` token read.
3. tokio `new_multi_thread()` 전환.
4. stdio transport: 전용 OS 스레드 + channel 구조 동작.
5. `crab-mcp --transport stdio`가 기존과 100% 동일하게 동작 (회귀 테스트 통과).

### Gate 2: HTTP transport 완료

1. `POST /mcp` initialize → tools/list → tools/call 정상.
2. Bearer token / Origin / CORS 검증 동작.
3. 세션 관리 (`Mcp-Session-Id`) + TTL 동작.
4. Notification → 204 동작.
5. 포트 충돌 자동 탐색 동작.
6. Parity 테스트 (stdio vs HTTP) 통과.

### Gate 3: `both` + 앱 연동

1. `--transport both` 동작: stdio + HTTP 동시 제공.
2. stdio EOF → HTTP 계속 유지.
3. HTTP fatal → fail-fast (exit 1).
4. 앱에서 HTTP MCP ON/OFF + endpoint/token 복사.
5. 앱 종료 시 MCP 프로세스 종료 보장.
6. 앱 spawn 시 `--ensure-daemon false` 전달.

### Gate 4: 문서 및 최종 검증

1. IDE별 설정 가이드 작성.
2. 트러블슈팅 문서 작성.
3. 전체 E2E 테스트 통과.

### 최종 DoD

1. stdio/HTTP 모두 실사용 가능.
2. 32개 도구 동등성 확보.
3. CLI 기존 옵션/명령 호환 유지.
4. 보안 기본값 (localhost + bearer + origin + CORS strict) 충족.
5. protocolVersion lenient 정책 + 경고 로그 동작.
6. 회귀/통합/E2E 테스트 통과.

---

## 11. 오픈 이슈

1. ~~protocol version strict vs lenient~~ → **v6에서 lenient 확정** (§5.1).
2. app supervisor에서 HTTP fatal 자동 재시작(백오프 포함) — 향후 버전 후보.
3. SSE(`GET /mcp`) 도입 시 notification/backpressure 정책 — 향후 버전 후보.
4. protocolVersion lenient → strict 전환 시점 기준 (경고 로그 수집량/기간).
