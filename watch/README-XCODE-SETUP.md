# Xcode watchOS 프로젝트 설정 가이드

이 파일은 `watch/` 디렉토리의 미리 준비된 Swift 소스 파일들을 Xcode 프로젝트에 추가하는 단계를 설명합니다.

## 준비된 파일 목록
- `watch/YoutumuWatch Watch App/KeyStore.swift`
- `watch/YoutumuWatch Watch App/EnrollClient.swift`
- `watch/YoutumuWatch Watch App/AACDecoder.swift`
- `watch/YoutumuWatch Watch App/StreamPlayer.swift`
- `watch/YoutumuWatch Watch App/ContentView.swift`

## 설정 단계

### 1. Xcode 프로젝트 생성
- Xcode 열기 → `File` → `New` → `Project`
- **watchOS** 탭 → **App** 선택
- **Product Name**: `YoutumuWatch`
- **Location**: `watch/` (이 README와 같은 디렉토리)
- **Organization Identifier**: 기본값 유지
- **Team**: Personal Team 선택
- **Interface**: SwiftUI
- **Finish** 클릭

프로젝트가 생성되면 Xcode가 기본 `ContentView.swift`를 생성합니다. 이후 단계에서 대체됩니다.

### 2. 서명 및 기능 설정
- 프로젝트 네비게이터에서 **YoutumuWatch** 선택
- **YoutumuWatch Watch App** 타겟 선택
- **Signing & Capabilities** 탭
  - **Team**: Personal Team 확인
  - **+Capability** 클릭
  - **Background Modes** 검색 후 추가
  - **Audio** 체크박스 활성화

### 3. 로컬 패키지 (YoutumuKit) 추가
- **File** → **Add Packages...**
- 왼쪽 사이드바에서 **Add Local...** 클릭
- `../YoutumuKit` 디렉토리 선택 (watch 폴더 상위의 YoutumuKit)
- **Add to Project** 다이얼로그:
  - **Add to YoutumuWatch** 선택
  - **YoutumuWatch Watch App** 체크
  - **Add Package** 클릭

**주의**: YoutumuKit의 `Package.swift`에 다음 라인이 없으면 추가하세요:
```swift
platforms: [.watchOS(.v9), .macOS(.v14)]
```

### 4. CA 인증서를 번들 리소스로 추가
- 프로젝트 네비게이터에서 **YoutumuWatch Watch App** 타겟 선택
- **Build Phases** 탭 → **Copy Bundle Resources** 섹션
- **+** 클릭 → `scripts/ca/out/ca.crt` 파일 선택
- **Add** 클릭
- **Build Phases**에 추가된 항목의 이름이 `ca.crt`인지 확인

### 5. Swift 소스 파일 추가
Xcode 프로젝트에 이 단계에서 준비된 5개의 Swift 파일을 추가합니다.

#### 기본 ContentView 대체
1. 프로젝트 네비게이터에서 **YoutumuWatch Watch App** 폴더의 **ContentView.swift** 선택
2. **Delete** (또는 우클릭 → **Delete**)
3. **Remove Reference** 선택 (파일 삭제 안 함)

#### 준비된 파일 추가
1. 프로젝트 네비게이터에서 **YoutumuWatch Watch App** 폴더 우클릭
2. **Add Files to "YoutumuWatch Watch App"...**
3. 파일 탐색기에서 `watch/YoutumuWatch Watch App/` 디렉토리로 이동
4. 다음 5개 파일을 선택:
   - `KeyStore.swift`
   - `EnrollClient.swift`
   - `AACDecoder.swift`
   - `StreamPlayer.swift`
   - `ContentView.swift`
5. **Copy items if needed** 체크 해제 (파일이 이미 올바른 위치)
6. **YoutumuWatch Watch App** 타겟 체크 확인
7. **Add** 클릭

### 6. 빌드 및 테스트
#### Simulator에서 먼저 빌드
- **Product** → **Build** (⌘B)
- 빌드 성공 확인

#### 실기기에 배포 (선택사항)
- iPhone과 Apple Watch를 페어링 (필요시)
- Xcode 상단의 scheme을 **YoutumuWatch** 선택
- destination을 실제 Watch로 설정
- **Product** → **Run** (⌘R)

## 빌드 에러 해결

| 에러 | 원인 | 해결책 |
|------|------|--------|
| `Cannot find 'YoutumuKit' in scope` | 로컬 패키지 미추가 | 단계 3 재확인, `Package.swift` 플랫폼 라인 추가 |
| `'ca.crt' not found in bundle` | 리소스 미추가 | 단계 4 재확인 |
| `Type 'StreamPlayer' cannot be used as a property initializer` | 타입 초기화 문제 | @State 데코레이터 확인, `@ObservedObject` 필요 여부 검토 |
| Simulator에서 "Secure Enclave 불가능" 안내 | 예상된 동작 | KeyStore.swift의 `#if !targetEnvironment(simulator)` 조건 동작 (Keychain 키로 fallback) |

## 검증

### 임시 테스트 (enrollment 없이)
1. Xcode에서 빌드 후 Simulator 실행
2. ContentView의 "Enrollment" 섹션이 표시되는지 확인
3. "Playback" 섹션 (Server Host, Play/Stop 버튼, Marker 텍스트)이 표시되는지 확인

### 전체 Flow 테스트 (Task 8, 9 완료 후)
- Mac: `swift run MacAgent enroll 123456` + `caddy run`
- Watch (Wi-Fi): Mac IP, 6자리 코드 입력 → Enroll → "identity OK" 표시
- Watch: Server Host 입력, Play 버튼 → 오디오 수신 및 재생 확인

## 참고 사항
- 모든 파일은 Swift 5.9 이상 필요
- watchOS 9.0 이상 타겟
- mTLS 인증서는 Task 8의 enrollment process로 Keychain에 저장됨
