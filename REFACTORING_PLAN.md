# CrabProxy 리팩토링 계획서

> **작성일**: 2026-02-15
> **최우선 목표**: 보안 (Security First)
> **분석 대상**: CrabProxy v1.1.0 (Rust crab-mitm + Swift macOS App)
> **비교 대상**: mitmproxy (Python), Proxyman (macOS)

---

## 목차

1. [프로젝트 현황 요약](#1-프로젝트-현황-요약)
2. [보안 리팩토링 — Critical (P0)](#2-보안-리팩토링--critical-p0)
3. [보안 리팩토링 — High (P1)](#3-보안-리팩토링--high-p1)
4. [프록시 엔진 개선 (P1)](#4-프록시-엔진-개선-p1)
5. [UI/UX 개선 — Quick Wins (P0)](#5-uiux-개선--quick-wins-p0)
6. [UI/UX 개선 — 구조 개선 (P1)](#6-uiux-개선--구조-개선-p1)
7. [UI/UX 개선 — 사용성 (P2)](#7-uiux-개선--사용성-p2)
8. [장기 로드맵 (P3)](#8-장기-로드맵-p3)
9. [리팩토링 액션 아이템 요약](#9-리팩토링-액션-아이템-요약)
10. [CrabProxy의 강점 (유지할 부분)](#10-crabproxy의-강점-유지할-부분)
11. [부록: mitmproxy vs CrabProxy 기술 비교](#11-부록-mitmproxy-vs-crabproxy-기술-비교)

---

## 1. 프로젝트 현황 요약

### 아키텍처

```
CrabProxy/
├── crab-mitm/          # Rust MITM 프록시 엔진 (~2500 LOC)
│   ├── src/
│   │   ├── ca.rs           # CA 인증서 관리 (ECDSA P-256, rcgen)
│   │   ├── proxy.rs        # 메인 프록시 로직 (1305줄)
│   │   ├── proxy/
│   │   │   ├── inspect.rs  # 바디 검사/로깅
│   │   │   ├── cert_portal.rs  # 모바일 인증서 포털
│   │   │   ├── response.rs     # HTTP 응답 헬퍼
│   │   │   └── transparent.rs  # 투명 프록시 (pf 연동)
│   │   ├── rules.rs        # 규칙 매칭 (allowlist, map_local, status_rewrite)
│   │   ├── ffi.rs          # C FFI 레이어 (762줄)
│   │   └── config.rs       # 설정 관리
│   └── Cargo.toml          # Rust 2024 edition, v1.1.0
│
├── CrabProxyMacApp/    # Swift macOS 앱 (~2000 LOC)
│   ├── Sources/CrabProxyMacApp/
│   │   ├── ProxyViewModel.swift    # 중앙 상태 관리 (996줄)
│   │   ├── ContentView.swift       # 메인 UI (2-panel HSplitView)
│   │   ├── SettingsView.swift      # 설정 화면
│   │   ├── RustProxyEngine.swift   # Rust FFI 브릿지
│   │   ├── CACertService.swift     # 인증서 설치/제거
│   │   ├── PFService.swift         # pf 방화벽 관리
│   │   └── ...
│   └── Sources/CrabProxyHelper/    # 특권 헬퍼 데몬
```

### 핵심 기술 스택

| 구성요소 | 기술 |
|---------|------|
| **프록시 엔진** | Rust + hyper 1.7 + tokio 1.47 |
| **TLS** | rustls 0.23 + rcgen 0.13 (ECDSA P-256) |
| **macOS 앱** | Swift 6.0 + SwiftUI (macOS 14+) |
| **FFI** | C header 기반 Rust↔Swift 바인딩 |

---

## 2. 보안 리팩토링 — Critical (P0)

> 즉시 수정이 필요한 보안 이슈. 프로덕션 환경에서 문제를 유발할 수 있음.

### 2.1 ECDSA Leaf 인증서에서 KeyEncipherment 제거

- **파일**: `crab-mitm/src/ca.rs:177-180`
- **현재 코드**:
  ```rust
  leaf_params.key_usages = vec![
      rcgen::KeyUsagePurpose::DigitalSignature,
      rcgen::KeyUsagePurpose::KeyEncipherment,  // ← 문제
  ];
  ```
- **문제**: `KeyEncipherment`는 RSA 키 교환 전용 용도이며, ECDSA 키에는 의미가 없음. 엄격한 TLS 클라이언트(일부 Java 앱, 기업 보안 소프트웨어)에서 경고 또는 연결 거부를 유발할 수 있음.
- **수정**: `KeyEncipherment` 제거, `DigitalSignature`만 유지
  ```rust
  leaf_params.key_usages = vec![
      rcgen::KeyUsagePurpose::DigitalSignature,
  ];
  ```
- **위험도**: 높음 | **작업량**: 소 (1줄 수정) | **난이도**: 낮음

### 2.2 CONNECT 사설 IP 차단 기본값 변경

- **파일**: `crab-mitm/src/proxy.rs:512-514`
- **현재 코드**:
  ```rust
  fn connect_private_block_enabled() -> bool {
      parse_env_bool_default_false(
          std::env::var("CRAB_CONNECT_BLOCK_PRIVATE").ok().as_deref()
      )
  }
  ```
- **문제**: `CRAB_CONNECT_BLOCK_PRIVATE` 환경변수가 설정되지 않으면 사설 IP(`127.0.0.1`, `10.x.x.x`, `192.168.x.x` 등)로의 CONNECT 터널이 기본 허용됨. 이는 SSRF(Server-Side Request Forgery) 공격 벡터가 될 수 있음.
- **수정**: 기본값을 `true`로 변경
  ```rust
  fn connect_private_block_enabled() -> bool {
      parse_env_bool_default_true(  // default_false → default_true
          std::env::var("CRAB_CONNECT_BLOCK_PRIVATE").ok().as_deref()
      )
  }
  ```
- **참고**: `inspect.rs:347-363`에 이미 `parse_env_bool_default_true` 함수가 존재하므로 재사용 가능. 다만 현재 `proxy.rs`에는 별도의 `parse_env_bool_default_false`가 있으므로 공통 유틸로 추출하는 것도 고려.
- **위험도**: 높음 | **작업량**: 소 (함수명 변경) | **난이도**: 낮음

### 2.3 루트 인증서 로딩 에러 로깅 추가

- **파일**: `crab-mitm/src/proxy/transparent.rs:144-145`
- **현재 코드**:
  ```rust
  for cert in roots.certs {
      let _ = root_store.add(cert);  // ← 에러 무시
  }
  ```
- **문제**: 시스템 루트 인증서 로딩 실패가 완전히 무시됨. 잘못된 인증서가 있어도 디버깅이 불가능하며, 루트 스토어가 비어 있을 경우 모든 업스트림 TLS 연결이 실패할 수 있음.
- **수정**:
  ```rust
  for cert in roots.certs {
      if let Err(err) = root_store.add(cert) {
          tracing::warn!(error = %err, "skipping invalid native root certificate");
      }
  }
  if root_store.is_empty() {
      tracing::error!("no valid root certificates loaded — upstream TLS will fail");
  }
  ```
- **위험도**: 중간 | **작업량**: 소 | **난이도**: 낮음

---

## 3. 보안 리팩토링 — High (P1)

> 보안 표준 준수 및 호환성 강화를 위한 개선.

### 3.1 CA 인증서에 SubjectKeyIdentifier 확장 추가

- **파일**: `crab-mitm/src/ca.rs:23-34`
- **현재 상태**: CA 인증서에 `SubjectKeyIdentifier` 확장이 없음
- **문제**: RFC 5280 §4.2.1.2에서 CA 인증서에 SubjectKeyIdentifier를 포함하도록 SHOULD로 권고. 인증서 체인 검증 시 발급자 추적에 사용됨.
- **mitmproxy 대비**: mitmproxy는 SubjectKeyIdentifier를 포함
- **수정**: rcgen의 SubjectKeyIdentifier 지원 확인 후 추가
- **위험도**: 중간 | **작업량**: 소 | **난이도**: 낮음

### 3.2 Leaf 인증서에 AuthorityKeyIdentifier 확장 추가

- **파일**: `crab-mitm/src/ca.rs:169-181`
- **현재 상태**: 리프 인증서에 AuthorityKeyIdentifier가 없음
- **문제**: RFC 5280 §4.2.1.1에서 CA가 발급한 인증서에 AuthorityKeyIdentifier를 포함하도록 MUST로 규정.
- **수정**: rcgen의 `authority_key_identifier` 관련 설정 활용
- **위험도**: 중간 | **작업량**: 소 | **난이도**: 낮음

### 3.3 CA 키 알고리즘 선택 옵션 제공

- **파일**: `crab-mitm/src/ca.rs:21`
- **현재 상태**: `rcgen::KeyPair::generate()` — 항상 ECDSA P-256만 사용
- **문제**: 레거시 클라이언트(구형 Android, 구형 Java 등)에서 ECDSA 인증서를 인식하지 못할 수 있음. 사용자에게 키 알고리즘 선택권이 없음.
- **수정 방향**:
  - `generate_ca_to_files` 에 키 알고리즘 파라미터 추가
  - 지원 알고리즘: ECDSA P-256 (기본값), RSA 2048, RSA 4096
  - FFI에 `crab_ca_generate_with_algorithm()` 추가
  - RSA 선택 시 leaf 인증서에 `KeyEncipherment` 자동 포함
- **참고**: ECDSA P-256이 현대적이고 성능이 우수하므로 기본값으로 유지하되, 레거시 호환성이 필요한 사용자를 위한 옵션
- **위험도**: 낮음 | **작업량**: 중 | **난이도**: 중

---

## 4. 프록시 엔진 개선 (P1)

### 4.1 업스트림 인증서 SAN 스니핑 (선택적)

- **파일**: `crab-mitm/src/ca.rs:166-199`, `proxy.rs:563-613`
- **현재 상태**: CONNECT 호스트명 하나만으로 리프 인증서 생성
  ```rust
  let mut leaf_params = rcgen::CertificateParams::new([host.to_string()])
  ```
- **mitmproxy 방식**: CONNECT 수신 후 업스트림에 먼저 TLS 연결 → 서버 인증서의 CN+SAN 추출 → 동일한 SAN으로 위조 인증서 생성
- **CrabProxy 현재 접근법의 장단점**:
  - 장점: 단순, 빠름 (업스트림 연결 불필요), 대부분의 개발 환경에서 충분
  - 단점: CDN, 로드밸런서, 멀티도메인 인증서 환경에서 인증서 불일치 가능
- **TL 판단**: 즉각 구현보다는 설정 옵션(opt-in)으로 제공 권장. 기본값은 현재 방식 유지.
- **수정 방향**:
  - `server_config_for_host(host: &str, upstream_sans: Option<Vec<String>>)` 시그니처 확장
  - `InspectConfig`에 `sniff_upstream_cert: bool` 옵션 추가
  - 활성화 시 업스트림 TLS 연결로 SAN 목록 수집 후 리프 인증서에 반영
- **위험도**: 낮음 | **작업량**: 대 | **난이도**: 중

### 4.2 env 파싱 유틸 통합

- **파일**: `proxy.rs:516-529`, `inspect.rs:351-363`
- **현재 상태**: `parse_env_bool_default_false`(proxy.rs)와 `parse_env_bool_default_true`(inspect.rs)가 거의 동일한 로직으로 중복 존재
- **수정**: 공통 유틸 함수로 추출
  ```rust
  // 예: lib.rs 또는 config.rs에 통합
  pub fn parse_env_bool(raw: Option<&str>, default: bool) -> bool { ... }
  ```
- **위험도**: 없음 | **작업량**: 소 | **난이도**: 낮음

---

## 5. UI/UX 개선 — Quick Wins (P0)

> 적은 작업량으로 즉시 사용자 경험을 개선할 수 있는 항목.

### 5.1 상태코드 색상 체계 도입

- **파일**: `CrabProxyMacApp/Sources/CrabProxyMacApp/CrabTheme.swift`, `ContentView.swift:538-540`
- **현재 상태**: 모든 상태코드가 `CrabTheme.secondaryTint` 단일 색상으로 표시
- **Proxyman 대비**: 1xx(회색), 2xx(초록), 3xx(파란), 4xx(노란), 5xx(빨간) 체계적 구분
- **수정**: `CrabTheme`에 상태코드별 색상 함수 추가
  ```swift
  static func statusCodeColor(for code: String?, scheme: ColorScheme) -> Color {
      guard let code, let num = Int(code) else {
          return secondaryText(for: scheme)
      }
      switch num {
      case 100..<200: return .gray
      case 200..<300: return .green
      case 300..<400: return .blue
      case 400..<500: return warningTint(for: scheme)
      case 500..<600: return destructiveTint(for: scheme)
      default: return secondaryText(for: scheme)
      }
  }
  ```
- **작업량**: 소 | **난이도**: 낮음

### 5.2 상태코드 퀵 필터

- **파일**: `ContentView.swift` transactionsPanel, `ProxyViewModel.swift`
- **현재 상태**: 단일 텍스트 필터(`visibleURLFilter`)만 존재
- **수정**: 상태코드 카테고리별 필터 칩 추가 (1xx, 2xx, 3xx, 4xx, 5xx)
  ```swift
  // ProxyViewModel에 추가
  @Published var statusCodeFilter: Set<StatusCodeCategory> = []

  enum StatusCodeCategory: String, CaseIterable {
      case info = "1xx", success = "2xx", redirect = "3xx"
      case clientError = "4xx", serverError = "5xx"
  }
  ```
- **작업량**: 중 | **난이도**: 낮음

### 5.3 키보드 단축키 기본 세트

- **파일**: `ContentView.swift`, `CrabProxyMacApp.swift`
- **현재 상태**: 키보드 단축키 없음
- **수정**: 핵심 액션에 `.keyboardShortcut` 추가
  - `Cmd+K`: 필터 필드 포커스
  - `Cmd+Shift+K`: 로그 클리어
  - `Cmd+R`: 프록시 시작/중지 토글
  - `Cmd+,`: 설정 화면
- **작업량**: 소 | **난이도**: 낮음

---

## 6. UI/UX 개선 — 구조 개선 (P1)

### 6.1 사이드바 도메인 그룹핑 (3-Panel 레이아웃)

- **파일**: `ContentView.swift:206-224`
- **현재 상태**: 2-panel `HSplitView` (트래픽 목록 + 상세)
- **Proxyman 대비**: 3-panel (도메인 사이드바 + 요청 목록 + 상세)
- **TL 판단**: 가장 큰 UX 개선이 될 수 있으나, 현재의 미니멀한 2-panel 디자인도 장점이 있음. `NavigationSplitView`로 전환하되, 사이드바를 토글 가능하게 구현하여 양쪽 장점 모두 확보.
- **수정 방향**:
  ```swift
  NavigationSplitView(columnVisibility: $sidebarVisibility) {
      DomainSidebarView(domains: model.groupedByDomain, ...)
  } content: {
      TrafficListView(entries: model.filteredLogsForSelectedDomain, ...)
  } detail: {
      RequestDetailView(entry: model.selectedLog)
  }
  ```
- **ProxyViewModel에 추가할 computed property**:
  ```swift
  var groupedByDomain: [DomainGroup] {
      Dictionary(grouping: filteredLogs) { entry in
          URLComponents(string: entry.url)?.host ?? "Unknown"
      }
      .map { DomainGroup(domain: $0.key, entries: $0.value) }
      .sorted { $0.entries.count > $1.entries.count }
  }
  ```
- **작업량**: 대 | **난이도**: 중

### 6.2 Request/Response 분리 상세 뷰

- **파일**: `ContentView.swift:312-353`
- **현재 상태**: Summary/Headers/Body 3탭, Headers와 Body에서 Request/Response가 하나의 스크롤에 혼재
- **Proxyman 대비**: Request/Response가 독립 패널 (수평/수직 전환 가능)
- **수정**: `VSplitView`로 Request/Response 분리
- **작업량**: 중 | **난이도**: 중

### 6.3 Query Parameter 파싱 탭 추가

- **파일**: `ContentView.swift:522-528` (DetailTab enum)
- **현재 상태**: URL 쿼리 파라미터를 별도로 파싱하지 않음
- **수정**: `DetailTab`에 `.query` 케이스 추가, `URLComponents.queryItems`로 키-값 테이블 표시
- **작업량**: 소 | **난이도**: 낮음

---

## 7. UI/UX 개선 — 사용성 (P2)

### 7.1 Duration/Size 정보 표시

- **현재 상태**: 요청 소요 시간과 응답 크기 표시 없음
- **수정 범위**: Rust 백엔드(`proxy.rs`)에서 타이밍 측정 → JSON 로그에 포함 → Swift에서 파싱/표시
- **TL 판단**: 백엔드+프론트엔드 양쪽 변경이 필요하므로 작업량이 큼
- **작업량**: 대 | **난이도**: 중

### 7.2 규칙 편집 모달 시트

- **현재 상태**: Rules가 Settings 화면 내 인라인 편집
- **수정**: Map Local, Status Rewrite 규칙을 `.sheet`로 분리하여 편집 UX 개선
- **작업량**: 중 | **난이도**: 낮음

---

## 8. 장기 로드맵 (P3)

### 8.1 HTTP/3 (QUIC) 지원

- **현재**: HTTP/1 + HTTP/2만 지원 (`proxy.rs:193-194`)
- **mitmproxy 대비**: HTTP/3 지원
- **TL 판단**: QUIC 트래픽이 증가 추세이나, rustls의 QUIC 지원이 아직 실험적. 장기적으로 모니터링하면서 생태계 성숙 시 도입.

### 8.2 CRL/OCSP Stapling

- **현재**: 인증서 폐기 메커니즘 없음
- **mitmproxy 대비**: CRL 생성/배포 지원
- **TL 판단**: 기업 환경에서 유용하나, 개발 프록시에서는 우선순위가 낮음.

### 8.3 Command Palette (Cmd+Shift+P)

- **Proxyman 대비**: 퍼지 검색으로 모든 명령 실행
- **TL 판단**: 프록시 툴의 명령 수가 아직 많지 않아 ROI가 낮음. 기능이 확장된 이후 도입.

### 8.4 Plugin/Addon 시스템

- **mitmproxy 대비**: Python 스크립트 기반 강력한 확장성
- **TL 판단**: 장기적 차별화 포인트. Lua 또는 WASM 기반 플러그인 시스템 검토.

---

## 9. 리팩토링 액션 아이템 요약

### 보안 (Security)

| # | 항목 | 우선순위 | 위험도 | 작업량 | 파일 |
|---|------|---------|--------|--------|------|
| S1 | ECDSA leaf에서 KeyEncipherment 제거 | **P0** | 높음 | 소 | `ca.rs:177-180` |
| S2 | CONNECT 사설 IP 차단 기본값→true | **P0** | 높음 | 소 | `proxy.rs:512-514` |
| S3 | 루트 인증서 로딩 에러 로깅 | **P0** | 중간 | 소 | `transparent.rs:144` |
| S4 | CA cert에 SubjectKeyIdentifier 추가 | P1 | 중간 | 소 | `ca.rs:23-34` |
| S5 | Leaf cert에 AuthorityKeyIdentifier 추가 | P1 | 중간 | 소 | `ca.rs:169-181` |
| S6 | CA 키 알고리즘 선택 옵션 | P1 | 낮음 | 중 | `ca.rs:21`, `ffi.rs` |

### 프록시 엔진 (Engine)

| # | 항목 | 우선순위 | 작업량 | 파일 |
|---|------|---------|--------|------|
| E1 | 업스트림 인증서 SAN 스니핑 (opt-in) | P1 | 대 | `ca.rs:166-199`, `proxy.rs` |
| E2 | env 파싱 유틸 통합 | P1 | 소 | `proxy.rs`, `inspect.rs` |

### UI/UX

| # | 항목 | 우선순위 | 작업량 | 파일 |
|---|------|---------|--------|------|
| U1 | 상태코드 색상 체계 | **P0** | 소 | `CrabTheme.swift`, `ContentView.swift` |
| U2 | 상태코드 퀵 필터 | **P0** | 중 | `ContentView.swift`, `ProxyViewModel.swift` |
| U3 | 키보드 단축키 기본 세트 | **P0** | 소 | `ContentView.swift`, `CrabProxyMacApp.swift` |
| U4 | 3-Panel 도메인 그룹핑 | P1 | 대 | `ContentView.swift`, `ProxyViewModel.swift` |
| U5 | Request/Response 분리 상세 뷰 | P1 | 중 | `ContentView.swift` |
| U6 | Query Parameter 파싱 탭 | P1 | 소 | `ContentView.swift` |
| U7 | Duration/Size 정보 | P2 | 대 | `proxy.rs`, `ProxyLogStore.swift`, `ContentView.swift` |
| U8 | 규칙 편집 모달 시트 | P2 | 중 | `SettingsView.swift` |

### 권장 실행 순서

```
Phase 1 (즉시): S1 → S2 → S3 → U1 → U3
Phase 2 (단기): S4 → S5 → U2 → U6 → E2
Phase 3 (중기): S6 → U4 → U5 → E1
Phase 4 (장기): U7 → U8 → HTTP/3 → CRL → Plugin
```

---

## 10. CrabProxy의 강점 (유지할 부분)

코드 리뷰 결과, CrabProxy가 mitmproxy/Proxyman 대비 우수하거나 유지해야 할 부분:

1. **메모리 안전 아키텍처**: Rust + rustls 사용으로 C/OpenSSL 기반의 메모리 취약점 원천 차단. mitmproxy의 Python+OpenSSL 대비 구조적으로 안전.

2. **Allowlist 기반 보수적 MITM 정책** (`rules.rs:276-283`): allowlist가 비어있으면 MITM을 수행하지 않음. mitmproxy는 기본적으로 모든 HTTPS를 MITM. CrabProxy의 접근이 보안적으로 우월.

3. **ECDSA P-256 기본 사용**: RSA 2048과 동등한 128-bit 보안 강도를 훨씬 작은 키로 달성. TLS 핸드셰이크 성능 우수.

4. **키 파일 퍼미션 보호** (`ca.rs:48-69`): `0o600` 모드로 비밀키 접근 제어. 스풀 파일도 동일 보호 (`inspect.rs:400-418`).

5. **민감 헤더 기본 마스킹** (`inspect.rs:366-373`): Authorization, Cookie, X-API-Key 등이 기본적으로 로그에서 `<redacted>` 처리.

6. **Path traversal 방어** (`ffi.rs:219-282`): map_local 파일 경로에서 `..` 탐지 및 허용 루트 제한.

7. **FFI 안전 계층** (`ffi.rs:83-114`): `ffi_entry!` 매크로로 패닉 캐치, 널 포인터 검증, 상태 검증.

8. **글래스모피즘 디자인**: 반투명 배경 + 애니메이팅 그라데이션은 Proxyman의 전통적 macOS 스타일 대비 독특한 차별화 요소.

9. **모바일 인증서 포털** (`cert_portal.rs`): iOS `.mobileconfig` 자동 생성, Android DER 다운로드, SHA-256 지문 표시. mitmproxy보다 편리한 모바일 셋업 UX.

10. **컨텍스트 메뉴 규칙 생성** (`ContentView.swift:266-278`): 트래픽 목록에서 우클릭으로 Allowlist/Map Local 규칙 자동 생성.

---

## 11. 부록: mitmproxy vs CrabProxy 기술 비교

### 암호화 알고리즘 비교

| 항목 | mitmproxy | CrabProxy | 비고 |
|------|-----------|-----------|------|
| **CA 키** | RSA 2048 | ECDSA P-256 | CrabProxy가 현대적 |
| **Leaf 키** | RSA 2048 | ECDSA P-256 | 동등 보안, 작은 키 |
| **서명 해시** | SHA-256 | SHA-256 | 동일 |
| **TLS 구현** | OpenSSL | rustls | CrabProxy가 메모리 안전 |
| **업스트림 스니핑** | O (CN+SAN 복제) | X (호스트명만) | mitmproxy가 호환성 우수 |
| **인증서 캐시** | 없음 (매번 생성) | LRU 2048개, TTL 6h | CrabProxy가 성능 우수 |

### TLS 인터셉션 방식 비교

```
mitmproxy:
  Client ─CONNECT→ [proxy] ─TLS→ Server (인증서 스니핑)
                             ←cert─ Server
         ←fake cert (CN/SAN 복제)─
         ─TLS handshake→
         ─HTTP→ [proxy] ─HTTP→ Server

CrabProxy:
  Client ─CONNECT→ [proxy]
         ←200 OK─
         ─TLS(SNI)→ [proxy] (호스트명으로 즉시 인증서 생성, 업스트림 연결 불필요)
         ←fake cert─
         ─HTTP→ [proxy] ─HTTP→ Server
```

### MITM 정책 비교

| 항목 | mitmproxy | CrabProxy |
|------|-----------|-----------|
| **기본 정책** | 모든 HTTPS MITM | MITM 비활성화 |
| **제어 방식** | ignore_hosts (제외 목록) | allowlist (허용 목록) |
| **보안 관점** | 편의성 우선 | 보안 우선 ✓ |

### 프록시 모드 비교

| 모드 | mitmproxy | CrabProxy |
|------|-----------|-----------|
| Forward (Explicit) | ✓ | ✓ |
| Transparent | ✓ | ✓ |
| Reverse | ✓ | ✗ |
| SOCKS5 | ✓ | ✗ |
| WireGuard | ✓ | ✗ |
| HTTP/3 (QUIC) | ✓ | ✗ |

---

> **이 문서는 CrabProxy 리팩토링 팀(TL + mitmproxy 분석가 + UI/UX 전문가)이 협업하여 작성했습니다.**
> **보안을 최우선 원칙으로 하여, 모든 제안 사항은 비판적 검토를 거쳤습니다.**
