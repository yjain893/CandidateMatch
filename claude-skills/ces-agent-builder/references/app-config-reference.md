# App configuration reference (values the interview chooses)

## Models (official list, CX Agent Studio)
| Model | Optimized for | Stage | Use when |
|---|---|---|---|
| `gemini-composite-v2` | Voice | GA | Best voice quality; better alphanumeric reading (phone numbers, ids); supports inline TTS tags |
| `gemini-composite-v1` | Voice | GA | Older voice composite |
| `gemini-3.7-flash` | Text | GA | Newest text model |
| `gemini-3.5-flash` | Text | GA | Default used in the real export; good all-round |
| `gemini-3-flash` | Text | Preview | |
| `gemini-2.5-flash` | Text | GA | Cheapest text option |
| `gemini-3.1-flash-live` | Voice | GA | Live voice model |
Per-agent `modelSettings.model` overrides the app model. `thinkingLevel`: DEFAULT, LOW, MEDIUM, HIGH (LOW is faster for voice) applies to the text models; a composite model is exported with no `thinkingLevel`. `temperature` optional.
A real voice agent was moved from `gemini-3.5-flash` to `gemini-composite-v2` in the console and kept working, so `gemini-composite-v2` is the default for voice in this skill.
Composite models: keep the speaking style empty or about a dozen words; use angle-bracket tags `<short pause>`, `<warm>`; add number-reading rules to the global instruction.

## Voice and audio
- `voice.name`: a Cloud Text-to-Speech voice, for example `en-US-Chirp3-HD-Aoede`, `...-Charon`, `...-Kore`, `...-Puck`, `...-Rasalgethi`, `...-Zephyr` (names vary by language; check the console voice list or the Text-to-Speech voices page).
- `speakingRate` 0.25 to 2.0 (1.0 normal). Slower (0.9) helps accessibility and number reading.
- `ambientSound`: coffee_shop, keyboard, keypad, hum, office_1, office_2, office_3, room_1 to room_5, air_conditioner. `ambientVolumeDb` -96 to 16.
- `inactivityTimeout`: seconds string ("10s"). After it the agent re-engages (use the `inactivity_prompt` callback for a fixed phrase).
- `bargeInAwareness` (default true): the agent adapts to the user not having heard everything. `disableBargeIn`: callers cannot interrupt. `disableDtmf`: keypad input off.
- Noise suppression, custom voices and speaking style are console settings (not generated).

## Languages
Chat: any Gemini-supported language. Voice: en-US, en-CA, en-GB, en-AU, en-IN (GA only en-US), fr-CA, fr-FR, de-DE, es-ES, es-US, pt-BR (GA); many others in Preview
(es-MX, it-IT, ja-JP, ko-KR, nl-NL, hi-IN, ...). `languageSettings` adds supported languages and multilingual handling. Write instructions in English.

## Persona and channel
`persona`: CONCISE (short, to the point, good for voice) or CHATTY (extra context and detail). Channels the console can deploy to: web widget, API, Google Telephony Platform,
Twilio, Five9, AudioCodes, CCaaS, WhatsApp, Instagram. Deployment is done in the console; set the matching modality (voice or text) in the deployment settings.

## Logging and privacy
`logging.retentionDays` (default 365). `redaction: true` turns on redaction (optionally with DLP templates configured in the console). `cloudLogging`, BigQuery export and audio recording
(a Cloud Storage bucket) are console settings. `requiredRecordingConsent` exists in the REST reference. State the recording policy to the user.

## Error handling
`errorHandling.strategy`: NONE, FALLBACK_RESPONSE (spoken fallback, `maxFallbackAttempts` retries, optional `customFallbackMessage`), END_SESSION. `escalateOnEnd` marks the session as escalated.
Tool execution mode: PARALLEL (default) or SEQUENTIAL (use when one tool's variable writes must be visible to the next).

## Variables
Names start with a letter or underscore, then letters, digits, underscores. Types STRING, NUMBER, INTEGER, BOOLEAN, OBJECT, ARRAY. Built-in `_session` holds modality and channel.
Typical configuration variables to offer: `company_name`, `agent_name`, `business_hours`, `escalation_phone_message`, `support_email`, `max_attempts`, `recording_notice`.

## Other console-only features worth mentioning
Evaluations and golden tests, versions (snapshot before changes), handoff rules between agents, simulator, monitoring dashboard, custom voices, web widget theme.
