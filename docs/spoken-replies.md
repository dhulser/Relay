# Spoken replies (working name: **Speak**)

> Status: proposal, 4 Oct 2026. Nothing here is built. Section 11 is the spike
> that decides whether the main design survives contact with Zoom.

## 1. What it is

Today Relay is one-directional: it hears the other person and shows you their
words in your language. Speak closes the loop. While a session is running you
hold a key, say something in your language, let go, and a few seconds later
the other person hears it in theirs, through the call's microphone, in a
synthetic voice. You never leave the call, they never install anything.

Two situations, two outputs:

| Situation | Relay hears them through | Your translation goes out through |
|---|---|---|
| **On a call** (Zoom, Meet, Teams, FaceTime, a browser) | system audio or the chosen app, as today | a virtual microphone called **Relay Voice** that you pick in the call app |
| **In the room** | the microphone, as today | this Mac's speakers |

The call case is the one you asked for and the one that needs real engineering.
The in-room case falls out of the same pipeline with the last step swapped and
is a good first milestone because it needs no virtual device.

## 2. What the user experiences

1. Settings → **Speak** tab. Turn it on. Choose where the voice goes (the call
   or the speakers), the hold key, the voice engine.
2. For a call, pick **Relay Voice** as the microphone in Zoom/Meet/Teams. The
   menu bar popover shows whether some app is actually using it, so you can
   tell before you start talking.
3. Press **Start listening** as usual. Subtitles for the other side appear as
   today.
4. Hold the key. A small HUD appears near the subtitles: *Listening… English →
   Spanish*, with a level meter. Speak.
5. Release. HUD: *Translating…*, then your translated sentence appears in the
   subtitle panel as a line labelled **You**, in a distinct tint, with the
   original underneath if "show original" is on. HUD: *Speaking…*.
6. The far side hears the Spanish. Nobody hears your English (unless you turn
   on pass-through, section 6).
7. Press the key again while it is speaking to cut it off. Press Esc during
   *Translating…* to throw a sentence away before it is spoken.

Everything about the current experience is unchanged when Speak is off.

## 3. Pipeline

```
hold key ─► mic capture ─► release ─► Whisper (language hint = your language)
        ─► translate (existing lanes, direction reversed) ─► text-to-speech
        ─► Relay's own audio output ─► [call] tapped into Relay Voice, muted on speakers
                                     ─► [room] plays on the speakers
```

Every box except the last two already exists.

- **Capture.** `MicrophoneCaptureService` already opens the default input
  through AVAudioEngine and hands buffers on. Speak needs the same engine for
  playback as well (section 4), so the engine moves into a new
  `VoiceOutputService` and the mic tap feeds whichever consumer wants it.
- **Recognition.** `WhisperTranscriptionService` is already used with a
  language hint when the source is explicit. For your own speech the language
  is known (it is the subtitle *target*), so recognition is faster and more
  accurate than the auto-detect path. One utterance per key hold: on release,
  flush whatever has accumulated as a single phrase rather than waiting for a
  pause. Reject holds under ~300 ms (an accidental tap) and drop results that
  Whisper flags as no-speech or that match its known hallucination strings
  ("Thank you for watching" and friends).
- **Translation.** The existing `TextTranslating` implementations (Claude,
  OpenAI, Hosted) with `TranslationPrompt` built for the reverse direction:
  source = your language, target = their language. The prompt gets one new
  sentence for this path: the text will be *spoken aloud*, so expand
  abbreviations and numbers into words and avoid anything that only works on a
  screen. A separate lane instance, never the one translating the incoming
  side, so queues do not interleave.
- **Their language** is whichever of these applies first: the explicit source
  language if one is set; the language of the most recent incoming line when
  auto-detect is on; a **Speak to them in** setting as the fallback for when
  nothing has been heard yet. The HUD always shows the direction so a wrong
  guess is visible before it is spoken.
- **Speech.** A new `SpeechSynthesizing` protocol with three implementations,
  section 5.
- **Output.** Relay plays the synthesized audio through its own
  `AVAudioPlayerNode`, which is the one piece the two situations share.

## 4. Getting the voice into the call: the virtual microphone

macOS has no API that lets an app push audio into the hardware microphone.
What "speaks through your microphone" has always meant on a Mac is a *virtual
input device* that other apps can select instead of the real mic. Three ways
to have one:

### A. Driverless: a public aggregate device fed by a process tap (recommended, pending spike)

Relay already creates process taps and private aggregate devices to *read*
system audio (`SystemAudioCaptureService`). The same two primitives, pointed
the other way, make a virtual mic without a driver:

1. Create a process tap on **Relay's own process** with
   `muteBehavior = .mutedWhenTapped`. Relay's playback is then diverted into
   the tap and the speakers stay silent.
2. Create an aggregate device named **Relay Voice**, with that tap in its tap
   list, **not** marked private (`kAudioAggregateDeviceIsPrivateKey: false`),
   with a fixed UID (`co.kevel.Relay.voice`) so Zoom's remembered mic choice
   matches again after a relaunch.
3. The aggregate is a first-class Core Audio device with input streams, so it
   appears in every app's microphone list. Zoom records from it and gets
   whatever Relay plays.

Why this is attractive: no installer, no admin password, no kernel or system
extension, no restart of `coreaudiod`, no new TCC prompt (tapping already needs
the system-audio permission Relay has), and nothing left behind on uninstall.
It follows Relay's output device automatically, because a *process* tap does
not care where the process is playing. It works on macOS 14.2+, and Relay
already requires 15.

Why it needs a spike: aggregate devices are visible to other apps by design,
but nobody guarantees every call app lists one that has only a tap and no
hardware sub-device, and `mutedWhenTapped` on one's own process is an unusual
use. Section 11 tests exactly those two things before anything else is built.

Consequences to design around:

- The device should exist for as long as Speak is enabled and Relay is
  running, not just during a session. If it vanished whenever you pressed
  stop, Zoom would silently fall back to the built-in mic mid-call. Hence
  pass-through (section 6) has to run whenever the device exists.
- Quitting Relay removes the device; call apps fall back to their default mic.
  Document it; no fix.
- The incoming side's global tap currently excludes no processes because Relay
  played no audio. It must now exclude Relay's own process, or in the in-room
  configuration Relay would subtitle its own voice.
- Two aggregate devices will exist during a session (the private capture one
  and Relay Voice). They are independent.

### B. A Core Audio HAL plug-in (fallback)

What BlackHole and Loopback do: an `AudioServerPlugIn` bundle in
`/Library/Audio/Plug-Ins/HAL/`, loaded by `coreaudiod`. Rock solid and
universally visible, but it needs an admin password to install, a restart of
`coreaudiod`, its own signing and notarization, and an uninstaller. BlackHole
is GPL-3, so it cannot be vendored into an MIT app; Apple's sample driver can be
the starting point for our own. Only if A fails.

### C. Tell users to install BlackHole themselves

Works today for the technically inclined and is what people do with other
tools. It is not a product. Mentioned only to rule it out.

## 5. Voices

Claude has no speech output, so the voice comes from elsewhere. Tested on
4 Oct 2026 with the same two sentences (English and Spanish) in every voice;
the harness is `scripts/voice-test.sh` + `scripts/voice-test-page.py`, and
`scripts/voice-latency.sh` measures streaming latency.

| Engine | Verdict | Latency to first audio | Cost | Needs |
|---|---|---|---|---|
| **OpenAI `gpt-4o-mini-tts`** | Natural enough for a business call. **Default.** Ships with two voices: **Nova** (female) and **Cedar** (male), chosen by ear from six candidates. | see the measurements below | roughly a cent and a half per minute of generated speech | the OpenAI key Relay already holds |
| **Apple** (`AVSpeechSynthesizer`, rendered to buffers, never straight to the speakers) | The compact voices a fresh Mac ships with are not acceptable. The Enhanced/Premium ones are passable but there is **no API or command to download them**: each user would have to find the pane in System Settings (VoiceOver settings on macOS 26) by hand. **Fallback only**, for when the network or the key fails, so the far side never gets silence. | instant | free, offline | nothing |
| **Own voice** (ElevenLabs or similar voice cloning) | The far side hears *you* speaking their language. Not tested yet. | ~1 s | highest, separate account | a new key and a short enrolment |

OpenAI's terms require telling listeners the voice is synthetic. Relay's
first-run tip for Speak says so and suggests a one-line heads-up to the other
party; the Settings tab repeats it.

Settings: voice (Nova / Cedar, with the other OpenAI voices behind "More"),
speed, and a test button that speaks a fixed sentence through the chosen
output. On a hosted or company account speech goes through a new Worker
route, `/v1/speak`, metered per character under the same monthly cap; the
Worker owns the model choice as it does for translation.

### Cost, worked example

A 30-minute call where you talk half the time. Recognition is local on both
sides, so it is free; the rest is API usage at list prices on 4 Oct 2026.

| Item | Basis | Cost |
|---|---|---|
| Translating what they say (15 min), as today | README figure, ~$0.19 per hour of speech on Haiku 4.5 | $0.05 |
| Translating what you say (15 min), the new reverse lane | same | $0.05 |
| Speaking your 15 minutes aloud | gpt-4o-mini-tts: $0.60 per 1M text tokens in, $12 per 1M audio tokens out, about 1,500 audio tokens per minute, so ~$0.015 per generated minute | $0.23 |
| **Total** | | **about $0.33** |

The voice is 70% of the bill and about three times what translation costs,
but the whole call still costs less than a coffee. With OpenAI's Luna for
translation instead of Haiku the total is about $0.25. The hosted tier
should meter Speak separately, per generated minute, so a quiet call pays
nothing extra.

Request shape that matters for latency: `response_format: "pcm"` (24 kHz
mono Int16, no container to wait for), chunked streaming, and playback
starting on the first chunk. The `instructions` field carries a one-line
interpreter brief: conversational pace, warm and neutral.

## 6. Pass-through

With Relay Voice selected as the mic, Zoom hears *only* what Relay plays. So
when you want to say "hi" in the shared language, you would be mute. Fix:
while the key is **not** held, Relay copies the real microphone to its output
(so into Relay Voice) with ~20–40 ms of latency. While the key **is** held,
pass-through stops: the far side hears silence until the translation plays
instead of hearing the untranslated original. A setting lets you keep the
original audible too, for people who prefer it, at reduced volume.

Pass-through audio is never transcribed or sent anywhere; it is a copy from
one buffer to another inside Relay.

In the in-room configuration there is no pass-through, and the incoming
pipeline is gated off while Relay is speaking plus ~300 ms, so the mic does
not transcribe the speaker output. Half duplex, the way a human interpreter
works.

## 7. The hold key

Three constraints shape this:

- A bare key such as **T** or **Space** cannot be the default. Registering it
  system-wide would steal it from every text field on the Mac, and watching it
  *without* stealing it needs an event tap, which needs the Input Monitoring
  permission, a new prompt Relay has avoided so far.
- Carbon `RegisterEventHotKey`, which `GlobalHotKey` already uses, delivers
  both `kEventHotKeyPressed` and `kEventHotKeyReleased`, so hold-to-talk works
  with no new permission as long as the key has modifiers.
- Some people cannot hold a key for ten seconds, and some keyboards drop the
  release event.

So:

- **Default: hold ⌃⌥Space.** Not bound by macOS or by Spotlight (⌘Space),
  Finder search (⌥⌘Space), Alfred (⌥Space) or input-source switching
  (⌃Space). Changeable in Settings, with the same recorder style the start/stop
  shortcut uses.
- **Toggle mode** as a setting: tap to start, tap to stop.
- **An on-screen button** in the subtitle panel and the popover: press and hold
  with the mouse. Discoverable, needs no memory, and is how the first-run tip
  explains the feature.
- **Hard ceiling of 60 s** per hold, with the HUD counting down the last ten,
  because a dropped release event otherwise records forever.
- A **bare-key option** (T, Space, a lone Right ⌥) comes later behind the
  Input Monitoring prompt, for people who want Discord-style push-to-talk and
  accept the permission.

## 8. Interface

- **Settings → Speak**: on/off; output (call / speakers); hold key and toggle
  mode; speak to them in (auto / a language); voice engine, voice, speed, test;
  pass-through and "let them hear my voice too"; confirm before speaking.
- **Popover**: when Speak is on and the output is the call, a line reading
  *Relay Voice is the mic in an app* or *No app is using Relay Voice yet. Pick
  it as the microphone in your call app*, driven by
  `kAudioDevicePropertyDeviceIsRunningSomewhere` on the aggregate. The
  hold-to-talk button sits next to Start.
- **HUD**: a pill above the subtitles with four states: listening (meter),
  translating, speaking (with a stop glyph), and a brief *Didn't catch that*
  when nothing was recognised. Same window class as the subtitle panel so it
  floats over full-screen video and never takes focus.
- **Subtitles**: your line appears with the label **You**, a tint reserved
  for you, right-aligned, with the original under it when that option is on.
  In comparison mode only the left lane is used for spoken replies.
- **Confirm before speaking** (off by default): the translation appears and
  waits; press the key to send, Esc to discard. For people translating into a
  language they half-know and want to glance at first.
- **Transcript**: your lines are kept with a `you` marker and saved in the
  same file.
- **Stats**: words spoken, alongside words translated.

## 9. Latency

Release-to-first-sound is the number that matters; it is the awkward silence
on the call.

### Measured: OpenAI speech, 4 Oct 2026

`scripts/voice-latency.sh`, from Dylan's Mac on home wifi, streaming PCM, one
sentence of 6–8 s of speech, three runs each. *First byte* is when the far
side would start hearing the voice; *total* is when the whole sentence has
arrived.

| Model | Voice | Lang | First byte (s), 3 runs | Total (s) |
|---|---|---|---|---|
| gpt-4o-mini-tts | Nova | EN | 1.82 · 1.39 · 0.57 | 1.6–2.8 |
| gpt-4o-mini-tts | Nova | ES | 0.80 · 1.37 · 0.81 | 1.9–2.5 |
| gpt-4o-mini-tts | Cedar | EN | 0.76 · 0.63 · 0.90 | 1.5–1.7 |
| gpt-4o-mini-tts | Cedar | ES | 0.56 · 0.53 · 0.64 | 1.6–2.7 |
| tts-1 (the "low latency" model) | Nova | EN/ES | 1.94 · 1.14 · 2.32 · 2.03 | 1.4–3.1 |

Takeaways: typical first audio in **0.6–0.9 s**, occasional outliers to
1.8 s, no difference between languages. The older `tts-1` is *not* faster, so
there is no reason to trade quality for it. Generation runs 3–4× faster than
playback, so once the voice starts it never stalls. The outliers look like
connection setup; keeping one HTTPS connection warm to the speech endpoint for
the session should remove most of them (`URLSession` does this when the
session object is reused, which is the existing pattern in the translators).

### Budget

| Step | v1 | After optimisation |
|---|---|---|
| Whisper, 5 s phrase, Small model | 0.3–0.5 s | ~0.1 s: run inference on the audio *during* the hold every second or so, so release only transcribes the tail |
| Translation, Haiku 4.5 | ~1 s to the full sentence | first clause in ~0.4 s: stream and split at sentence boundaries |
| First speech audio | 0.6–0.9 s measured, 1.8 s worst | the same, overlapped with translation of the next sentence; warm connection removes the outliers |
| **Total, release → far side hears the voice** | **~2–2.5 s** | **~1–1.3 s** |

Two seconds is roughly a consecutive interpreter's pause and is acceptable for
v1. Ship the simple serial version first and measure end to end. If the real
figure disappoints, the step to attack is translation, not speech: it is the
only one that waits for a whole sentence before anything downstream can start.

## 10. Failure and edge cases

- **No speech recognised**: HUD *Didn't catch that*, nothing spoken, nothing
  sent.
- **Translation error**: existing `onTrouble` / `onFatalError` paths; the HUD
  shows the warning text and the hold key does nothing until it clears.
- **Voice engine fails** (network, 402 on hosted): fall back to the Apple
  voice for that sentence and show a warning, rather than leaving the far side
  in silence.
- **Key pressed while speaking**: stop playback immediately and start
  listening (barge-in).
- **Hold while a sentence is still translating**: queue; sentences are spoken
  in order.
- **Output device changes mid-call** (headphones plugged in): a process tap
  follows the process, so nothing to do. Verify in the spike.
- **Sleep/wake, `coreaudiod` restart**: rebuild the tap and aggregate with the
  same UID; log it.
- **Microphone permission refused**: Speak cannot work; Settings says so with
  the button to System Settings that the mic source already uses.
- **Microphone chosen as the incoming source and output set to the call**: a
  contradiction (why would the far side be on a call?). Settings explains and
  switches the output to speakers.
- **Relay quits**: Relay Voice disappears, call apps revert to their default
  mic. Said once in the Settings tab.
- **Headphones.** Between translations the real microphone passes through
  Relay Voice, and with speakers it hears the call's own audio; the call app's
  echo canceller may or may not cope with the extra 40 ms in the loop. Said in
  the Settings tab.

## 11. Spike: done, both answers yes (4 Oct 2026)

Run on Dylan's Mac (macOS 26, Xcode 27) from the `speak-spike` branch, with
Zoom, Teams and ChatGPT running.

1. **A non-private aggregate device with a tap on Relay's own process works as
   a virtual microphone.** `Relay Voice` appeared in the system's input list
   next to Zoom's and Teams' own virtual devices, Zoom listed it and showed
   level from it, and a separate process (ffmpeg over AVFoundation, the same
   path Chrome and QuickTime use) recorded the Cedar sample from it cleanly at
   −24 dB mean / −5 dB peak. With `mutedWhenTapped` the speakers stayed
   silent. No new permission prompt: it ran on the existing system-audio grant.
   `kAudioDevicePropertyDeviceIsRunningSomewhere` flipped while the other
   process was reading and back when it stopped, so the popover can say
   whether a call app is using the device.
2. **The hold key reports its release.** ⌃⌥Space through Carbon
   (`kEventHotKeyReleased`) with Zoom frontmost: two holds, 4.24 s and 8.08 s,
   each with its release line.

Two things learned that the design now accounts for:

- **An aggregate device outlives a killed process.** After `pkill`, the old
  Relay Voice stayed registered under the fixed UID and a second create was
  refused with `nope`. `RelayVoiceDevice.create` now looks the UID up and
  destroys a stale device first; a normal quit tears it down.
- **ChatGPT's launcher is ⌥Space.** Confirmed from its preferences; it does
  not touch ⌃⌥Space. The first failed test was ⌥Space being pressed instead.

So: build **A**. Option B is dropped.

## 12. Code shape

New, under `Relay/Speak/`:

- `VoiceOutputService` — owns the AVAudioEngine graph (mic in → pass-through
  gain → mixer ← TTS player → out), creates and destroys the Relay Voice tap
  and aggregate, reports `isInUseByAnotherApp`.
- `SpokenReplyController` — the state machine (idle, listening, transcribing,
  translating, speaking, confirming), the hold timer, the HUD model, and the
  gating of the incoming pipeline while speaking.
- `SpeechSynthesizing` protocol with `AppleSpeechSynthesizer`,
  `OpenAISpeechSynthesizer`, `HostedSpeechSynthesizer`.
- `HoldKey` — `GlobalHotKey` extended with a release callback, or a sibling.
- `SpeakSettingsView`, `SpeakHUD`.

Touched: `AppState` (settings, wiring, a reverse-direction lane,
`activeEngines` unchanged), `TranslationPrompt` (a spoken-output variant),
`SystemAudioCaptureService` (exclude Relay's own process from the global tap),
`SubtitleManager`/`SubtitleView` (the **You** line), `Transcript`,
`TranslationStats`, `MicrophoneCaptureService` (becomes a consumer of the
shared engine's mic tap rather than owning an engine). Hosted: `speak.ts` and
a character meter.

## 13. Phases

1. **Spike** (section 11). Done 4 Oct.
2. **In the room**: hold key, Whisper, reverse lane, OpenAI voice with Apple fallback, speakers,
   HUD, the You line. Ships on its own as "Speak for me in the room". **Built 4 Oct**
   (`Relay/Speak/`, the Speak tab, `SpokenReplyController`). Verified end to end with
   a Debug self-test (`-speakSelfTest file.aiff`): a 6.7 s English sentence recognised in
   0.3 s, translated to Spanish, spoken by Cedar with first audio 1.2 s after the
   translation on a cold connection. Two findings: Speak loads its own Whisper
   context (a second ~500 MB on the GPU; sharing one is a later optimisation), and
   the incoming side is muted while Relay speaks on *every* source, because the
   system tap hears the speakers too.
3. **On a call**: Relay Voice, pass-through, popover status,
   Settings tab complete. This is the feature as you described it. **Built 4 Oct.**
   The call line (output engine, microphone pass-through, Relay Voice device) comes
   up at launch whenever Speak is set to the call and stays up between sessions,
   so a call app's choice of microphone never goes dead. Verified by recording
   from Relay Voice during a self-test: room noise at −45 dB through the
   pass-through, then a nine-second burst at −20 dB where Cedar's Spanish played,
   then room noise again; Relay's own playback was excluded from the system tap
   and nothing of the Spanish was subtitled. Pass-through drops buffers if it
   falls more than 150 ms behind, so input and output clocks drifting apart
   cannot grow the delay over a long call. Confirm-before-speaking: a tap of the
   key sends, a hold replaces, the popover has Say it / Drop it.
4. **Latency**: inference during the hold, streaming sentence split, parallel
   synthesis.
5. **Hosted** `/v1/speak`, bare-key option, your own voice.

## 14. Privacy

- The microphone is opened for the session when Speak is on, but its audio
  is looked at only while the key is held (every other buffer is dropped on
  arrival). With pass-through on, buffers are copied to the output inside
  Relay and nothing from them is transcribed, stored or transmitted.
- Recognition is local, as today. The translated text goes to the translation
  provider as today, and, with the OpenAI or own-voice engines, to the speech
  provider. With the Apple voice no audio or speech text leaves the Mac.
- Nothing is written to disk. The README's privacy section gains a paragraph.

## 15. Decisions

Taken 4 Oct 2026:

- **Voice**: OpenAI `gpt-4o-mini-tts`, Nova (female) and Cedar (male). Apple is
  the offline fallback only.
- **Pass-through** is on by default for the call output. Without it, picking
  Relay Voice mutes you.
- **The far side does not hear your original** by default. A setting lets it
  through at reduced volume.
- **In-room ships first**, as its own release, then the call version.
