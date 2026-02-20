# PLAN: MCP Dual Transport (stdio + Streamable HTTP) v5

## v4 → v5 변경 요약

| # | v4 리뷰 지적 | v5 반영 |
|---|---|---|
| 1 | CORS preflight 헤더명 오류 (`Allow-*`) | **정식 헤더명으로 수정**: `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers` |
| 2 | `DaemonBridge &self` 전환 근거 불충분 (start 경합 가능) | **start-once 보호 설계 추가**: `daemon_start_lock` + double-check + `spawn_blocking(ensure_daemon_started)` |
| 3 | `both` 모드 HTTP fatal 시 정책 모호 | **명시적 Fail-Fast 정책 확정**: HTTP fatal 발생 시 전체 프로세스 종료(exit 1) |
| 4 | CLI 회귀 0와 옵션 문서 불일치 | **기존 옵션 유지 명시**: `--socket`, `--daemon-path`, `--principal`, `--token-path`, `--ensure-daemon` + 신규 HTTP 옵션 병행 |
| 5 | JoinSet 언급/본문 불일치 | 본문 supervisor 예시를 **`JoinSet + select!`** 로 통일 |

---

## 1. 목표

1. 단일 바이너리(`crab-mcp`)에서 `stdio`와 Streamable HTTP를 모두 지원한다.
2. 두 transport에서 동일한 MCP 도구 집합(32개)과 동작/에러 규약을 보장한다.
3. macOS 앱에서 HTTP MCP 서버를 시작/중지하고 endpoint/token을 확인할 수 있게 한다.
4. 기존 stdio 워크플로우 회귀를 0으로 유지한다.

## 2. 비목표 (v5 범위 제외)

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
| `crab-mitm/src/bin/crab-mcp.rs` | 1486 | stdio MCP 서버, 도구 정의/실행, traffic 집계 |
| `crab-mitm/src/daemon/mod.rs` | 1681 | daemon IPC, 인증/scope, RPC dispatch |
| `crab-mitm/src/ipc.rs` | 168 | IPC 타입 |
| `crab-mitm/src/proxy.rs` | 2380 | 프록시 엔진 |
| `crab-mitm/src/rules.rs` | 453 | 룰 타입/매칭 |

### 3.2 현재 제약

1. `DaemonBridge.call(&mut self)` + `runtime.block_on(send_rpc(...))` 구조다.
2. 런타임은 `new_current_thread()`다.
3. `ensure_daemon_started`는 파일 삭제/spawn/sleep 대기를 수행하는 blocking 함수다.
4. principal/token 기본 체계는 `app|cli|mcp` 3개다.

---

## 4. 목표 아키텍처

```text
                    +------------------------+
IDE/Codex ----------> StdioTransport         |
                    +------------------------+ \
                                                 \
                    +------------------------+    +------------------+    +--------+
IDE/Tool -----------> HttpTransport          +---> McpCore (shared) +---> crabd  |
                    +------------------------+    +------------------+    +--------+
                              ^
                              |
                   CrabProxyMacApp (HTTP MCP process manager)
```

원칙:

1. 도구 정의/검증/실행/에러 매핑은 `McpCore`에 집중한다.
2. stdio/HTTP는 transport adapter 역할만 담당한다.
3. HTTP 세션과 crabd 연결 세션을 분리한다.

---

## 5. 설계 결정

### 5.1 MCP 프로토콜 버전

1. 서버 광고 버전은 `2024-11-05`로 유지.
2. `initialize.params.protocolVersion != 2024-11-05`이면 `-32602` 반환.
3. 에러 `data.supported = ["2024-11-05"]` 포함.

### 5.2 Streamable HTTP 세션 정책

1. `initialize` 성공 시 `Mcp-Session-Id` 발급.
2. 이후 `POST /mcp` 요청은 같은 `Mcp-Session-Id` 사용.
3. 세션 저장 항목: session_id, created_at, last_activity, client_info, capabilities.
4. 저장 금지 항목: crabd bridge session/connection state.
5. TTL: 30분, 60초 간격 청소 task.

### 5.3 HTTP 엔드포인트

| Method | Path | 설명 |
|---|---|---|
| `POST` | `/mcp` | JSON-RPC 요청 |
| `OPTIONS` | `/mcp` | CORS preflight |
| `GET` | `/healthz` | liveness |

### 5.4 인증/CORS (v5 확정)

1. bind 기본값은 `127.0.0.1`.
2. `Authorization: Bearer <token>` 필수 (`mcp.token`, 0600).
3. `Origin` 헤더 존재 시 `localhost`/`127.0.0.1`만 허용.
4. CORS 허용 origin은 exact match reflection 방식 사용.

**Preflight 응답 헤더(정식 이름 고정):**

1. `Access-Control-Allow-Origin`
2. `Access-Control-Allow-Methods: POST, OPTIONS`
3. `Access-Control-Allow-Headers: Authorization, Content-Type, Mcp-Session-Id`
4. `Access-Control-Max-Age`

주의:

1. `Allow-Methods`, `Allow-Headers` 같은 비표준 헤더 사용 금지.
2. `Access-Control-Allow-Origin: http://localhost:*` 같은 wildcard 포맷 금지.

### 5.5 DaemonBridge 동시성/안정성 (v5 핵심)

#### 5.5.1 목표

1. `call(&self)` 전환으로 HTTP 동시 요청 처리 가능.
2. daemon 미기동 상태에서 동시 요청이 들어와도 중복 spawn/race를 방지.
3. blocking 작업(`ensure_daemon_started`)이 async executor를 막지 않게 처리.

#### 5.5.2 구조

```rust
struct McpBridge {
    socket_path: PathBuf,
    daemon_path: PathBuf,
    token_path: PathBuf,
    principal: String,
    ensure_daemon: bool,
    daemon_start_lock: Arc<tokio::sync::Mutex<()>>, // start-once 보호
}
```

#### 5.5.3 알고리즘 (double-check)

```text
call(method, params)
  if ensure_daemon:
    1) quick check: socket connect 가능하면 skip
    2) lock 획득(daemon_start_lock)
    3) 2차 check: 여전히 불가하면 ensure_daemon_started 실행
       - spawn_blocking으로 감싸서 blocking 격리
    4) lock 해제
  token read
  send_rpc(...).await
```

#### 5.5.4 실행 규칙

1. bridge 내부 mutable state를 두지 않는다.
2. start 보호는 process-local lock으로 충분하다.
3. `ensure_daemon_started`는 `tokio::task::spawn_blocking`으로 실행한다.
4. lock 임계구역은 daemon start 관련 코드로 최소화한다.

### 5.6 런타임 모델

| 항목 | 현재 | v5 |
|---|---|---|
| tokio runtime | `new_current_thread()` | `new_multi_thread()` |
| bridge API | `fn call(&mut self, ...)` | `async fn call(&self, ...)` |
| send path | `runtime.block_on(send_rpc(...))` | `send_rpc(...).await` |
| core ownership | 단일 소유 | `Arc<McpCore>` 공유 |

### 5.7 `both` 모드 supervisor 정책 (v5 확정)

**정책:** `stdio EOF`는 비치명, **HTTP fatal은 치명(Fail-Fast)**

| 이벤트 | 동작 | exit |
|---|---|---:|
| stdio EOF | stdio task 종료, HTTP 계속 서비스 | 0 (HTTP 종료 시) |
| HTTP bind 실패(시작 단계) | 즉시 종료 | 1 |
| HTTP fatal(런타임) | 전체 프로세스 종료 (Fail-Fast) | 1 |
| SIGINT/SIGTERM | graceful shutdown(최대 5초) | 0 |

왜 Fail-Fast인가:

1. 앱/운영자가 장애를 즉시 감지할 수 있다.
2. "프로세스는 살아있지만 HTTP만 죽은" 상태를 제거한다.
3. 재시작 정책은 상위 레이어(app supervisor)가 담당하도록 분리한다.

### 5.8 CLI 호환성 정책 (회귀 0)

#### 5.8.1 기존 옵션 유지 (Breaking change 금지)

| 옵션 | 상태 | 비고 |
|---|---|---|
| `--socket` | 유지 | 기존 stdio 동작과 동일 |
| `--daemon-path` | 유지 | 기존과 동일 |
| `--principal` | 유지 | 기본값 `mcp` 유지 |
| `--token-path` | 유지 | 기존 경로 override |
| `--ensure-daemon` | 유지 | 기존 semantics 유지 |

#### 5.8.2 신규 옵션 추가

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `--transport` | `stdio` | `stdio|http|both` |
| `--http-bind` | `127.0.0.1` | HTTP listen address |
| `--http-port` | `3847` | HTTP listen port |

#### 5.8.3 모드별 유효성

1. `stdio`: HTTP 옵션 무시(경고 로그 1회).
2. `http`: stdio I/O loop 미기동.
3. `both`: stdio + HTTP 동시 기동.
4. 기존 stdio 실행 커맨드는 인자 변경 없이 그대로 동작해야 한다.

### 5.9 에러 규약

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

| 상황 | status | body |
|---|---:|---|
| token 누락/무효 | 401 | `{"error":"invalid or missing token"}` |
| origin 거부 | 403 | `{"error":"origin not allowed"}` |
| content-type 불일치 | 415 | `{"error":"expected application/json"}` |
| session 누락 | 400 | `{"error":"missing Mcp-Session-Id header"}` |
| session 무효/만료 | 401 | `{"error":"session expired or invalid"}` |

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

### WS1. Core 분리 + Bridge 전환

1. `src/mcp/{core,tools,bridge,traffic,types,error}.rs` 분리.
2. `bridge.call`을 `async &self`로 전환.
3. `daemon_start_lock` + double-check + `spawn_blocking` 도입.
4. stdio 루프는 `src/mcp/transport_stdio.rs`로 이동.

### WS2. HTTP transport 추가

1. `src/mcp/transport_http.rs` 구현(`POST /mcp`, `OPTIONS /mcp`, `GET /healthz`).
2. Bearer/Origin/CORS 구현(§5.4 strict).
3. `src/mcp/session.rs`로 `Mcp-Session-Id` TTL 관리.
4. 포트 충돌 시 3848~3857 순차 탐색.

### WS3. `both` supervisor 정리 (JoinSet + select!)

1. `JoinSet`으로 stdio/http task 등록.
2. `select!`로 signal/task completion/fatal 이벤트 처리.
3. HTTP fatal 시 fail-fast 종료 경로 구현.

### WS4. 앱 연동

1. `CrabProxyMacApp/Sources/CrabProxyMacApp/MCPHttpService.swift` 추가.
2. `ProxyViewModel.swift`, `SettingsView.swift`, `CrabProxyMacApp.swift` 변경.
3. 앱이 시작한 MCP 프로세스는 `willTerminate`에서 반드시 종료.

### WS5. 문서/운영

1. stdio/HTTP/both 연결 가이드.
2. IDE 설정 예시(토큰/endpoint).
3. 트러블슈팅(401, CORS, 포트 충돌, daemon unreachable).

---

## 8. 테스트 전략

### 8.1 단위 테스트

1. tool argument validation.
2. JSON-RPC/HTTP 에러 매핑.
3. CORS preflight 헤더명 검증 (`Access-Control-Allow-*`).
4. 세션 TTL/청소 로직.
5. bridge start-once 경합 테스트(동시 20요청에서 daemon spawn 1회 보장).

### 8.2 통합 테스트

1. stdio initialize/list/call 회귀.
2. HTTP initialize/list/call.
3. parity diff (32개 도구 샘플).
4. HTTP bind 실패/충돌 시 fallback 포트 탐색.
5. `both` 모드에서 HTTP fatal 시 exit 1 검증.

### 8.3 E2E

1. 앱에서 HTTP MCP ON → IDE 연결 → rules/traffic 조회.
2. 앱 종료 시 MCP 프로세스 종료 확인.
3. stdio EOF 이후 HTTP 서비스 지속 확인.

---

## 9. 리스크와 대응

| 리스크 | 영향 | 대응 |
|---|---|---|
| transport 결과 불일치 | 사용자 혼란 | `McpCore` 단일화 + parity 자동 테스트 |
| daemon start 경합 | 중복 spawn/불안정 시작 | `daemon_start_lock` + double-check |
| blocking start가 runtime 정체 | tail latency 증가 | `spawn_blocking` 격리 |
| HTTP 부분 장애 은닉 | 운영 관측성 저하 | HTTP fatal fail-fast + 상위 재시작 |
| CLI 옵션 회귀 | 기존 사용자 중단 | 기존 옵션 유지 + 회귀 테스트 |

---

## 10. Gate / DoD

### Gate 1

1. `src/mcp/*` 분리 완료.
2. bridge async 전환 + start-once 보호 완료.
3. stdio 회귀 테스트 통과.

### Gate 2

1. HTTP transport + 인증 + 세션 + CORS 구현.
2. CORS 헤더명/값 검증 테스트 통과.
3. parity 테스트 통과.

### Gate 3

1. `both` supervisor 완료(HTTP fatal fail-fast).
2. 앱 연동 UI/프로세스 lifecycle 완료.
3. 앱 종료 시 MCP 종료 보장.

### 최종 DoD

1. stdio/HTTP 모두 실사용 가능.
2. 32개 도구 동등성 확보.
3. CLI 기존 옵션/명령 호환 유지.
4. 보안 기본값(localhost + bearer + origin + CORS strict) 충족.
5. 회귀/통합/E2E 테스트 통과.

---

## 11. 오픈 이슈

1. protocol version을 strict(`2024-11-05` only)로 계속 유지할지, 호환 모드(복수 허용)를 둘지.
2. app supervisor에서 HTTP fatal 자동 재시작(백오프 포함)을 v6에 포함할지.
3. SSE(`GET /mcp`) 도입 시 notification/backpressure 정책을 어떻게 정의할지.
