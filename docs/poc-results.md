# Phase 0 PoC Results (측정일: 2026-08-26 ~ 2026-08-29)

측정 환경: Mac mini(호스트) + iPhone 15 Pro(사전 검증) + Apple Watch Series 7 41mm Cellular(게이트) / KT GiGA WiFi + KT LTE / DDNS youtumu.duckdns.org(DuckDNS)

| Gate | 항목 | 기준 | 측정값 | 판정 |
|---|---|---|---|---|
| G1 | 백그라운드 재생 | 화면 OFF + 손목 내림 10분 지속 | 10분 연속 재생, 소리 양호, 서버측 연결 끊김 0회 (5초 간격 관찰) | **PASS** |
| G2 | 셀룰러 단독 | iPhone 없이 외부 LTE에서 재생 시작 성공 | 네트워크 경로는 iPhone LTE로 사전 실증(DDNS→포워딩→mTLS 재생 성공). Watch 단독은 셀룰러 개통 후 측정 | 보류 (경로 검증 완료) |
| G3 | SE mTLS | SecIdentity 기반 연결 성공 (LAN + LTE) | Watch 실기기 SE 키 enrollment "identity OK" + LAN(mDNS·hairpin) 재생 성공. iPhone SE 키로 LTE 경로도 성공 | **PASS** (Watch LTE 재확인은 G2와 함께) |
| G4 | 곡 전환 latency | `m` 마커 10회, p95 ≤ 2초 | (측정 예정) | |
| G5 | 60분 soak | 자동 복구 불가 disconnect 0회, stall 누적 < 30초 | (셀룰러 개통 후 측정 예정) | |
| G6 | Mac 캡처 | 화면 잠금 상태에서 캡처 지속 | 93초 중 80초 연속 오디오(rms~0.04), 잠금 후에도 SCK 콜백 지속 | **PASS** |
| M1 | 배터리 (기록용) | 60분 소모 % | 10분 기준 45%→45% (0%p). 60분 값은 G5에서 | 판정 없음 |
| M2 | 셀룰러 데이터 (기록용) | 60분 사용량 MB | Wi-Fi 10분 기준 4.3MB (~26MB/h, 음원 VBR 특성으로 96kbps 이론치 43MB/h보다 낮음). LTE 값은 G5에서 | 판정 없음 |

## 실기기 검증으로 발견·수정한 결함 (스펙 반영 완료)

1. **서버 인증서 유효기간**: 3년(1095d) → Apple TLS 정책상 ≤825일 (watchOS `OtherTrustValidityPeriod` 거부) → 820일로 수정 (§10.6)
2. **HTTP/3 금지**: iOS h3 경로는 URLSession 델리게이트의 신뢰 승인과 별개로 시스템 신뢰 평가를 강제 → 사설 CA 거부(-9802). Caddy `servers { protocols h1 h2 }` (§10.3)
3. **ATS 예외 필요**: 공개 도메인에는 ATS가 시스템 신뢰 평가 강제(`.local` 면제). Info.plist NSExceptionDomains(duckdns.org) — 델리게이트 CA 핀닝 유지로 실질 보안 동일 (§10.3)
4. **serve 캡처 수명 버그**: 캡처 객체가 Task 지역변수라 start 직후 해제 → 스트림 0바이트. case-body 호이스팅으로 수정
5. **SCStream 무진단 사망**: delegate nil이라 장기 실행 중 캡처가 조용히 죽음(TCC 변경·시스템 이벤트) → Phase 3/6에서 delegate + 사망 감지·자동 재시작 필수 (§24 자동 복구 기준)

## 운영 관찰 (백로그)

- 곡 전환 시 내려둔 볼륨 원복 현상 → Phase 5 (Crown 볼륨/§22 volume=Watch-local 구현 시 규명)
- AirPods 자동 전환이 Mac으로 오디오를 뺏는 현상 → 사용 시 자동 전환 off 권장
- Enrollment은 LAN 전용(설계 의도) — iPhone/Watch가 LTE 상태면 "오프라인" 표시됨
- Mac 볼륨 0에서도 캡처 정상(무음 운영 모드)

## 잔여 측정 계획

- Watch 셀룰러 개통 후: G2(Watch LTE 단독) + G5(60분 soak, LTE) + M1/M2 60분 실측
- G4는 Wi-Fi에서 즉시 측정 가능
