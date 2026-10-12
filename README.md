# Memento

[![Backend checks](https://github.com/SeanLee12345/memento/actions/workflows/backend-checks.yml/badge.svg)](https://github.com/SeanLee12345/memento/actions/workflows/backend-checks.yml)

A personal AI memory assistant for Meta smart glasses. Memento combines live video, speech, person recognition, and searchable conversation history to help you recall who you met and what you discussed.

Built with SwiftUI, Meta Wearables DAT, Apple Vision, on-device Parakeet speech recognition, Supabase, and AWS inference workers.

## Features

- **Live glasses input:** stream camera frames from Meta smart glasses, with an official Mock Device Kit path for development.
- **People and identity:** combine face and speaker evidence with user confirmation and a people dictionary.
- **Conversation memory:** save transcripts, stream summaries, reminders, and person-centered timelines.
- **Selective recall:** retrieve relevant memories through semantic and keyword search instead of loading every past conversation.
- **Scene context:** turn visual input into structured context for the current interaction.
- **Live assistance:** show context cards on the phone and supported glasses displays, with spoken output through the iPhone.

## Architecture

```text
Meta glasses camera + iPhone microphone
                 |
        Vision / speech processing
                 |
     Face + speaker identity evidence
                 |
  Conversation memory + selective retrieval
                 |
     Assistance cards / phone voice output
```

The iOS app handles streaming, UI, and local identity state. Supabase provides authenticated sync and memory retrieval; Edge Functions proxy model requests and issue short-lived worker tokens. AWS workers provide face embeddings, speaker embeddings, and post-session diarization.

## Getting Started

Requirements: Xcode, an iOS 17+ target, and Meta Wearables DAT 0.7.0. Real-glasses sessions use a physical iPhone, compatible glasses, and Meta AI with Developer Mode enabled.

1. Open `Memento.xcodeproj` and select the **Memento** scheme.
2. Set your signing team in Xcode and let Swift Package Manager resolve dependencies.
3. Run on an iPhone for glasses input, or use Mock Device Kit for simulator development.
4. Configure your own Supabase project and inference services for cloud-backed features using the [development guide](docs/DEVELOPMENT.md).

The [environment template](.env.example) lists configuration names. Provider credentials belong in backend secrets; the iOS app uses public Supabase client configuration and authenticated sessions.

## Repository Map

| Path | Purpose |
| --- | --- |
| `CameraAccess/` | SwiftUI app, streaming, identity, memory, and assistance |
| `MementoTests/` | iOS unit tests |
| `MementoUITests/` | UI tests |
| `supabase/` | Database migrations and Edge Functions |
| `tools/` | AWS workers, model conversion, and evaluation tools |
| `DebugBridge/` | Development instrumentation |
| `docs/` | Architecture, setup, and model notes |

## Verification

Run iOS tests from Xcode with an available simulator, or:

```sh
xcodebuild -project Memento.xcodeproj -scheme Memento \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Backend CI runs the existing worker and Lambda unit tests. These checks use mocks and do not require an AWS account:

```sh
python3 -m pip install boto3 numpy soundfile
python3 -m unittest discover -s tools/aws_diarization_worker -p 'test_*.py'
python3 -m unittest discover -s tools/diarizen_start_ec2_lambda -p 'test_*.py'
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for upstream attribution and terms.
