#!/bin/zsh
# Measures OpenAI speech latency the way Relay would use it: streaming PCM,
# time to first audio byte and total time, for the two default voices.
# Reads the key from the Keychain item Relay keeps; never prints it.
set -euo pipefail
cd "$(dirname "$0")/.."
KEY=$(security find-generic-password -s co.kevel.Relay -a openai-api-key -w 2>/dev/null || true)
[[ -z "$KEY" ]] && { echo "No OpenAI key in the Keychain."; exit 1; }
EN="Sorry, could you repeat the last part? I want to make sure we agree on the delivery date before we move on."
ES="Perdón, ¿podrías repetir la última parte? Quiero asegurarme de que estamos de acuerdo con la fecha de entrega antes de continuar."
INSTR="You are interpreting for someone on a business video call. Speak naturally and clearly at a conversational pace, warm and neutral."
printf '%-18s %-6s %-4s %-8s %-8s %s\n' model voice lang firstByte total bytes
for model in ${=TTS_MODELS:-gpt-4o-mini-tts tts-1}; do
  for voice in nova cedar; do
    # tts-1 has no cedar; skip the combination rather than fail.
    [[ $model == tts-1 && $voice == cedar ]] && continue
    for lang in en es; do
      text=$EN; [[ $lang == es ]] && text=$ES
      for run in 1 2 3; do
        body=$(jq -n --arg m "$model" --arg v "$voice" --arg t "$text" --arg i "$INSTR" \
          'if $m == "tts-1" then {model:$m, voice:$v, input:$t, response_format:"pcm"}
           else {model:$m, voice:$v, input:$t, instructions:$i, response_format:"pcm"} end')
        curl -sS --fail -o /tmp/relay-tts.pcm -w "%{time_starttransfer} %{time_total} %{size_download}\n" \
          https://api.openai.com/v1/audio/speech -H "Authorization: Bearer $KEY" \
          -H "Content-Type: application/json" -d "$body" \
        | awk -v m="$model" -v v="$voice" -v l="$lang" '{printf "%-18s %-6s %-4s %-8.2f %-8.2f %s\n", m, v, l, $1, $2, $3}'
      done
    done
  done
done
rm -f /tmp/relay-tts.pcm
echo "firstByte = seconds until the first audio arrives (what the far side waits). total = whole sentence. PCM 24 kHz: 48000 bytes per second of speech."
