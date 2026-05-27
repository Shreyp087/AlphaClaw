# AlphaClaw Repository Deep Study Report

## Executive Summary
AlphaClaw (forked/renamed from VisionClaw) is an open-source real-time AI assistant app for **Meta Ray-Ban smart glasses**. It enables **voice + vision conversations** with Google's **Gemini Live API**, optionally routing actions through **OpenClaw** (local AI agent gateway with 56+ skills). Supports **iOS (iPhone)** and **Android** phones as companions, with **phone camera fallback** for testing. Includes **WebRTC P2P streaming** to browsers and a **Node.js signaling server**.

**Core Value Prop**: \"See what you see, hear what you say, take actions on your behalf\" – glasses camera (~1fps JPEG) + mic audio streams to Gemini; AI speaks responses; tools delegate to OpenClaw for messaging, searches, lists, etc.

**Tech Stack**:
- **Frontend**: SwiftUI (iOS 17+), Jetpack Compose (Android 14+)
- **Glasses SDK**: Meta Wearables DAT (iOS: `meta-wearables-dat-ios@0.4.0`; Android: `mwdat-core/camera/mockdevice@0.4.0`)
- **AI**: Gemini Live WebSocket (native audio/video, `gemini-2.5-flash-native-audio-preview-12-2025`)
- **Streaming**: WebRTC (iOS: stasel/WebRTC; Android: stream-webrtc-android)
- **Backend**: Node.js/WS signaling server (port 8080)
- **Tools**: OpenClaw HTTP gateway (port 18789, local/LAN)

## Repo Structure
```
.
├── README.md (detailed setup/docs)
├── assets/ (UI images)
├── samples/
│   ├── CameraAccess/ (iOS Xcode project)
│   │   ├── CameraAccess.xcodeproj/
│   │   ├── Gemini/, OpenClaw/, iPhone/, WebRTC/, Settings/, ViewModels/, Views/
│   │   └── server/ (Node.js)
│   └── CameraAccessAndroid/ (Gradle: Kotlin Compose equivs)
└── OSS files
```

## Architecture (MVVM)
| Module | iOS | Android | Purpose |
|--------|-----|---------|---------|
| Config | GeminiConfig.swift | GeminiConfig.kt | Keys, audio/video params |
| Audio | AudioManager.swift | AudioManager.kt | Mic/speaker w/ echo cancel |
| Gemini | GeminiLiveService.swift | GeminiLiveService.kt | WS client |
| Session | GeminiSessionViewModel.swift | GeminiSessionViewModel.kt | Lifecycle/tools |
| Tools | OpenClawBridge.swift | Equiv | execute() → OpenClaw POST |
| Camera | DAT / IPhoneCameraManager.swift | DAT / CameraX | 1fps JPEG |
| WebRTC | WebRTCClient.swift | stream-webrtc-android | P2P browser share |

**Data Flow**:
```
Mic/Camera → Gemini WS → Audio resp / Tool call → OpenClaw → Result → Speech
```

**Dependencies**:
- iOS: SPM DAT@0.4.0, WebRTC~141
- Android: GitHub Pkgs mwdat@0.4.0, CameraX, OkHttp

## Workflow
1. Setup: Secrets.swift/kt (Gemini key), Dev Mode ON
2. Phone test: \"Start on Phone\" → AI chat
3. Glasses: Connect → Stream → Voice (e.g. \"Add milk\")
4. Live: Room code → Browser P2P

## Strengths
- Cross-platform parity
- Prod-ready (NAT, bg handling)
- Extensible via OpenClaw

## Improvements
- More tests/CI
- Server HTTPS

**Ready for Meta glasses + Gemini key.**
