#!/bin/zsh
# Renders the same two sentences with OpenAI's speech voices, for the Speak
# feature voice comparison. Reads the OpenAI key from the Keychain item Relay
# already keeps; the key is never printed. Costs a few cents in total.
# Output: build/voice-test/openai-<lang>-<gender>-<voice>.m4a
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/voice-test; mkdir -p "$OUT"
KEY=$(security find-generic-password -s co.kevel.Relay -a openai-api-key -w 2>/dev/null || true)
if [[ -z "$KEY" ]]; then echo "No OpenAI key in the Keychain (service co.kevel.Relay, account openai-api-key). Add one in Relay → Settings first."; exit 1; fi
MODEL=${TTS_MODEL:-gpt-4o-mini-tts}
EN="Sorry, could you repeat the last part? I want to make sure we agree on the delivery date before we move on."
ES="Perdón, ¿podrías repetir la última parte? Quiero asegurarme de que estamos de acuerdo con la fecha de entrega antes de continuar."
INSTR="You are interpreting for someone on a business video call. Speak naturally and clearly at a conversational pace, warm and neutral, no theatrical emotion."
# voice:gender — marin and cedar are the ones OpenAI recommends for quality.
VOICES=(marin:f cedar:m coral:f ash:m nova:f onyx:m)
speak() { # lang gender voice text
  local file="$OUT/openai-$1-$2-$3.m4a"
  jq -n --arg m "$MODEL" --arg v "$3" --arg t "$4" --arg i "$INSTR" \
    '{model:$m, voice:$v, input:$t, instructions:$i, response_format:"aac"}' \
  | curl -sS --fail -o "$file" https://api.openai.com/v1/audio/speech \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d @- \
  && echo "  $file"
}
echo "Rendering with $MODEL…"
for pair in "${VOICES[@]}"; do
  v=${pair%%:*}; g=${pair##*:}
  speak en "$g" "$v" "$EN"
  speak es "$g" "$v" "$ES"
done
echo "Done. Now: python3 scripts/voice-test-page.py"
