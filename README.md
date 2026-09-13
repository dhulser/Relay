# Relay

Live subtitles, in your language, for calls and anything else playing on your
Mac. Relay listens to what your Mac is playing, recognises the speech, and puts
the translation on screen while the original audio keeps playing.

**Apple Silicon, macOS 15 or later.**

## Install

Download `Relay.dmg` from the [latest release](https://github.com/dhulser/Relay/releases/latest)
and drag Relay to Applications, or:

```bash
brew install --cask dhulser/relay/relay
```

Relay is signed and notarized. It updates itself through Sparkle; you can turn
that off in Settings → General.

## First run

1. Click **Relay** in the menu bar, then **Settings**.
2. Add an Anthropic or OpenAI API key. It goes in your Keychain and nowhere else.
3. Under **Speech recognition**, download the **Small** model (466 MB, once).
4. Close Settings and press **Start listening**. macOS asks for permission to
   record system audio; allow it, then press start again if it didn't begin.

That's it. Relay detects the spoken language automatically and translates into
the language you pick.

## What it does

- **Follows the call.** Works in Zoom, Meet, Teams, a browser, anything, with no
  bot joining the meeting. Subtitles float above every window, including
  full-screen video, and never take focus. Drag them anywhere.
- **Thirty-four languages, either direction**, detected as people speak, so a
  meeting that switches between two is fine.
- **Tells voices apart.** Optional speaker labels colour each line by who said
  it. It knows two voices differ, not who anyone is.
- **Shows the original** under each line if you want it.
- **Listens where you point it:** everything on the Mac, only the apps you
  choose, or the microphone for a conversation in the room.
- **Compares engines side by side**, each in its own column on the same audio,
  so you can decide which you would rather read.
- **Keeps count** of words translated, languages heard, and time listened. Never
  the words themselves.
- **⌃⌥⌘R** starts and stops from anywhere. Optional launch at login.

## Engines

Relay has no server. Your Mac talks to the model provider directly, with your
key. There are two ways to do it:

| Engine | Pipeline | Where the audio goes | Cost per hour of speech |
|---|---|---|---|
| **Claude** | Whisper on this Mac → text to Claude | stays on your Mac | ~$0.19 (Haiku 4.5) |
| **OpenAI** | Whisper on this Mac → text to `gpt-5.6-luna` | stays on your Mac | ~$0.04 |
| **OpenAI Realtime** | audio streamed to `gpt-realtime-translate` | sent to OpenAI | $2.04 |

The local engines wait for a phrase to finish before a line appears; Realtime
shows words while the speaker is still talking, at fifty times the price. The
local engines bill only for text, so a quiet hour costs almost nothing.

Costs are what the providers charge you. Relay itself is free with your own
key; a hosted option is planned.

### Speech recognition

The local engines use [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
on Metal. Models download on demand into
`~/Library/Application Support/co.kevel.Relay/Models`: **Small** (466 MB) is the
default, **Base** (142 MB) is faster and guesses more, **Medium** (1.5 GB) is
the most accurate. On macOS 26 you can switch to Apple's recogniser instead; it
is lower latency but handles one language at a time.

Two optional filters, both off by default:

- **Label speakers** runs a 27 MB voiceprint model
  ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) CAM++) on the same audio
  Whisper transcribes, so a label can never drift out of sync with its line.
  Voices reset each session. Telling Relay how many people are talking stops it
  inventing extras.
- **Filter out music and noise** runs Silero VAD inside Whisper, which stops it
  turning a soundtrack into words.

## Privacy

- Audio is never written to disk. Buffers exist only long enough to hand on.
- With the local engines, **audio never leaves your Mac**; only the recognised
  text is sent to the translation API. With Realtime, audio streams to OpenAI.
- Nothing anyone said is stored or logged. If you turn on **Keep a transcript**,
  lines are held in memory until you save them or press start again.
- The microphone is used only when you choose it as the source.
- Counts of words and time are kept in preferences. No analytics, no telemetry.
- API keys live in the macOS Keychain and are never logged.

## Building

Requires Xcode 26 and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Relay.xcodeproj -scheme Relay \
  -configuration Debug -derivedDataPath build build
```

`./run.sh` does a Debug build, relaunches, and tails the log.

The whisper.cpp static libraries (`Vendor/whisper`, ~4 MB, arm64, Metal +
Accelerate) and the sherpa-onnx xcframework (`Vendor/sherpa`, ~26 MB) are
checked in so a clone builds without cmake or network. To change the pinned
versions: `scripts/build-whisper.sh` (needs `brew install cmake`) and
`scripts/fetch-sherpa.sh`.

## Tests

```bash
xcodebuild test -project Relay.xcodeproj -scheme Relay \
  -configuration Debug -derivedDataPath build
```

Covers audio conversion, subtitle coalescing, the wire formats of all three
providers, sentence splitting, Keychain round-trips under a test service, the
language table against Whisper's, word counting across scripts, transcript
formatting, stats, an end-to-end pass of the local speech path on a Spanish
fixture, and voiceprint clustering on real voices. Model-dependent tests skip
when the model isn't downloaded. CI runs the suite on every push.

## Releasing

```bash
./scripts/release.sh            # build, notarize, staple, DMG, appcast, cask
./scripts/release.sh --publish  # …and create the GitHub release
```

Needs a **Developer ID Application** certificate, a notarytool credential named
`notary`, and the Sparkle EdDSA key in your login keychain (`generate_keys`).
Run it from a Terminal you can see: signing the disk image asks for the key
the first time. Afterwards copy `dist/relay.rb` to `Casks/relay.rb` in
`dhulser/homebrew-relay`.

```bash
xcrun notarytool store-credentials "notary" \
  --apple-id "you@example.com" --team-id 4PJ4624484 \
  --password "app-specific-password-from-appleid.apple.com"
```

## Debugging

```bash
log stream --style compact --predicate 'subsystem == "co.kevel.Relay"'
```

Every stage is traced: `[Audio]`, `[Whisper]`/`[Speech]`, `[Claude]`/`[OpenAI]`/
`[Realtime]`, `[Subtitles]`. What was said is deliberately not in there; Debug
builds print it to stdout.

## License

MIT.
