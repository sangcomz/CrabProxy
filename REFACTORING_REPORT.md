# CrabProxy 리팩토링 보고서

> 분석일: 2026-02-09
> 분석 대상: CrabProxy (Rust MITM 프록시 엔진 + Swift macOS GUI 앱)
> 분석 관점: 아키텍처, 보안, 성능

---

## 진행 현황

### 처리된 목록

- [x] `S-01` CA 개인키 파일 권한 강화 (`0600`)
- [x] `S-02` FFI LogCallback 안전성 강화 (`unsafe Send/Sync` 제거 + 콜백 수명 계약 명시)
- [x] `S-03` Swift 콜백 포인터 수명 문제 수정 (`passRetained` 기반 콜백 컨텍스트 + 명시적 해제)
- [x] `S-07` Spool 디렉토리/파일 권한 강화 (`0700` / `0600`)
- [x] `P-01` `filteredLogs` 캐시형 `@Published` 전환 (로그/필터 변경 시 재계산)
- [x] `A-01` `proxy.rs` 모듈 분리 (`proxy/inspect.rs`, `proxy/cert_portal.rs`, `proxy/response.rs`)
- [x] `A-02` `ContentView.swift` 분리 (`SettingsView.swift`, `Components.swift`, `CrabTheme.swift`)
- [x] `A-03` FFI 보일러플레이트 매크로 추출 (`ffi_entry!`, `ffi_with_handle!`, `ffi_with_stopped_handle!`)
- [x] `A-04` `ProxyViewModel` 책임 분리 (`ProxyLogStore`, `NetworkInterfaceService`, `ProxyRuleManager`)
- [x] `S-04` 클라이언트 응답에서 내부 에러 상세 노출 제거 (`bad gateway` 고정 메시지)
- [x] `S-05` TLS 인증서 캐시 크기 제한 (`LruCache`, 2048 엔트리)
- [x] `S-06` `map_local` 경로 검증(Path Traversal 방어 + 허용 루트 제한)
- [x] `P-02` logs 선형 검색 반복 제거 (`logIndexByID` 인덱스 기반 조회)
- [x] `P-03` `@Published logs` 갱신 배치화 (`appendBatch` + 50ms 배치 flush)
- [x] `P-04` `InspectMeta` 문자열 clone 최적화 (`Arc<str>`)

### 다음 처리 대상 (우선순위별 전체 백로그)

#### Critical

- 없음 (Critical 4개 항목 완료: `S-01`, `S-02`, `S-03`, `P-01`)

#### High

- 없음 (High 10개 항목 완료: `A-01`, `A-02`, `A-03`, `A-04`, `S-04`, `S-05`, `S-06`, `P-02`, `P-03`, `P-04`)

#### Medium

- [ ] `A-05` HTTP 응답 헬퍼 통합
- [ ] `A-06` `Matcher`/`AllowRule` 매칭 로직 통합
- [ ] `A-07` 구조화 로그 포맷(JSON) 도입
- [ ] `A-08` FFI 레이어 테스트 추가
- [ ] `A-09` 에러 코드 동기화 자동화
- [ ] `S-08` 민감 헤더 로그 마스킹
- [ ] `S-09` Mutex poisoning 처리 일관화
- [ ] `S-10` iOS mobileconfig UUID 고유화
- [ ] `S-11` 인증서 포탈에 fingerprint 표시
- [ ] `S-12` CONNECT 터널 SSRF 방어
- [ ] `P-08` async context 내 동기 I/O 제거 (BodyInspector)
- [ ] `P-09` CA Signer 동기 Mutex 병목 완화
- [ ] `P-10` 인증서 캐시 TOCTOU 보완
- [ ] `P-11` 로그 콜백 문자열 변환 최적화
- [ ] `P-12` rules 매칭 시 반복 String 할당 감소
- [ ] `P-13` BodyInspector sample Vec 사전 할당
- [ ] `P-14` 로그 파싱 정규식 비용 최적화
- [ ] `P-15` `resolve_target` URI 재파싱 제거
- [ ] `P-16` `encode_headers_for_log` 할당 최적화
- [ ] `P-17` `map_local` Text 소스 이중 `Bytes` 생성 제거

#### Low

- [ ] `A-10` CrabTheme 중복 제거
- [ ] `A-11` CLI 전용 의존성 feature flag 분리
- [ ] `A-12` `MacSystemProxyService` 프로토콜 추출
- [ ] `S-13` 기본 바인딩 Open Proxy 위험 완화
- [ ] `S-14` leaf 인증서 캐시 만료 처리
- [ ] `S-15` CI에 `cargo audit` 추가
- [ ] `P-18` tokio worker_threads 설정 개선
- [ ] `P-19` HTTP/2 지원 검토

---

## 목차

1. [프로젝트 개요](#1-프로젝트-개요)
2. [아키텍처 리팩토링 제안](#2-아키텍처-리팩토링-제안)
3. [보안 리팩토링 제안](#3-보안-리팩토링-제안)
4. [성능 리팩토링 제안](#4-성능-리팩토링-제안)
5. [우선순위별 종합 정리](#5-우선순위별-종합-정리)
6. [결론 및 로드맵 제안](#6-결론-및-로드맵-제안)

---

## 1. 프로젝트 개요

CrabProxy는 **macOS용 트래픽 검사 및 디버깅 도구**로, 두 가지 주요 컴포넌트로 구성됩니다:

- **Rust 백엔드 (`crab-mitm/`)**: MITM 프록시 엔진. HTTP/HTTPS 트래픽 가로채기, 인증서 관리, 룰 매칭 등을 담당
- **Swift 프론트엔드 (`CrabProxyMacApp/`)**: SwiftUI 기반 macOS 네이티브 앱. 트래픽 시각화, 프록시 제어, 설정 관리

두 레이어는 **C FFI**를 통해 통신하며, Rust 라이브러리를 Swift에서 호출하는 구조입니다.

### 주요 소스 파일 규모

| 파일 | 줄 수 | 역할 |
|------|-------|------|
| `proxy.rs` | 1,305 | 프록시 코어 로직, 바디 인스펙션, 인증서 포탈 |
| `ContentView.swift` | 1,379 | 전체 UI 뷰, 테마, 설정 |
| `ProxyViewModel.swift` | 996 | 앱 상태 관리, 로그 파싱, 룰 동기화 |
| `ffi.rs` | 762 | FFI 인터페이스 |

---

## 2. 아키텍처 리팩토링 제안

### 2.1 대형 파일 분리 (SRP 위반)

#### `proxy.rs` (1,305줄) → 4개 모듈로 분리

현재 `proxy.rs`에 프록시 서버, 바디 인스펙션, 인증서 포탈, HTTP 유틸리티 등 4가지 책임이 혼재되어 있습니다.

| 분리 대상 | 현재 위치 | 제안 모듈 |
|-----------|-----------|-----------|
| 인증서 포탈 (HTML/mobileconfig 생성) | `proxy.rs:825-1081` | `cert_portal.rs` |
| 바디 인스펙션 (BodyInspector, InspectableBody) | `proxy.rs:48-282` | `inspect.rs` |
| HTTP 응답 헬퍼 (text/html/bytes_response) | `proxy.rs:1093-1195` | `response.rs` |
| 프록시 서버 코어 로직 | 나머지 | `proxy.rs` (유지) |

#### `ContentView.swift` (1,379줄) → 4개 파일로 분리

| 분리 대상 | 현재 위치 | 제안 파일 |
|-----------|-----------|-----------|
| 테마 정의 (CrabTheme) | `ContentView.swift:1146-1367` | `CrabTheme.swift` |
| 설정 뷰 (SettingsView 등) | `ContentView.swift:376-797` | `SettingsView.swift` |
| 재사용 컴포넌트 (GlassCard, ActionButton 등) | `ContentView.swift:836-1144` | `Components/` 디렉토리 |
| 메인 뷰 | 나머지 | `ContentView.swift` (유지) |

#### `ProxyViewModel.swift` (996줄) 책임 분리

현재 7가지 이상의 책임을 담당하고 있어 SRP를 심각하게 위반합니다:

- 프록시 엔진 관리 → `ProxyEngineManager`
- 로그 파싱/저장 → `LogParser` / `LogStore`
- 룰 동기화 → `RuleManager`
- 네트워크 인터페이스 스캔 → `NetworkInterfaceService`
- CA 관리 → (기존 `RustProxyEngine`에 위임)
- 시스템 프록시 관리 → (기존 `MacSystemProxyService`에 위임)
- UI 상태 관리 → `ProxyViewModel` (유지, 축소)

### 2.2 FFI 보일러플레이트 제거

**파일**: `ffi.rs` 전반

모든 FFI 함수에서 동일한 패턴이 반복됩니다:

```rust
// 10개 이상의 함수에서 반복되는 패턴
catch_unwind → handle_ref → ensure_not_running → lock → 작업 → CrabResult
```

**개선 방안**: Rust 매크로로 추출하여 보일러플레이트 제거

```rust
macro_rules! ffi_fn {
    ($name:ident, $handle:ident, $body:expr) => {
        #[unsafe(no_mangle)]
        pub extern "C" fn $name(handle: *mut CrabProxyHandle) -> CrabResult {
            std::panic::catch_unwind(|| {
                let $handle = handle_ref(handle)?;
                ensure_not_running($handle)?;
                $body
            })
            .unwrap_or_else(|_| CrabResult::err(ERR_PANIC, "panic"))
        }
    };
}
```

### 2.3 에러 코드 동기화 위험

**파일**: `ffi.rs:14-19`, `crab_mitm.h:9-16`

Rust와 C 헤더에서 에러 코드 상수가 각각 독립적으로 정의되어 있어 동기화가 깨질 위험이 있습니다.

**개선 방안**: `cbindgen`을 도입하여 Rust 코드에서 C 헤더를 자동 생성하거나, 빌드 시 검증 스크립트 추가

### 2.4 코드 중복 제거

| 중복 항목 | 위치 | 개선 방안 |
|-----------|------|-----------|
| HTTP 응답 함수 3개 (text/html/bytes) | `proxy.rs:1093-1139` | content_type 매개변수를 받는 단일 함수로 통합 |
| CA 없음 응답 3회 반복 | `proxy.rs:861-868, 882-889, 903-910` | 헬퍼 함수로 추출 |
| CrabTheme switch 패턴 20+ 반복 | `ContentView.swift:1146-1367` | 딕셔너리/구조체 기반으로 리팩토링 |
| `Matcher::is_match` / `AllowRule::is_match` 유사 로직 | `rules.rs:47-80, 106-118` | 공통 매칭 로직을 `Matcher`에 통합, `AllowRule`이 이를 재사용 |

### 2.5 테스트 커버리지 부족

| 영역 | 현재 상태 | 위험도 |
|------|-----------|--------|
| `ffi.rs` (762줄) | 테스트 0개 | **높음** - FFI 경계는 가장 위험한 레이어 |
| Swift 전체 | 테스트 0개 | **높음** |
| `ca.rs` (CA 생성/서명) | 테스트 0개 | **중간** |
| 통합 테스트 | 없음 | **중간** |

**개선 방안**:
- `MacSystemProxyService`를 프로토콜로 추출하여 모킹 가능하게 변경
- `RustProxyEngine`을 프로토콜로 추출하여 `ProxyViewModel` 테스트 가능하게 변경
- FFI 레이어에 대한 유닛 테스트 추가

### 2.6 OCP 위반 - 룰 타입 확장 비용

새로운 룰 타입을 추가하려면 최소 **6개 파일**을 수정해야 합니다:

`rules.rs` → `config.rs` → `ffi.rs` → `crab_mitm.h` → `RustProxyEngine.swift` → `ProxyViewModel.swift` → `ContentView.swift`

**개선 방안**: 룰 레지스트리 패턴 도입 또는 trait object 기반 확장 가능한 구조로 변경

---

## 3. 보안 리팩토링 제안

### 3.1 Critical (즉시 수정 필요)

#### S-01. CA 개인키 파일 권한 미설정

- **파일**: `ca.rs:36-39`
- **문제**: `std::fs::write()`로 CA 개인키를 저장할 때 파일 권한을 설정하지 않습니다. 기본 umask에 따라 다른 사용자가 읽을 수 있는 0644 권한으로 생성될 수 있습니다.
- **위험**: CA 개인키가 유출되면 공격자가 임의 호스트에 대한 인증서를 생성하여 MITM 공격 수행 가능
- **수정 방안**:
  ```rust
  use std::os::unix::fs::OpenOptionsExt;
  std::fs::OpenOptions::new()
      .write(true)
      .create(true)
      .mode(0o600)
      .open(&key_path)?
      .write_all(key_pem.as_bytes())?;
  ```

#### S-02. FFI LogCallback의 unsafe Send/Sync

- **파일**: `ffi.rs:47-48`
- **문제**: `LogCallback`이 `*mut c_void`를 포함하면서 수동으로 `unsafe impl Send/Sync`을 선언. thread-safe하지 않은 포인터 전달 시 data race 가능
- **수정 방안**: 호출자의 책임을 명확히 문서화하고, `user_data`의 수명 보장에 대한 safety contract를 주석으로 명시

#### S-03. RustProxyEngine의 Unmanaged 포인터 수명 문제

- **파일**: `RustProxyEngine.swift:52, 227`
- **문제**: `Unmanaged.passUnretained(self)`로 ARC 카운트를 증가시키지 않아, `deinit` 후 콜백에서 dangling pointer 접근 가능. 멀티스레드 환경에서 race condition 존재
- **수정 방안**: `passRetained`를 사용하고 프록시 중지 시 명시적으로 `takeRetainedValue()`로 해제, 또는 Rust 측에서 콜백 해제 시 동기화 보장

### 3.2 High (빠른 시일 내 수정)

#### S-04. 에러 메시지를 통한 내부 정보 노출

- **파일**: `proxy.rs:394`
- **문제**: `text_response(StatusCode::BAD_GATEWAY, format!("bad gateway: {err}\n"))` — 내부 에러를 클라이언트에 그대로 반환
- **수정 방안**: 클라이언트에는 일반 에러 메시지만 반환, 상세 에러는 로그에만 기록

#### S-05. TLS 인증서 캐시 무한 증가 (DoS)

- **파일**: `ca.rs:48, 93-103`
- **문제**: 인증서 캐시에 만료나 크기 제한이 없어, 장시간 운영 시 메모리 무한 증가
- **수정 방안**: LRU 캐시 도입 (예: `lru` crate) 또는 최대 캐시 크기 제한

#### S-06. map_local 파일 경로 검증 부재 (Path Traversal)

- **파일**: `proxy.rs:716`, `ffi.rs:504`
- **문제**: `MapSource::File(path)`에 전달된 경로에 대한 검증 없음. `../../etc/passwd` 같은 경로로 임의 파일 노출 가능
- **수정 방안**: 경로 정규화 후 허용 디렉토리 내 파일인지 검증

#### S-07. Spool 파일 권한 미설정

- **파일**: `proxy.rs:1161-1174`
- **문제**: 프록시 트래픽(쿠키, 인증 토큰 포함 가능)이 기본 권한으로 저장됨
- **수정 방안**: spool 파일/디렉토리에 0600/0700 권한 설정

### 3.3 Medium (계획적 수정)

#### S-08. 민감 정보의 로그 기록

- **파일**: `proxy.rs:253, 560-562, 624-626`
- **문제**: Authorization, Cookie 등 민감 헤더와 바디 샘플이 로그에 기록됨
- **수정 방안**: 민감 헤더 마스킹 옵션 제공

#### S-09. Mutex lock poisoning 처리 불일치

- **파일**: `ca.rs:123` (panic) vs `ffi.rs` 전반 (에러 반환)
- **수정 방안**: 일관된 에러 반환 패턴 적용

#### S-10. iOS mobileconfig UUID 하드코딩

- **파일**: `proxy.rs:1057-1058, 1074-1075`
- **문제**: 모든 인스턴스가 동일 UUID 사용 → 프로파일 충돌 가능
- **수정 방안**: CA 인증서 fingerprint에서 UUID 파생

#### S-11. 인증서 포탈 HTTP 전용 (fingerprint 미표시)

- **파일**: `proxy.rs:830`
- **수정 방안**: 포탈 페이지에 인증서 fingerprint 표시하여 수동 확인 가능하게

#### S-12. CONNECT 터널 SSRF 위험

- **파일**: `proxy.rs:456-465`
- **문제**: 호스트/포트 검증 없이 내부 네트워크로의 CONNECT 요청 중계 가능
- **수정 방안**: 내부 네트워크 IP 대역 차단 옵션 제공

### 3.4 Low (장기적 개선)

#### S-13. 0.0.0.0 기본 바인딩 (Open Proxy 위험)

- **파일**: `ProxyViewModel.swift:131`
- **수정 방안**: 기본값을 `127.0.0.1:8888`로 변경, 전체 인터페이스 바인딩 시 경고 표시

#### S-14. leaf 인증서 캐시 만료 처리 없음

- **파일**: `ca.rs:111`
- **수정 방안**: 인증서 캐시에 TTL 추가하여 만료 시 재생성

#### S-15. 의존성 보안 감사 미적용

- **파일**: `Cargo.toml`
- **수정 방안**: `Cargo.lock`을 버전 관리에 포함하고, CI에 `cargo audit` 추가

---

## 4. 성능 리팩토링 제안

### 4.1 Critical (즉시 수정 필요)

#### P-01. filteredLogs 매번 정렬 + 필터링 수행

- **파일**: `ProxyViewModel.swift:177-191`
- **문제**: `filteredLogs`가 computed property로, SwiftUI body 재평가 시마다 전체 logs를 정렬 O(n log n) + 필터링 O(n). maxLogEntries=800에서 UI 업데이트가 빈번하면 심각한 성능 저하
- **수정 방안**:
  - 로그를 삽입 시 정렬된 순서로 유지
  - `filteredLogs`를 캐시된 `@Published` 프로퍼티로 변경
  - 필터 조건 변경 시에만 재계산

### 4.2 High (빠른 시일 내 수정)

#### P-02. logs 배열 내 선형 검색 반복

- **파일**: `ProxyViewModel.swift:729, 852`
- **문제**: `logs.contains(where:)`, `logs.firstIndex(where:)` — O(n) 선형 검색이 빈번하게 호출됨
- **수정 방안**: `[String: Int]` ID→index 매핑 Dictionary 유지

#### P-03. @Published logs 빈번한 UI 갱신

- **파일**: `ProxyViewModel.swift:719, 723-726, 853-855`
- **문제**: `logs.append()`, `logs.removeFirst()`, `logs[index] = entry` 각각이 `objectWillChange`를 트리거. 한 번의 `appendLog`에 최대 3회 UI 업데이트 발생
- **수정 방안**:
  - 배치 업데이트 패턴 도입
  - throttle/debounce 적용 (예: 100ms 간격으로 UI 업데이트 통합)

#### P-04. InspectMeta 문자열 반복 clone

- **파일**: `proxy.rs:589-595, 630-636`
- **문제**: 모든 allowed 요청에서 `request_url.clone()`, `method.clone()` 발생
- **수정 방안**: `Arc<str>` 또는 참조 기반으로 변경

#### P-05. 인증서 캐시 무한 증가

- **파일**: `ca.rs:48`
- **문제**: 방문한 모든 호스트의 인증서가 영구 보관됨 (보안 S-05와 동일)
- **수정 방안**: LRU 캐시 도입

#### P-06. FFI 핸들의 과도한 Mutex 사용

- **파일**: `ffi.rs:22-29`
- **문제**: `CrabProxyHandle` 내 6개의 `Mutex`. `crab_proxy_start()`에서 4개를 순차 lock/unlock
- **수정 방안**: 단일 `RwLock<Config>` 구조체로 통합

#### P-07. Unmanaged dangling reference 위험 (보안 S-03 겸)

- **파일**: `RustProxyEngine.swift:52`
- **수정 방안**: `passRetained` 사용 + 명시적 해제 패턴

### 4.3 Medium (계획적 수정)

#### P-08. BodyInspector 동기적 파일 I/O in async context

- **파일**: `proxy.rs:222-227`
- **문제**: `std::fs::File::write_all()`이 tokio async 워커 스레드를 블로킹
- **수정 방안**: `tokio::fs::File` 사용 또는 `spawn_blocking` 내에서 처리

#### P-09. CA Signer의 std::sync::Mutex in async context

- **파일**: `ca.rs:122-127`
- **문제**: 인증서 생성(CPU 집약적)이 동기적 Mutex로 직렬화, async context에서 블로킹
- **수정 방안**: `tokio::sync::Mutex` 사용 또는 `spawn_blocking`으로 래핑

#### P-10. RwLock 캐시 TOCTOU (중복 인증서 생성)

- **파일**: `ca.rs:93-102`
- **문제**: 읽기 잠금 해제 → 쓰기 잠금 획득 사이에 동일 호스트 인증서 중복 생성 가능
- **수정 방안**: write lock 내에서 캐시 재확인

#### P-11. 로그 콜백 3중 문자열 변환

- **파일**: `ffi.rs:189`, `RustProxyEngine.swift:228`
- **문제**: `buf(바이트)` → `String` → `CString` → Swift `String` (매 로그 라인)
- **수정 방안**: 변환 횟수 최소화 또는 버퍼링

#### P-12. rules 매칭 시 반복 String 할당

- **파일**: `rules.rs:56-57, 107, 116`
- **문제**: 매 요청마다 `format!("{scheme}://{authority}{path_and_query}")`로 전체 URL 문자열 생성
- **수정 방안**: slice 비교로 변경하거나 한 번 할당한 것을 재사용

#### P-13. BodyInspector sample Vec 미리 할당 없음

- **파일**: `proxy.rs:164`
- **수정 방안**: `Vec::with_capacity(cfg.sample_bytes.min(상한))` 사용

#### P-14. NSRegularExpression 다수 실행

- **파일**: `ProxyViewModel.swift:929-939`
- **문제**: 매 로그 라인마다 9개의 정규식 실행
- **수정 방안**: 구조화된 로그 포맷(JSON) 도입으로 정규식 파싱 제거, 또는 간단한 문자열 파싱으로 대체

#### P-15. resolve_target URI 재파싱

- **파일**: `proxy.rs:681-683, 700-701`
- **문제**: 이미 파싱된 URI에서 `format!` → `.parse()`로 다시 재구성 (hot path)
- **수정 방안**: 파싱된 컴포넌트에서 직접 URI 구성

#### P-16. encode_headers_for_log String 할당

- **파일**: `proxy.rs:1186-1195`
- **수정 방안**: `String::with_capacity()` 사용하여 재할당 최소화

#### P-17. map_local Text 소스 이중 Bytes 생성

- **파일**: `proxy.rs:737-738`
- **수정 방안**: `text` 소유권을 직접 `Bytes::from(text)`로 넘기고 len 미리 계산

### 4.4 Low (장기적 개선)

#### P-18. tokio worker_threads 고정값 2

- **파일**: `ffi.rs:244-246`
- **수정 방안**: CPU 코어 수에 비례하게 설정하거나 설정 가능하도록 변경

#### P-19. HTTP/1.1만 지원

- **파일**: `proxy.rs:346-353`, `ca.rs:136`
- **수정 방안**: HTTP/2 지원 추가 검토 (확장 시)

---

## 5. 우선순위별 종합 정리

### Critical (즉시 수정)

| ID | 분류 | 이슈 | 파일 |
|----|------|------|------|
| S-01 | 보안 | CA 개인키 파일 권한 미설정 | `ca.rs:36-39` |
| S-02 | 보안 | FFI LogCallback unsafe Send/Sync | `ffi.rs:47-48` |
| S-03 | 보안/성능 | Unmanaged 포인터 수명/race condition | `RustProxyEngine.swift:52,227` |
| P-01 | 성능 | filteredLogs 매번 정렬+필터 (O(n log n)) | `ProxyViewModel.swift:177-191` |

### High (빠른 시일 내 수정)

| ID | 분류 | 이슈 | 파일 |
|----|------|------|------|
| A-01 | 아키텍처 | `proxy.rs` 분리 (1,305줄, 4가지 책임) | `proxy.rs` |
| A-02 | 아키텍처 | `ContentView.swift` 분리 (1,379줄) | `ContentView.swift` |
| A-03 | 아키텍처 | FFI 보일러플레이트 매크로 추출 | `ffi.rs` |
| A-04 | 아키텍처 | `ProxyViewModel` 책임 분리 (996줄, 7+ 책임) | `ProxyViewModel.swift` |
| S-04 | 보안 | 에러 메시지 내부 정보 노출 | `proxy.rs:394` |
| S-05 | 보안/성능 | TLS 인증서 캐시 무한 증가 | `ca.rs:48,93-103` |
| S-06 | 보안 | map_local Path Traversal 위험 | `proxy.rs:716`, `ffi.rs:504` |
| S-07 | 보안 | Spool 파일 권한 미설정 | `proxy.rs:1161-1174` |
| P-02 | 성능 | logs 배열 선형 검색 반복 O(n) | `ProxyViewModel.swift:729,852` |
| P-03 | 성능 | @Published logs 빈번한 UI 갱신 | `ProxyViewModel.swift:719-726` |
| P-04 | 성능 | InspectMeta 문자열 반복 clone | `proxy.rs:589-636` |

### Medium (계획적 수정)

| ID | 분류 | 이슈 | 파일 |
|----|------|------|------|
| A-05 | 아키텍처 | HTTP 응답 헬퍼 함수 통합 | `proxy.rs:1093-1139` |
| A-06 | 아키텍처 | Matcher/AllowRule 매칭 로직 통합 | `rules.rs:47-118` |
| A-07 | 아키텍처 | 구조화된 로그 포맷(JSON) 도입 | `proxy.rs`, `ProxyViewModel.swift` |
| A-08 | 아키텍처 | FFI 레이어 테스트 추가 | `ffi.rs` |
| A-09 | 아키텍처 | 에러 코드 상수 동기화 자동화 | `ffi.rs`, `crab_mitm.h` |
| S-08 | 보안 | 민감 헤더 로그 마스킹 | `proxy.rs:253,560,624` |
| S-09 | 보안 | Mutex lock poisoning 처리 일관화 | `ca.rs:123` |
| S-10 | 보안 | iOS mobileconfig UUID 고유화 | `proxy.rs:1057,1074` |
| S-11 | 보안 | 인증서 포탈 fingerprint 표시 | `proxy.rs:830` |
| S-12 | 보안 | CONNECT 터널 SSRF 방어 | `proxy.rs:456-465` |
| P-08 | 성능 | BodyInspector 동기 I/O in async context | `proxy.rs:222-227` |
| P-09 | 성능 | CA Signer std::sync::Mutex in async | `ca.rs:122-127` |
| P-10 | 성능 | RwLock 캐시 TOCTOU | `ca.rs:93-102` |
| P-11 | 성능 | 로그 콜백 3중 문자열 변환 | `ffi.rs:189` |
| P-12 | 성능 | rules 매칭 시 반복 String 할당 | `rules.rs:56-57,107,116` |
| P-14 | 성능 | NSRegularExpression 9개 매 로그 실행 | `ProxyViewModel.swift:929-939` |
| P-15 | 성능 | resolve_target URI 재파싱 | `proxy.rs:681-701` |

### Low (장기적 개선)

| ID | 분류 | 이슈 | 파일 |
|----|------|------|------|
| A-10 | 아키텍처 | CrabTheme 중복 제거 | `ContentView.swift:1146-1367` |
| A-11 | 아키텍처 | CLI 전용 의존성 feature flag 분리 | `Cargo.toml` |
| A-12 | 아키텍처 | MacSystemProxyService 프로토콜 추출 | `MacSystemProxyService.swift` |
| S-13 | 보안 | 0.0.0.0 기본 바인딩 Open Proxy | `ProxyViewModel.swift:131` |
| S-14 | 보안 | leaf 인증서 캐시 만료 처리 | `ca.rs:111` |
| S-15 | 보안 | cargo audit CI 추가 | `Cargo.toml` |
| P-18 | 성능 | tokio worker_threads 고정 2 | `ffi.rs:244-246` |
| P-19 | 성능 | HTTP/2 지원 | `proxy.rs`, `ca.rs` |

---

## 6. 결론 및 로드맵 제안

### 현재 상태 평가

CrabProxy는 Rust + Swift의 강점을 잘 활용한 프로젝트이며, 기본적인 코드 품질은 양호합니다. 특히:
- Rust의 타입 시스템과 메모리 안전성을 활용
- FFI 경계에서 `catch_unwind`로 패닉 전파 방지
- `rustls` 사용으로 메모리 안전한 TLS 구현
- 셸 인젝션 방지를 위한 `Process` API 사용

그러나 프로젝트 성장에 따라 **대형 파일의 책임 분리**, **보안 강화**, **성능 최적화**가 필요한 시점입니다.

### 제안 로드맵

#### Phase 1: 긴급 보안 수정 (1주)
- S-01: CA 개인키 파일 권한 설정 (0600)
- S-03: Unmanaged 포인터 → passRetained 패턴 변경
- S-07: Spool 파일 권한 설정
- P-01: filteredLogs 캐시된 @Published로 변경

#### Phase 2: 구조 개선 (2-3주)
- A-01: `proxy.rs` → 4개 모듈 분리
- A-02: `ContentView.swift` → 4개 파일 분리
- A-03: FFI 매크로 추출
- S-05/P-05: 인증서 LRU 캐시 도입
- P-02/P-03: logs 배열 성능 최적화

#### Phase 3: 품질 강화 (3-4주)
- A-04: ProxyViewModel 책임 분리
- A-07: 구조화된 로그 포맷(JSON) 도입
- S-06: map_local 경로 검증
- S-08: 민감 헤더 마스킹
- P-08/P-09: async context 내 동기 I/O 제거

#### Phase 4: 장기 개선 (지속적)
- A-08: FFI 레이어 테스트 추가
- A-12: 프로토콜 추출 및 DI 도입
- S-12: SSRF 방어
- S-15: CI에 cargo audit 추가
- P-18/P-19: 런타임 설정 개선 및 HTTP/2 지원

---

### 통계 요약

| 분류 | Critical | High | Medium | Low | 합계 |
|------|----------|------|--------|-----|------|
| 아키텍처 | 0 | 4 | 5 | 3 | **12** |
| 보안 | 3 | 4 | 5 | 3 | **15** |
| 성능 | 1 | 6 | 10 | 2 | **19** |
| **합계** | **4** | **14** | **20** | **8** | **46** |

> ※ 일부 이슈는 보안과 성능에 중복 카운트됨 (예: 인증서 캐시, Unmanaged 포인터)

---

*이 보고서는 아키텍처, 보안, 성능 전문가의 병렬 분석 결과를 종합하여 작성되었습니다.*
