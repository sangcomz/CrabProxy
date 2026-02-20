# Crab Proxy

언어: [English](README.md) | **한국어**

Crab Proxy는 `crab-mitm` Rust 엔진 기반의 macOS 트래픽 디버깅 앱입니다.
macOS 앱/API 트래픽과 동일 LAN의 모바일(iOS/Android) 트래픽 분석을 목표로 합니다.

## 주요 기능

- HTTP/HTTPS 프록시 트래픽 실시간 수집
- 사이드바 스코프: `All Traffic`, `Pinned`, `Apps`, `Domains`
- 앱 기준 트래픽 묶음(가능한 경우 앱 이름/아이콘 자동 식별)
- 독립 스코프 동작:
  - `Domains` 클릭 시 해당 도메인 트래픽
  - `Apps` 클릭 시 해당 앱 트래픽
- URL 포함 검색 (`Show only traffic URLs containing...`)
- 상태 코드 필터 (`All`, `1xx`, `2xx`, `3xx`, `4xx`, `5xx`)
- 상세 탭: `Summary`, `Headers`, `Body`, `Query`
- 컨텍스트 액션: `Replay`, `Add to Allowlist`, `Add to Map Local`, `Add to Rewrite`
- Rules UI: `Allowlist`, `Map Local`(file/text), `Map Remote`, `Status Rewrite`
- 모바일 설정:
  - LAN 프록시 엔드포인트 안내
  - 허용 디바이스 IP 목록 + 승인 팝업
  - 인증서 포털 (`http://crab-proxy.local/`)
- 고급 설정:
  - `Inspect Bodies`
  - 네트워크 스로틀링(프리셋/커스텀, 선택 호스트만 적용 가능)
  - Transparent Proxy
- 테마: `System`, `Light`, `Dark`

## 프로젝트 구조

- `CrabProxyMacApp`: SwiftUI macOS 앱
- `crab-mitm`: Rust 프록시 엔진 + C FFI

## 개발 빌드/실행

1. Rust 정적 라이브러리 빌드

```bash
cargo build --manifest-path crab-mitm/Cargo.toml
```

2. macOS 앱 실행

```bash
swift run --package-path CrabProxyMacApp CrabProxyMacApp
```

선택: 릴리즈 빌드

```bash
cargo build --release --manifest-path crab-mitm/Cargo.toml
swift build -c release --package-path CrabProxyMacApp
```

## 빠른 시작

1. 앱 실행 후 `Start`
2. (선택) `macOS Proxy` 활성화
3. HTTPS 복호화 필요 시:
   - `Settings > General`에서 CA 설치/신뢰
   - `Settings > Rules > Allowlist (SSL Proxying)`에 대상 추가
4. 왼쪽 사이드바의 `Apps` 또는 `Domains`로 트래픽 스코프 선택
5. 모바일은 `Settings > Mobile`에서 표시된 엔드포인트로 프록시 설정
6. 모바일 브라우저에서 `http://crab-proxy.local/` 접속 후 CA/프로파일 설치

## MCP 사용 방법 (HTTP / Stdio)

Crab Proxy MCP는 두 가지 방식으로 사용할 수 있습니다.

### 1) HTTP 방식 (앱에서 켜는 방식, 권장)

앱이 MCP 서버를 띄우고 `Endpoint` + `Token`을 외부 IDE/AI 클라이언트에 연결하는 방식입니다.

1. `Settings > Advanced > MCP (HTTP)`를 켭니다.
2. 아래 값을 복사합니다.
   - `Endpoint` (예: `http://127.0.0.1:3847/mcp`)
   - `Token` (`~/Library/Application Support/CrabProxy/run/mcp.token` 기반)
3. MCP 클라이언트에서 Streamable HTTP로 설정합니다.
   - URL = `Endpoint`
   - `Authorization: Bearer <Token>`

### 2) Stdio 방식 (기존 방식)

IDE/AI 클라이언트가 `crab-mcp` 프로세스를 직접 실행하는 방식입니다.

실행 명령:

```bash
cargo run --manifest-path crab-mitm/Cargo.toml --bin crab-mcp -- --transport stdio
```

빌드 후 실행:

```bash
./crab-mitm/target/release/crab-mcp --transport stdio
```

이 방식은 HTTP 엔드포인트 없이, MCP 클라이언트의 command/args 실행 설정으로 연결합니다.

## HTTPS MITM 동작

- HTTPS MITM은 CA가 필요합니다.
- HTTPS MITM 대상은 Allowlist 규칙이 필요합니다.
- CA 또는 Allowlist가 없으면 HTTPS는 터널링만 수행됩니다(복호화 안 됨).

## 참고

- 기본 프록시 포트: `8888`
- 내부 CA 경로:
  `~/Library/Application Support/CrabProxyMacApp/ca/`
- 디버깅 목적 도구이므로 신뢰할 수 없는 네트워크에 오픈 프록시로 노출하지 마세요.
