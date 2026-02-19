# Crab Proxy One-Shot 전환 계획서 v3 (Quality First)

## 0) 결론 요약 (고정 의사결정)

본 문서는 구현 복잡도보다 품질을 우선한다. 아래 3개 결정은 고정한다.

- D1. XPC 호출 주체: `crabd` 직접 호출 (앱 브리지 제거)
- D2. IPC 인증: `UDS 권한 + 세션 토큰` 이중 인증
- D3. FFI fallback: 제거 (`daemon` 단일 실행 경로)

핵심 원칙은 "단일 제어 평면, 단일 상태 소스, fail-closed 보안"이다.

---

## 1) 목표와 비목표

### 목표

- 현재 `FFI 인프로세스` 구조에서 `daemon + IPC + MCP` 3단계 목표 상태로 한 번에 전환
- `CrabProxyMacApp`, `crabctl`, `crab-mcp`가 동일한 `crabd` 상태를 공유
- 사용자 환경에서 Rust 설치 없이 앱 설치만으로 동작
- 프리릴리즈 단계에서 품질 게이트를 통과한 후 단일 릴리즈로 전환

### 비목표

- 원격(네트워크) 제어 API 공개
- 멀티 호스트 분산 제어
- FFI 병행 운영

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
                         │ NSXPCConnection (.privileged)
                  ┌──────▼────────────────┐
                  │   CrabProxyHelper     │
                  │ (PF/인증서, root)     │
                  └───────────────────────┘
```

핵심 변화:
- 앱 내부 FFI 호출 제거
- 권한 작업은 `crabd -> Helper` 직접 호출
- 앱은 순수 클라이언트(UI) 역할로 축소

---

## 4) ADR (Architecture Decision Record)

## ADR-001: `crabd`가 Helper를 직접 호출

결정:
- XPC privileged 작업(PF/인증서)은 `crabd` 단일 주체가 수행

채택 이유:
- CLI/MCP가 앱 없이도 동일 기능 수행 가능
- 권한 작업 진입점을 단일화해 감사/보안 정책 명확화
- 앱 생명주기와 시스템 제어 기능을 분리

대가/주의점:
- Helper의 클라이언트 코드서명 검증 정책 업데이트 필요
- launchd/번들 ID/서명 파이프라인 변경 범위 확대

수용 기준:
- Helper가 허용한 서명된 `crabd`만 XPC 연결 허용
- 앱이 직접 Helper 호출하지 않아도 기능 동등성 유지

## ADR-002: UDS + 토큰 이중 인증

결정:
- IPC 인증을 파일 권한 기반 + 토큰 기반으로 구성

채택 이유:
- 동일 사용자 내 다른 프로세스 오남용 위험 축소
- 클라이언트 구분/세션 폐기/회전 정책 설계 가능

대가/주의점:
- 토큰 생성/회전/배포 정책 구현 필요
- CLI 단독 시작 흐름과 충돌하지 않게 초기화 프로토콜 설계 필요

수용 기준:
- handshake 실패 시 제어 API 접근 불가 (fail-closed)
- 토큰 탈락/만료/회전 시 재인증 동작 검증

## ADR-003: FFI fallback 제거

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
- peer credential 검사: 동일 uid 검증 (OS 제공 peer cred)

### 5.2 세션 토큰

- 토큰 경로: `~/Library/Application Support/CrabProxy/run/session.token`
- 파일 권한: `0600`
- 토큰 생성: daemon 시작 시 CSPRNG로 생성 (최소 256-bit)
- 토큰 전달: `system.handshake` 요청 본문에 포함
- 회전 정책:
  - daemon 재시작 시 강제 회전
  - `system.rotate_token` 호출 시 수동 회전

### 5.3 인증 성공 조건

모두 만족해야 인증 성공:
- UDS 파일 권한 검사 통과
- peer credential uid 검사 통과
- 토큰 검증 통과
- protocol_version 호환 통과

하나라도 실패하면 즉시 연결 거부.

### 5.4 XPC 권한

- Helper는 허용 식별자 화이트리스트 기반 검증
- 기본 허용 대상: `crabd`
- 검증 항목: bundle identifier + team identifier + designated requirement
- helper 메서드는 최소 권한 원칙으로 분리(`enable_pf`, `disable_pf`, `install_cert`, `remove_cert`, `check_cert`)

---

## 6) Daemon 생명주기 (품질 우선 정책)

### 시작/유지

- canonical owner: `launchd LaunchAgent`
- 앱/CLI/MCP는 daemon 미실행 시 `launchctl kickstart`로 시작 요청
- 중복 spawn 금지 (launchd 단일 인스턴스 보장)

### 종료

- 기본 정책: 클라이언트가 없어도 daemon 유지 (proxy 실행 상태 보호)
- 명시적 종료만 허용: `daemon.shutdown`
- idle auto-exit 정책은 v1 범위에서 제외 (예측가능성 우선)

### 장애 복구

- launchd가 crash restart 담당
- 클라이언트는 재연결(backoff) + `logs.tail`로 유실분 복구
- stale socket/PID 수동 로직은 최소화 (launchd 소유권 우선)

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

- in-memory ring + sqlite append 전략
- `logs.tail(after_id, limit)`는 sqlite 기반 보장 조회
- overflow 발생 시에도 과거 로그 복구 가능

---

## 8) API 계약 v3 (네이밍 일관성 고정)

네임스페이스는 아래로 고정:
- `system.*`, `proxy.*`, `config.*`, `rules.*`, `logs.*`, `ca.*`, `helper.*`, `daemon.*`

### 필수 메서드

- `system.ping`
- `system.version`
- `system.handshake`
- `system.rotate_token`
- `proxy.start`
- `proxy.stop`
- `proxy.status`
- `proxy.replay`
- `config.get`
- `config.patch`
- `rules.get`
- `rules.apply`
- `logs.subscribe`
- `logs.unsubscribe`
- `logs.tail`
- `logs.clear`
- `ca.status`
- `ca.load`
- `ca.generate`
- `helper.enable_pf`
- `helper.disable_pf`
- `helper.install_cert`
- `helper.remove_cert`
- `helper.check_cert`
- `daemon.doctor`
- `daemon.shutdown`

### Notification

- `logs.event`
- `logs.overflow`
- `state.changed`
- `proxy.status_changed`

### 응답 공통 필드

- `revision`: 상태 변경 단조 증가값
- `request_id`: 추적용 서버 로그 상관 ID

---

## 9) 리포 구조 (Quality-first)

```text
CrabProxy/
├── Cargo.toml                        # workspace root
├── crab-mitm/                        # proxy engine library
├── crab-ipc/                         # protocol/codec/client/server shared
├── crabd/                            # daemon binary
├── crabctl/                          # CLI binary
├── crab-mcp/                         # MCP stdio server
└── CrabProxyMacApp/
    └── Sources/CrabProxyMacApp/
        ├── DaemonClient.swift
        ├── DaemonLifecycle.swift
        ├── ProxyViewModel.swift      # IPC 기반으로 교체
        └── RustProxyEngine.swift     # 제거 대상
```

정책:
- `RustProxyEngine.swift`와 C FFI 브리지는 v3 전환 완료 시 삭제
- 문서/CI/테스트도 daemon 경로만 유지

---

## 10) 데이터 마이그레이션

- 전환 시점 1회 마이그레이션만 수행
- 소스: 앱 `UserDefaults`
- 대상: daemon state DB
- 완료 마크: `migration.v3.completed = true` (daemon 저장소에 기록)

규칙:
- 성공 전까지 daemon 모드 활성화 금지
- 실패 시 앱에서 명확한 복구 가이드 출력
- 재시도는 idempotent해야 함

---

## 11) 실행 계획 (내부 게이트)

### Gate 0: 설계 고정 (D+3)

- ADR-001/002/003 승인
- API 네이밍/에러코드/핸드셰이크 스펙 확정
- Helper 보안 정책(허용 식별자/요구사항) 확정

산출물:
- API 스펙 v3
- 보안 모델 문서
- 상태/로그 저장 스키마 문서

### Gate 1: 플랫폼 기반 (D+10)

- workspace + `crab-ipc` + `crabd` 골격 완성
- launchd 기반 lifecycle
- handshake + token + peer credential 구현

산출물:
- IPC 통합 테스트
- 인증 실패 케이스 테스트

### Gate 2: 엔진/권한 통합 (D+18)

- proxy/rules/config/log/replay를 daemon 상태와 통합
- `crabd -> Helper` 직접 XPC 경로 구현
- state sqlite + logs tail 복구 경로 완성

산출물:
- 엔드투엔드 제어 테스트
- XPC 보안 검증 테스트

### Gate 3: 클라이언트 전환 (D+24)

- 앱 IPC 전환 완료
- `crabctl`, `crab-mcp` IPC 연동 완료
- UserDefaults -> daemon 마이그레이션 완료

산출물:
- app/cli/mcp 상호운용 테스트
- 마이그레이션 테스트 리포트

### Gate 4: 하드닝 (D+31)

- 장애 주입(crash, timeout, malformed, auth fail)
- 부하 테스트(log burst, 동시 클라이언트)
- 코드사인/notarization 검증

산출물:
- release candidate 품질 리포트
- blocker 0개 확인

---

## 12) 테스트 전략 (품질 기준)

### 12.1 기능

- Start/Stop/Status/Rules/Map Local/Map Remote/Rewrite/Replay
- Throttle/Inspect/Allowlist/CA 전체 시나리오

### 12.2 보안

- 무토큰/오토큰/만료토큰/권한오류/버전불일치
- 비허용 바이너리의 Helper XPC 접근 거부

### 12.3 복구

- daemon crash 후 launchd 재기동 + 클라이언트 재연결
- 로그 overflow 후 `logs.tail` 복구
- 마이그레이션 중 중단/재시도 idempotency

### 12.4 성능/부하

- 동시 클라이언트 N개(앱+CLI+MCP)에서 제어 일관성
- 로그 burst 처리량과 지연
- 장시간 soak test (>= 24h)

---

## 13) 프리릴리즈 운영 전략 (No Fallback)

- 내부 카나리: 개발/QA/소수 사용자 순으로 점진 확장
- 릴리즈 블로커 기준:
  - P0/P1 결함 0건
  - 보안 결함 0건
  - 데이터 손실 재현 0건
- fallback 경로 없음: 결함은 수정 후 재배포 원칙

---

## 14) 일정 가이드 (품질 우선)

- Gate 0: 3일
- Gate 1: 7일
- Gate 2: 8일
- Gate 3: 6일
- Gate 4: 7일
- 총합: 약 4.5~5.5주

---

## 15) 완료 정의 (Definition of Done)

아래 조건을 모두 충족해야 v3 전환 완료로 본다.

- FFI 코드 경로 제거 완료
- 앱/CLI/MCP가 동일 daemon 상태를 읽고 제어함
- `crabd -> Helper` privileged 경로가 보안 검증과 함께 동작함
- 인증(UDS+토큰) 및 버전 협상 실패가 fail-closed로 동작함
- 마이그레이션/복구/부하/보안 테스트가 게이트 기준을 통과함
- 운영 문서(README, 진단 가이드, 장애 대응 플로우) 반영 완료

---

## 16) 최종 제안

- 본 전환은 "복잡도 최소"가 아니라 "품질 최대" 전략이다.
- 따라서 초기 개발 비용은 증가하지만, 전환 후 운영 리스크와 상태 불일치 리스크를 구조적으로 제거한다.
- 본 문서 기준으로 진행 시, 장기적으로 MCP/자동화 확장에 가장 안정적인 기반을 확보할 수 있다.
