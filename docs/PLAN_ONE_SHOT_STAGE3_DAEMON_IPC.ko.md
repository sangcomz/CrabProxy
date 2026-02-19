# Crab Proxy One-Shot 전환 계획서 (현재 -> 3단계 일괄)

## 1) 목적
- 목표: 현재 `FFI 인프로세스` 구조에서 바로 `3단계(daemon + IPC + MCP)` 목표 상태까지 한 번에 전환한다.
- 결과: `CrabProxyMacApp`, `crabctl(CLI)`, `crab-mcp(MCP)`가 동일한 `crabd` 엔진 인스턴스를 제어한다.
- 제약: 사용자 설치 경험은 유지한다. 최종 사용자는 Rust 설치가 필요 없어야 한다.

## 2) 현재와 목표 상태

### 현재 (As-Is)
- 앱이 Rust 라이브러리를 FFI로 직접 호출해 프록시 엔진을 제어
- UI, 엔진 제어 경계가 프로세스 내부에 강하게 결합
- CLI/MCP가 동일 상태를 안전하게 공유하기 어려움

### 목표 (To-Be: 3단계)
- 엔진: `crabd` (Rust daemon, 별도 프로세스)
- 제어: `Unix Domain Socket + JSON-RPC 2.0`
- 클라이언트:
  - `CrabProxyMacApp` (UI)
  - `crabctl` (운영/자동화 CLI)
  - `crab-mcp` (IDE/AI 연동용 MCP 서버)
- 단일 진실 소스: 룰/상태/로그는 daemon이 authoritative

## 3) 범위

### 포함
- `crab-mitm`에 `crabd`, `crabctl`, `crab-mcp` 실행 경로 추가
- 앱 엔진 제어를 FFI -> IPC 클라이언트로 전환
- 룰, 상태, 로그 스트림, replay를 daemon API로 통합
- 앱 번들에 daemon/cli/mcp 바이너리 포함 및 코드사인 반영
- 버전 협상, 재연결, 장애 복구 UX 구현

### 제외
- 원격 네트워크 제어 API 공개
- 멀티 호스트 분산 오케스트레이션
- 1차 릴리즈에서 FFI 코드 완전 삭제 (비상 fallback 용도로 유지 가능)

## 4) 아키텍처 결정
- IPC transport: Unix Domain Socket
- RPC protocol: JSON-RPC 2.0
- 버전 정책: `protocol_version` 핸드셰이크(최소/최대 지원 범위 검증)
- 인증/권한:
  - 소켓 파일 권한 `0600`
  - 앱이 생성한 세션 토큰 파일 검증
- 로그 전략:
  - `subscribe` 실시간 이벤트
  - `tail`/`pull` 백필 동시 제공
- 상태 저장:
  - daemon authoritative
  - 앱은 캐시 및 뷰 전용

## 5) 앱 관점 변화 (핵심)

### 장점
- 앱/CLI/MCP가 같은 엔진 상태를 공유 가능
- 앱 재시작과 엔진 생명주기를 분리해 안정성 향상
- MCP 연동이 자연스러워져 IDE/AI 자동화 확장 용이

### 단점/비용
- IPC/프로세스 관리 복잡도 증가
- 버전 불일치, 소켓 권한, 재연결 시나리오 대응 필요
- 초기 마이그레이션 기간 동안 QA 범위 확대

### 성능 영향
- 제어/로그 경로에 IPC 오버헤드는 존재
- 실제 프록시 데이터 경로는 daemon 내부 처리 중심이므로 체감 저하는 제한적
- 로그 폭주 구간은 배치 전송/backpressure로 제어

## 6) API 계약 (v1 초안)
- `system.ping`
- `system.version`
- `daemon.start_proxy`
- `daemon.stop_proxy`
- `daemon.status`
- `daemon.apply_rules`
- `daemon.get_rules`
- `daemon.set_network`
- `daemon.set_inspect`
- `daemon.set_throttle`
- `daemon.logs.subscribe`
- `daemon.logs.tail`
- `daemon.replay`
- `daemon.shutdown`

## 7) 구현 워크스트림

### WS-A: Rust daemon 코어
- `crabd` 진입점 및 런타임/상태 머신
- 기존 proxy/rules/inspect/throttle/replay를 daemon 상태로 통합
- 크래시 복구/헬스체크/진단 로그

### WS-B: IPC 레이어
- JSON-RPC 서버/클라이언트 공통 DTO
- 에러 코드 체계 및 타임아웃 표준화
- 버전 협상/호환성 검사

### WS-C: Mac App 전환
- `ProxyViewModel`의 엔진 호출을 IPC 호출로 교체
- 연결 상태 배지, 재시도, 실패 시 가이드 메시지
- FFI fallback 토글(릴리즈 초기 안전장치)

### WS-D: CLI + MCP
- `crabctl`: start/stop/status/rules/logs/replay
- `crab-mcp`: stdio MCP 서버, tool -> IPC 브리지
- IDE 연결 시 읽기/제어 권한 정책 정리

### WS-E: 배포/운영
- 앱 번들 내 바이너리 배치 경로 확정
- 코드사인/notarization 파이프라인 반영
- 릴리즈 진단 명령(`doctor`) 제공

## 8) 리포 변경 포인트 (예상)
- `/Users/sangcomz/projects/CrabProxy/crab-mitm/src/main.rs`
- `/Users/sangcomz/projects/CrabProxy/crab-mitm/src/daemon/*` (신규)
- `/Users/sangcomz/projects/CrabProxy/crab-mitm/src/ipc/*` (신규)
- `/Users/sangcomz/projects/CrabProxy/crab-mitm/src/mcp/*` (신규)
- `/Users/sangcomz/projects/CrabProxy/CrabProxyMacApp/Sources/CrabProxyMacApp/ProxyViewModel.swift`
- `/Users/sangcomz/projects/CrabProxy/CrabProxyMacApp/Sources/CrabProxyMacApp/RustProxyEngine.swift` (fallback 용도 축소)
- `/Users/sangcomz/projects/CrabProxy/CrabProxyMacApp/Sources/CrabProxyMacApp/*` (연결 상태/오류 UI)
- `/Users/sangcomz/projects/CrabProxy/README.md`
- `/Users/sangcomz/projects/CrabProxy/README.ko.md`
- `/Users/sangcomz/projects/CrabProxy/crab-mitm/README.md`
- `/Users/sangcomz/projects/CrabProxy/crab-mitm/README.ko.md`

## 9) 원샷 실행 플랜 (내부 게이트 포함)

### Gate 0: 설계 고정 (D+2~3)
- RPC 스키마, 에러코드, 생명주기(앱-데몬), 인증 정책 확정
- 산출물: API 스펙 문서, 상태 전이 다이어그램, 실패 처리표

### Gate 1: Engine 독립화 (D+7)
- `crabd + crabctl`만으로 start/stop/rules/status/logs 동작
- 산출물: Rust 단위/통합 테스트 통과, 로컬 E2E 스크립트

### Gate 2: App 전환 (D+13)
- 앱 주요 기능이 IPC 경로로 동작
- 산출물: Start/Stop, Rules(Map Local/Map Remote/Rewrite), Logs, Replay 회귀 통과

### Gate 3: MCP 연동 (D+17)
- `crab-mcp` tool 세트 구현, IDE 클라이언트 연동 검증
- 산출물: MCP 시나리오 테스트 및 권한 정책 검증

### Gate 4: 하드닝/릴리즈 (D+21~24)
- 재연결/timeout/권한 실패/버전 불일치/daemon 재시작 처리
- 산출물: 릴리즈 체크리스트, 전환 안전장치 검증, 배포 문서

## 10) 테스트 전략

### 자동화
- 단위: RPC 파서/검증, 룰 매핑, 상태 전이
- 통합: `crabd + crabctl`, `crabd + app`, `crabd + mcp`
- 회귀: Start/Stop, Map Local/Map Remote, Rewrite, Replay, Throttle

### 장애/복구
- daemon kill/restart
- 소켓 삭제/권한 오류
- 응답 timeout 및 malformed payload
- 앱 재실행 후 세션 복구

## 11) 프리릴리즈 전환 전략

### 롤아웃
- 내부 플래그: `engine_mode=daemon` 기본 ON
- 베타 채널에서 우선 검증 후 일반 배포

### 전환 안전장치
- 릴리즈 전까지 `engine_mode` 플래그로 daemon/ffi 경로 전환 가능 상태 유지
- 데이터 포맷은 전방 호환 우선
- daemon 비활성화 시에도 기존 핵심 기능 유지

## 12) 주요 리스크와 대응
- 버전 불일치: 핸드셰이크에서 즉시 차단 + 업그레이드 안내
- 권한/소켓 실패: `doctor` 진단 + 자동 재시도 + 수동 복구 버튼
- 로그 폭주: 배치 전송, 백프레셔, UI 샘플링
- 배포 이슈: 초기부터 번들 구조/서명 파이프라인 고정
- 기능 회귀: 핵심 시나리오 CI + 수동 체크리스트 병행

## 13) 일정 가이드 (병렬 작업 기준)
- 설계/스펙 고정: 2~3일
- daemon + IPC 코어: 5~7일
- 앱 IPC 전환: 4~6일
- CLI/MCP: 3~4일
- 하드닝/QA/릴리즈: 4~6일
- 총합: 약 3~4주

## 14) 최종 제안
- "한 번에 3단계"는 가능하다.
- 단, 외부 릴리즈는 1회로 하되 내부는 Gate 방식으로 끊어서 리스크를 통제한다.
- 우선순위는 `daemon 안정화 > 앱 전환 > MCP 확장`을 고정한다.
