# PLAN: MCP Dual Transport (stdio + HTTP) v1

## 0. 배경
- 현재 Crab는 `crab-mcp`를 `stdio MCP` 서버로 제공하고, 내부적으로 `crabd` IPC를 호출한다.
- 이 방식은 Codex/IDE 연결이 안정적이지만, "앱에서 MCP를 켜고 URL로 붙는(Figma 스타일)" UX는 제공하지 못한다.
- 목표는 `stdio`를 유지하면서 `HTTP MCP`도 추가해 두 방식 모두 지원하는 것이다.

---

## 1. 목표
1. `stdio MCP`와 `HTTP MCP`를 동시에 지원한다.
2. 두 transport에서 **동일한 도구(tool) 집합과 동일한 동작**을 보장한다.
3. macOS 앱에서 HTTP MCP를 켜고 끌 수 있게 한다.
4. 보안(로컬 바인딩, 인증 토큰, scope 제어)을 유지한다.

## 2. 비목표 (v1 범위 제외)
1. 원격 공개(인터넷 노출) MCP 서버 운영.
2. 다중 사용자 계정 공유 인증.
3. MCP 툴 자체의 대규모 재설계(기존 툴의 의미 변경).

---

## 3. 현재 상태 (As-Is)
- `crab-mcp`는 stdio 프레이밍 MCP 서버.
- 툴 호출은 `send_rpc(...)`로 `crabd` IPC 브리지.
- `mcp` principal scope: `read`, `rules.write`, `control`.
- 앱은 현재 MCP 프로세스를 직접 관리하지 않음(IDE/Codex가 실행).

---

## 4. 목표 아키텍처 (To-Be)
```text
               +--------------------+
IDE/Codex ---->| stdio transport    |----+
               +--------------------+    |
                                           v
               +--------------------+   +------------------+
IDE/Tool ----->| HTTP transport     |-->| MCP Core/Tools   |--> IPC --> crabd
               +--------------------+   +------------------+
                        ^
                        |
                 CrabProxyMacApp
            (HTTP MCP start/stop, endpoint/token 표시)
```

핵심 원칙:
1. Tool registry/validation/execution은 **단일 Core**에서만 구현.
2. Transport는 입출력 어댑터만 담당.
3. `crabd` API/권한 모델은 기존 체계 재사용.

---

## 5. 핵심 설계 결정

### D1. 구현 형태
- 선택지 A: `crab-mcp` 단일 바이너리에 `--transport stdio|http` 모드
- 선택지 B: `crab-mcp`(stdio) + `crab-mcp-http`(별도)
- **권장: A (단일 바이너리 모드)**
  - 장점: 배포/서명/버전 동기화 단순, 코드 중복 최소.

### D2. HTTP 프로토콜
- 선택지 A: Streamable HTTP만 지원
- 선택지 B: Streamable HTTP + SSE 모두 지원
- **권장: A (v1은 Streamable HTTP 우선)**  
  - 필요 시 v2에서 SSE 추가.

### D3. HTTP 보안
- 기본값:
  1. `127.0.0.1` 바인딩 (외부 NIC 미노출)
  2. Bearer token 필수
  3. token 파일 `0600` 권한
  4. 기존 `mcp` scope 정책 유지
- token 회전: 앱/CLI에서 명시적 rotate 제공.

### D4. 라이프사이클
- **v1 권장: 앱 관리형(App-managed)**
  - 앱에서 HTTP MCP 시작/중지.
  - 앱 종료 시 HTTP MCP도 종료(좀비 방지).
- launchd 상시 서비스는 v2 후보.

---

## 6. 작업 분해 (Workstreams)

### WS1. MCP Core 분리
목표: stdio/http 공통 로직 단일화.

예상 변경:
1. `crab-mitm/src/mcp_core/mod.rs` (신규)
2. `crab-mitm/src/mcp_core/tools.rs` (신규)
3. `crab-mitm/src/bin/crab-mcp.rs` (stdio/HTTP adapter 진입점)

작업:
1. `initialize`, `tools/list`, `tools/call`, `ping` 핸들러를 Core로 이동.
2. 기존 툴 스키마/validation을 Core로 이동.
3. stdio adapter는 프레이밍 read/write만 담당.

### WS2. HTTP Transport 추가
목표: 동일 Core를 HTTP로 노출.

예상 변경:
1. `crab-mitm/src/mcp_http/mod.rs` (신규)
2. `crab-mitm/src/bin/crab-mcp.rs`에 `--transport http`, `--http-bind`, `--http-port`, `--http-token-path`

엔드포인트(v1):
1. `POST /mcp` : MCP JSON-RPC request 처리
2. `GET /healthz` : liveness

작업:
1. HTTP 요청 -> Core request 변환.
2. Core 응답 -> HTTP JSON 응답 반환.
3. Authorization header 검증(`Bearer <token>`).

### WS3. 앱 연동 (HTTP MCP ON/OFF)
목표: 앱에서 HTTP MCP를 제어하고 연결 정보를 제공.

예상 변경:
1. `CrabProxyMacApp/Sources/CrabProxyMacApp/MCPService.swift` (신규)
2. `CrabProxyMacApp/Sources/CrabProxyMacApp/ProxyViewModel.swift`
3. `CrabProxyMacApp/Sources/CrabProxyMacApp/SettingsView.swift`

UI 항목(v1):
1. `Enable MCP (HTTP)` 토글
2. Endpoint 표시 (`http://127.0.0.1:<port>/mcp`)
3. Token 파일 경로/복사 버튼
4. 상태 표시(Running/Stopped, 마지막 에러)

### WS4. 보안/운영성
목표: 로컬 서버 운영 안전성 확보.

작업:
1. 기본 포트 충돌 시 자동 탐색(예: 3847 -> 가용 포트).
2. token 파일 권한 검사/복구.
3. 실패 진단 메시지 표준화 (`port in use`, `token missing`, `auth failed`).

### WS5. 문서/도구 설정
목표: 사용자 연결 경험 단순화.

작업:
1. IDE별 설정 예시 업데이트(Codex/Cursor/Claude Desktop).
2. stdio/HTTP 중 어떤 상황에서 무엇을 권장하는지 가이드.
3. 트러블슈팅 섹션 추가.

---

## 7. 도구 동등성(Parity) 정책
모든 MCP tool은 transport와 무관하게 동일해야 한다.

검증 규칙:
1. `tools/list` 결과가 stdio/http에서 동일(정렬 제외).
2. 동일 입력으로 `tools/call` 결과 `structuredContent`가 동일.
3. 에러 코드/메시지 포맷 일치.

대상:
1. proxy 제어(`status/start/stop`)
2. engine 설정(`listen/inspect/throttle/client_allowlist/transparent/ca`)
3. rules CRUD(`allow/map_local/map_remote/status_rewrite`)
4. traffic/log 조회(`crab_logs_tail`, `crab_traffic_tail`, `crab_traffic_get`)

---

## 8. 테스트 계획

### 8.1 단위 테스트
1. tool argument validation
2. HTTP auth/token 검증
3. transport adapter <-> core 변환

### 8.2 통합 테스트
1. stdio handshake + tools/list + tools/call
2. HTTP POST /mcp initialize + tools/list + tools/call
3. 동일 시나리오에 대한 parity 비교

### 8.3 E2E 테스트
1. 앱에서 HTTP MCP ON -> IDE 연결 -> rules/traffic 조회 성공
2. 앱 종료 시 HTTP MCP 종료 확인
3. 포트 충돌/토큰 오류 시 복구 또는 명확한 에러 표시

---

## 9. 릴리즈 단계 (Gate)

### Gate 1: Core + stdio 회귀 무손상
- 완료 기준:
  1. 기존 stdio 동작 100% 유지
  2. 툴 목록/결과 회귀 테스트 통과

### Gate 2: HTTP 서버 기능 완료
- 완료 기준:
  1. HTTP MCP initialize/tools/list/tools/call 정상
  2. auth/token/port 충돌 처리 검증

### Gate 3: 앱 연동 완료
- 완료 기준:
  1. 앱에서 ON/OFF 가능
  2. IDE가 endpoint/token으로 연결 가능
  3. 종료/재시작/오류 UX 검증

---

## 10. 리스크와 대응
1. 리스크: stdio와 HTTP 결과 불일치  
   대응: Core 단일화 + parity 자동 테스트.
2. 리스크: 로컬 포트 노출 오남용  
   대응: localhost 바인딩 강제 + bearer token 필수.
3. 리스크: 앱-서버 라이프사이클 꼬임  
   대응: 앱 관리형 단일 정책(v1), 종료 훅에서 확실히 정리.
4. 리스크: 사용자 설정 복잡도 증가  
   대응: 앱에서 endpoint/token 복사 UX + 문서 단순화.

---

## 11. 일정(러프)
1. WS1 Core 분리: 1~2일
2. WS2 HTTP transport: 2~3일
3. WS3 앱 연동: 1~2일
4. WS4/WS5 테스트/문서: 1~2일

총 5~9일(병렬도에 따라 변동).

---

## 12. 최종 수용 기준 (Definition of Done)
1. `stdio`와 `HTTP` 모두에서 같은 MCP tool set 제공.
2. 앱에서 HTTP MCP ON/OFF 및 연결 정보 제공 가능.
3. rules/traffic 포함 주요 시나리오가 IDE에서 실사용 가능.
4. 보안 기본값(localhost + token + scope) 충족.
5. 회귀 테스트에서 기존 stdio 사용성 저하 없음.
