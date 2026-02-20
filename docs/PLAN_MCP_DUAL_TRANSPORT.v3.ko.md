# PLAN: MCP Dual Transport (stdio + Streamable HTTP) v3

## 0. v2 리뷰 결과 (요약)

아래는 v2 문서를 현재 코드와 대조한 결과다.

| 리뷰 항목 | v2 상태 | v3 반영 |
|---|---|---|
| 파일 경로/구조 정합성 | 신규 경로 설명이 실제 코드 구조와 일부 불일치 | **현재 구조 기준**으로 재정의 (`src/bin/crab-mcp.rs` 중심, `src/mcp/*` 단계적 분리) |
| 실제 도구 목록 | "45개" 표기와 실제 열거/합계 불일치 | **실코드 기준 32개 전체 목록**으로 고정 |
| stdio/HTTP 동시 실행 | `--transport both` 존재만 언급, 수명주기 미흡 | **시작/종료/오류 전파 규칙** 명시 |
| crabd IPC 브리지 | `McpBridge` 개념 중심, 실제 호출 흐름 불명확 | `ensure_daemon_started -> token read -> send_rpc(handshake+call)` 명시 |
| MCP 프로토콜 버전 | 스펙/호환 정책이 추상적 | `2024-11-05` 기준의 **요청 처리 정책** 명시 |
| Streamable HTTP 세션 | stateful/stateless 경계가 불명확 | **MCP 세션은 stateful, crabd 세션은 비재사용**으로 분리 명시 |
| hyper 재사용 전략 | 방향은 있으나 구체성 부족 | 기존 `hyper/hyper-util/http-body-util/tokio` 기반 구현 경로 명시 |
| 앱 연동 파일 구조 | Swift 스타일/실제 파일과 일부 불일치 | 실제 `ObservableObject` + `ProxyViewModel/SettingsView/CrabProxyMacApp` 기준으로 정렬 |

---

## 1. 목표

1. 단일 바이너리(`crab-mcp`)에서 `stdio`와 Streamable HTTP를 모두 지원한다.
2. 두 transport에서 **동일한 도구 집합(32개)과 동일한 의미/에러 규약**을 제공한다.
3. macOS 앱에서 HTTP MCP 서버를 시작/중지하고 endpoint/token 정보를 확인할 수 있게 한다.
4. 기존 stdio 워크플로우(Codex/IDE spawn 방식) 회귀를 0으로 유지한다.

## 2. 비목표 (v3 범위 제외)

1. 인터넷 공개 바인딩(공인 네트워크 노출) 운영.
2. 멀티 유저/조직 계정 인증 체계.
3. crabd IPC 프로토콜 자체 개편.
4. MCP 도구 의미(룰/트래픽 동작)의 대규모 변경.

---

## 3. 현재 상태 (코드 기준)

### 3.1 핵심 파일

| 파일 | 현재 상태 |
|---|---|
| `crab-mitm/src/bin/crab-mcp.rs` | 1486줄, stdio MCP + 도구 실행 + traffic 집계 |
| `crab-mitm/src/daemon/mod.rs` | 1681줄, IPC 서버/인증/scope/RPC dispatch |
| `crab-mitm/src/ipc.rs` | 168줄, RPC 타입 |
| `crab-mitm/src/proxy.rs` | 2380줄, 프록시 엔진 |
| `crab-mitm/src/rules.rs` | 453줄, 룰 타입/매칭 |

### 3.2 실제 MCP 도구 수

- `crab-mcp.rs`의 `"name": "crab_*"` 정의 기준 **32개**.
- v3의 parity/테스트/문서 기준 수치는 32개를 단일 소스로 사용한다.

### 3.3 crabd 브리지 실제 호출 흐름

현재 도구 호출 시 흐름:

1. `ensure_daemon_started(daemon_path, socket_path)`
2. `read_token_from_file(mcp.token)`
3. `send_rpc(...)`
4. `send_rpc` 내부에서
   - `system.handshake`
   - 실제 RPC method 호출

핵심:

1. `send_rpc`는 호출마다 Unix socket 연결을 새로 연다.
2. 따라서 MCP HTTP 세션을 도입해도 crabd 세션 ID를 재사용하지 않는다.
3. v3는 이 제약을 유지하고, MCP 세션과 crabd 호출 수명주기를 분리한다.

### 3.4 앱 구조

| 파일 | 역할 |
|---|---|
| `CrabProxyMacApp/Sources/CrabProxyMacApp/ProxyViewModel.swift` | `ObservableObject` 기반 상태/제어 |
| `CrabProxyMacApp/Sources/CrabProxyMacApp/SettingsView.swift` | 설정 UI |
| `CrabProxyMacApp/Sources/CrabProxyMacApp/CrabProxyMacApp.swift` | 앱 lifecycle (`willTerminate` 훅 존재) |

---

## 4. v3 목표 아키텍처

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

설계 원칙:

1. `McpCore`에 도구 정의/검증/실행/에러 매핑을 집중한다.
2. transport 계층은 입출력/인증/세션 처리만 담당한다.
3. 기존 crabd 인증/권한(scope) 모델을 그대로 사용한다.

---

## 5. 프로토콜/세션/보안 결정

### D1. MCP 프로토콜 버전 정책

1. 서버 광고 버전: `2024-11-05`.
2. `initialize.params.protocolVersion`이 `2024-11-05`가 아니면 `-32602` 반환.
3. 에러 `data`에 `supported: ["2024-11-05"]`를 포함해 클라이언트 진단성을 높인다.

### D2. Streamable HTTP 세션 정책

선택: **stateful (MCP 레이어만)**

1. `initialize` 성공 시 `Mcp-Session-Id` 발급.
2. 이후 `POST /mcp`는 동일 `Mcp-Session-Id` 사용.
3. 세션 저장 항목:
   - session_id
   - created_at / last_activity
   - client_info / capabilities
4. **저장하지 않는 항목:** crabd bridge session/connection 정보.
5. TTL: 30분(기본), 만료 시 HTTP 401 + JSON-RPC 에러 본문.

### D3. HTTP 엔드포인트 정책 (v3)

1. `POST /mcp`: JSON-RPC 요청 처리.
2. `OPTIONS /mcp`: CORS preflight.
3. `GET /healthz`: liveness.
4. `GET /mcp` SSE 및 `DELETE /mcp`는 v3 범위에서 제외(추후 확장).

### D4. 인증/보안 정책

1. 기본 bind: `127.0.0.1`.
2. `Authorization: Bearer <token>` 필수 (`mcp-http.token`, 권한 0600).
3. `Origin` 헤더가 있을 때 `localhost`/`127.0.0.1`만 허용.
4. CORS는 허용 origin **정확 매칭 반사** 방식 사용.
5. `Access-Control-Allow-Origin: http://localhost:*` 같은 와일드카드 포맷은 금지.
6. 도구 권한은 기존 `mcp.token` scope(`read`, `rules.write`, `control`)를 따른다.

### D5. `--transport` 런타임 규칙

CLI 옵션:

1. `--transport stdio|http|both` (기본 `stdio`)
2. `--http-bind` (기본 `127.0.0.1`)
3. `--http-port` (기본 `3847`)
4. `--http-token-path`

수명주기:

1. `stdio`: stdin EOF면 프로세스 종료.
2. `http`: signal(SIGINT/SIGTERM) 전까지 실행.
3. `both`:
   - 시작 시 stdio/http 모두 초기화 성공해야 정상 기동.
   - stdio EOF는 stdio task만 종료, HTTP는 계속 유지.
   - HTTP task 치명 오류(바인드 손실/loop panic) 발생 시 프로세스 종료.

---

## 6. 실제 도구 목록 (32개, 코드 기준)

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

합계: 3 + 3 + 7 + 3 + 5 + 10 + 1 = 32

---

## 7. 구현 계획

### WS1. McpCore 분리 (stdio 회귀 보호)

목표 구조:

```text
crab-mitm/src/
  mcp/
    mod.rs
    core.rs
    tools.rs
    bridge.rs
    traffic.rs
    types.rs
    error.rs
    transport_stdio.rs
    transport_http.rs
    session.rs
  bin/
    crab-mcp.rs
```

작업:

1. `tool_definitions`/`call_tool`/validation 로직을 `tools.rs`로 이동.
2. traffic 집계 로직을 `traffic.rs`로 이동.
3. daemon RPC 래퍼(`send_rpc` 기반)를 `bridge.rs`에 정리.
4. 공통 request dispatch를 `core.rs`로 이동.
5. `crab-mcp.rs`는 CLI 파싱 + transport wiring만 담당.

### WS2. HTTP Transport 구현 (기존 의존성 재사용)

재사용 의존성:

1. `hyper`
2. `hyper-util`
3. `http-body-util`
4. `tokio`

작업:

1. `POST /mcp` 요청 파싱/응답 구현.
2. Bearer 인증 + Origin/CORS 처리.
3. `Mcp-Session-Id` 세션 매니저 구현(TTL 포함).
4. `GET /healthz`, `OPTIONS /mcp` 구현.
5. 모든 요청을 `McpCore.handle_request()`로 위임.

### WS3. both 모드 안정화

1. stdio/http 동시 실행 supervisor 구성.
2. 종료 원인별 상태 코드 정의(EOF, signal, fatal error).
3. 로그 키워드 통일(`transport=stdio|http`, `event=start|stop|fatal`).

### WS4. 앱 연동 (실제 Swift 구조 기준)

신규 파일:

1. `CrabProxyMacApp/Sources/CrabProxyMacApp/MCPHttpService.swift`

기존 파일 변경:

1. `CrabProxyMacApp/Sources/CrabProxyMacApp/ProxyViewModel.swift`
2. `CrabProxyMacApp/Sources/CrabProxyMacApp/SettingsView.swift`
3. `CrabProxyMacApp/Sources/CrabProxyMacApp/CrabProxyMacApp.swift`

원칙:

1. `ObservableObject` + `@Published` 유지 (`@Observable`로 전환하지 않음).
2. 앱이 시작한 MCP 프로세스는 `willTerminate`에서 반드시 종료.
3. UI는 ON/OFF, endpoint/token path, port, last error 제공.

### WS5. 문서/운영 가이드

1. stdio 연결 가이드.
2. HTTP 연결 가이드.
3. both 모드 운용 가이드.
4. 트러블슈팅(401, token 권한, 포트 충돌, daemon unreachable).

---

## 8. 테스트/수용 기준

### 8.1 Parity 기준

1. `tools/list` 결과의 도구 집합이 동일(32개).
2. 같은 입력의 `tools/call` 결과 `structuredContent`가 동일.
3. JSON-RPC 에러 코드/메시지 규약이 동일.

### 8.2 테스트 매트릭스

단위 테스트:

1. tool arg validation
2. auth/origin/cors
3. session ttl
4. error mapping

통합 테스트:

1. stdio initialize/list/call
2. HTTP initialize/list/call
3. parity diff(32개 도구 샘플)

E2E:

1. 앱에서 HTTP MCP ON 후 IDE 연결
2. 앱 종료 시 MCP 프로세스 종료 확인
3. both 모드에서 stdio EOF 후 HTTP 지속 확인

### 8.3 DoD

1. stdio + HTTP 모두 실사용 가능.
2. 32개 도구가 transport 무관하게 동일 동작.
3. 앱에서 HTTP MCP 관리 가능.
4. 보안 기본값(localhost + bearer + origin 검증) 충족.
5. stdio 기존 사용자 회귀 없음.

---

## 9. 일정 (러프)

1. WS1: 1.5~2일
2. WS2: 2~3일
3. WS3: 1일
4. WS4: 1~1.5일
5. WS5: 0.5일

총 6~8일

---

## 10. 오픈 이슈

1. `initialize`에서 `2024-11-05` 외 버전을 허용할지(엄격 모드 vs 호환 모드).
2. HTTP 세션 저장소를 메모리만 사용할지(현재안) 또는 선택적 영속 저장을 둘지.
3. `GET /mcp` SSE/notification 채널을 v4로 미룰지 여부.
