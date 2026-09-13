# Live Translator

A menu-bar app that puts live translated subtitles on screen for whatever audio
is playing on your Mac. Point it at a Spanish YouTube video and read English
captions while the original audio keeps playing normally.

**Apple Silicon, macOS 15+** (the Apple speech engine additionally needs macOS 26).

## Setup

1. Open `🎙 Translate` in the menu bar → **Settings…**
2. Pick a provider and paste that provider's API key (stored in your Keychain).
3. Close Settings, click **Start Translation**.
4. Grant **Screen Recording** when macOS asks, then quit and reopen the app —
   macOS only applies the grant on a fresh launch.

## Providers

Audio is always captured with ScreenCaptureKit. What happens next depends on the
provider:

| Provider | Pipeline | Cost/hour | Language detection |
|---|---|---|---|
| **Claude** | Whisper on-device → Claude | ~$0.31 (Haiku 4.5) | automatic |
| **OpenAI** | Whisper on-device → `gpt-5.6-luna` | ~$0.07 | automatic |
| **OpenAI Realtime** | audio → `gpt-realtime-translate` | $2.04 | automatic |

Costs assume roughly twelve spoken phrases a minute. The two local providers
bill only for text, so quiet content is nearly free; OpenAI Realtime bills by
audio duration whether anyone is speaking or not.

The two local providers can also use **Apple's** recogniser instead of Whisper.
It is lower latency but handles one language at a time, so the source language
must be set by hand — Whisper identifies the language of every utterance.

### Speaker labels

With the Whisper engine, **Label speakers** tags each line with the voice that
said it — "Speaker 1", "Speaker 2" — in its own colour. A 27 MB voiceprint model
(sherpa-onnx CAM++) runs on the same audio Whisper transcribes, so a label can
never drift out of sync with its line.

It recognises that two lines share a voice, not *who* anyone is. There is no
enrolment: the first voice heard becomes Speaker 1. Measured separation is wide
(same voice ~0.85 cosine, different voices ~0.1), so the 0.5 threshold sits in a
large gap. Speakers reset each session, and it caps at six voices.

Not available on OpenAI Realtime: that model returns text with no alignment to
our audio, so there is nothing to attach a label to. Without labels, a pause
longer than 1.4s draws a short rule instead.

### Speech models

Whisper models download on demand into
`~/Library/Application Support/LiveTranslator/Models`.
`Small` (466 MB) is the default and the right balance; `Base` (142 MB) is faster
but guesses more on noisy audio; `Medium` (1.5 GB) is the most accurate.

## Subtitles

The overlay floats above other windows, including full-screen apps, and never
takes keyboard focus. Drag it anywhere — the position is remembered.
**Recenter Subtitles** in the menu puts it back.

Roughly three lines stay visible. Partial text is coalesced on a ~150 ms cadence
so captions don't flicker as tokens arrive.

## Privacy

- No audio is ever written to disk, and no transcripts are stored.
- With Whisper or Apple recognition, **audio never leaves the machine** — only
  the recognised text is sent to the translation API.
- With OpenAI Realtime, system audio is streamed to OpenAI.
- The microphone is never used. No analytics, no telemetry.
- API keys live in the macOS Keychain and are never logged.

## Building

Requires Xcode 26+ and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project LiveTranslator.xcodeproj -scheme LiveTranslator \
  -configuration Release -derivedDataPath build build
```

`./run.sh` does a Debug build, relaunches, and tails the log.

### whisper.cpp

The static libraries in `Vendor/whisper` are checked in (~4 MB) so a clone
builds without cmake. To change the pinned version (currently `v1.9.2`) or the
build flags:

```bash
brew install cmake
./scripts/build-whisper.sh
```

They are arm64-only and built with Metal plus Accelerate, which is why the app
is Apple Silicon only.

### sherpa-onnx

`Vendor/sherpa` holds a prebuilt xcframework (~26 MB, thinned to arm64) used for
speaker embeddings. To change the pinned version (currently `v1.13.8`):

```bash
./scripts/fetch-sherpa.sh
```

## Debugging

```bash
log stream --style compact --predicate 'subsystem == "co.kevel.LiveTranslator"'
```

Every stage is traced: `[Audio]` capture and format, `[Whisper]` or `[Speech]`
recognition with the detected language, `[Claude]`/`[OpenAI]`/`[Realtime]` for
translation, and `[Subtitles]` for what reaches the screen.

## Tests

```bash
xcodebuild test -project LiveTranslator.xcodeproj -scheme LiveTranslator \
  -configuration Debug -derivedDataPath build
```

Covers audio-format conversion, subtitle coalescing, an end-to-end pass of the
local speech path against a Spanish fixture, and voiceprint clustering against
two real voices interleaved. Model-dependent tests skip if the model is not
downloaded.
