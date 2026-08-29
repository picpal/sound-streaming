#!/bin/bash
# 원격 제어 전용 Chrome 프로필 실행 (spec §11 — 개인 세션과 격리, CDP는 127.0.0.1만)
# 최초 1회: 열린 창에서 Google 로그인 → music.youtube.com 재생 확인
#
# 주의: SCK 캡처는 bundle id(com.google.Chrome) 기준이므로 개인 Chrome 창의 소리도
# 함께 캡처된다 — 스트리밍 중에는 개인 창에서 오디오 재생을 피한다
# (완전 분리는 Phase 3에서 검토).
set -euo pipefail
PROFILE="$HOME/.youtumu-chrome"
open -na "Google Chrome" --args \
  --remote-debugging-port=9222 \
  --user-data-dir="$PROFILE" \
  --no-first-run \
  "https://music.youtube.com"
