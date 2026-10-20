# Lex

A personal Grammarly for macOS: checks what you type in any app, and refines a sentence the moment you finish it.

## How it works

- **Instant layer:** macOS's own spelling and grammar checker runs on every keystroke, offline, in a few milliseconds.
- **Claude layer:** each sentence goes to Claude Haiku 5.5 the moment you finish it (`.` `!` `?` or a line break), or after a 0.7-second pause on a longer unfinished sentence.
  - **Fast:** Claude answers one line per fix, streamed, and each underline appears as its line arrives (about 1 s). The prompt is cached.
  - **Cached per sentence:** results are stored by sentence text, so editing one sentence never re-checks the others.
  - **No flicker:** while you edit a sentence, its existing underlines stay up until the re-check returns.
  - **Authoritative:** once Claude has reviewed a sentence, the spell checker's flags on names and jargon there are cleared.
- **Refine:** press **⌃1** after you finish a sentence. A panel streams a rewrite from Claude Sonnet 5.5 (changeable in Settings) with the changes highlighted.
  - **↵** replaces the text in place.
  - **⌘1–7** applies Improve, Fix only, Shorter, Clearer, Friendlier, Formal or Direct, stacked on the current version.
  - Type an instruction ("less salesy") and press **↵** to apply it.
  - **Tab** switches scope: sentence, paragraph, or the whole field.
  - **⌘Z** undoes a step, **⌘C** copies, **⌘D** toggles the change view, **esc** closes.
  - With a selection, the shortcut refines the selection. The badge next to the field refines the whole field.

- **Read aloud:** select text anywhere and press **⌥§** to hear it; press again to stop.
  - **Source:** the selection comes through Accessibility, or by copying it (web pages, PDFs, Mail) and then restoring your clipboard. With nothing selected in a text field, Lex reads the paragraph at the cursor. Password fields are never read.
  - **Voices:**
    - **Google Chirp 3 HD** (default): natural voices; the first 1M characters each month are free, then $0.03 per 1,000.
    - **ElevenLabs:** $0.04 per 1,000 characters (Flash) or $0.08 (Multilingual, v3).
    - **macOS voice:** free, offline; the fallback when no cloud voice is set up.
  - **Speed:** text is split at sentence boundaries into small-then-growing chunks (~90 → 240 → 600 → 1,200 characters). The first audio arrives in about 1.1 s, and the next chunk is fetched while the current one plays. The language is detected, so Hebrew text gets a he-IL voice.
  - **Cost:** audio is cached in `~/Library/Caches/dev.lex.app/speech`, so hearing the same text again is free. Settings shows this month's characters.
  - **Mini player:** pause, 10-second back and forward (across chunks, with Google or ElevenLabs voices), speed (0.8×–2×) and stop.

- **Dictation (like Wispr Flow):** hold **Right ⌥**, talk, let go, and the text is typed at your cursor in any app.
  - **Hands-free:** double-tap the key, then tap once more to finish. Esc cancels.
  - **No accidental starts:** a quick tap, or ⌥ used with another key (typing a special character), never dictates. fn 🌐 and Right ⌘ are options in Settings.
  - **Engine:** Auto follows your keyboard.
    - **English keyboard:** Apple's on-device recognizer. Free and private; a short sentence is typed about 0.5 s after release.
    - **Hebrew keyboard:** Google Chirp 3 (Hebrew and English, about $0.016 per minute, through the gcloud sign-in). Long dictation is cut at natural pauses and sent while you talk, so only the last piece is left when you let go.
  - **Tidy-up:** when a transcript has fillers or a spoken correction ("Tuesday, no wait, Wednesday"), or is long, Claude Haiku tidies it, keeping your words and language. If the result strays from the transcript, the raw transcript is used instead. **Words to know** in Settings are passed to both as spelling hints.
  - **Key detection:** the talk key is watched with a listen-only event tap at the head of the queue, so tools like Wispr Flow can't swallow it first. This needs Input Monitoring and Microphone access.

- **Fix all:** press **⌃§** to apply every correction in the field at once.
  - **What's included:** spelling, grammar, punctuation and word choice. Clarity rewrites stay manual. The word you just typed counts too.
  - **Accuracy:** Lex first has Claude check any sentence it hasn't reviewed, waiting up to 2.5 s, so a name only the spell checker flagged isn't "fixed".
  - **How fixes go in:** fixes are applied one by one from the end of the text, so formatting such as @mentions survives. Each waits until the app has taken the previous one, and your clipboard is saved and restored once for the whole batch.

Hover an underline to see the fix and apply it with a click. In message boxes and other small fields, the card opens above or below the field so it never covers your text. A click that lands just as the card appears is ignored, and clicking anywhere else dismisses it.

## Build

```bash
./scripts/build.sh --open
```

The script builds a release binary, wraps it as `Lex.app`, signs it with your Apple Development identity and installs it to `~/Applications`. A stable signature keeps the Accessibility grant and Keychain access across rebuilds.

On first launch:
1. Allow Lex under System Settings › Privacy & Security › Accessibility.
2. Paste an Anthropic API key in Settings (it's stored in your Keychain), then click **Test connection**.
3. For the Google voice, sign in once with gcloud. This works where your organisation blocks API keys; an API key in Settings works too. Lex reads the saved sign-in from `~/.config/gcloud/application_default_credentials.json` and refreshes its own access tokens:
   ```bash
   gcloud auth application-default login
   gcloud auth application-default set-quota-project PROJECT_ID
   gcloud services enable texttospeech.googleapis.com --project PROJECT_ID
   ```
   Then click **Check connection** in Settings › Read aloud. For Hebrew dictation, also enable Speech-to-Text on the project: `gcloud services enable speech.googleapis.com --project PROJECT_ID`.
4. Allow the microphone and Input Monitoring the first time you hold the talk key. Settings › Dictation shows both.

## Notes

- Text you type in checked apps is sent to the Anthropic API with your key. Password fields are never read. Terminals, code editors and password managers are off by default; turn Lex off for any app from the menu-bar icon.
- Edits go through Accessibility in native apps. In Chromium-based apps (Chrome, Dia, Arc, Codex) and Electron apps (Slack, Claude, Linear, Notion), Lex selects the text and pastes, then restores your clipboard, so the editor's own undo and state stay intact. Chromium apps are recognised by their renderer helper app, not by name. Before replacing anything, Lex checks that the selected text is exactly the words it means to fix, and aborts otherwise. Some editors (the Claude app's composer) count selection offsets one or more characters away from the text they report. Lex detects that shift from what actually got selected, corrects the selection, and checks again before editing.
- Finding where a word is on screen varies by app. Lex tries, in order, and remembers per field what worked:
  1. the field's own position API (native apps, Chrome);
  2. the text runs inside rich editors (Claude, Slack);
  3. text markers;
  4. measuring the text against a run's frame (Dia; single-line text only);
  5. hit-testing.
  Positions that cover the whole field are rejected. Where nothing works, the badge still shows the issue count and refine still works.
- Suggestions that would mangle text, such as several words replaced by nothing or by bare punctuation, are dropped.
- Removing a word takes one neighbouring space with it. In paste-based apps, the removal is a Delete keystroke on the verified selection, since editors ignore an empty paste. Placeholders like "(remove)" in Claude's answer count as deletions, and when Claude corrects itself mid-answer, the later fix wins.
- Debug log (timings and counts only, never your text): `defaults write dev.lex.app debugLog -bool true`, then see `~/Library/Logs/Lex.log`.

## Testing

`swift test` runs the core tests. With debug logging on, Lex also accepts commands posted as the distributed notification `dev.lex.debug`:
- `benchmark` and `quality` time and spot-check the models on fixed sample sentences.
- `dump-field`, `apply-first`, `fix-all` and `refine-accept` drive the real fix and refine paths.
- `speak:<text>`, `speak-skip:<seconds>`, `speak-state` and `tts-bench` exercise read-aloud; `tts-bench` times the configured cloud voice without playing anything.
- `stt-test-apple` and `stt-test-google` speak sample sentences (English and Hebrew) with the Google voice, transcribe the audio and tidy it, so dictation can be tested without a person.

The field commands only act on TextEdit, or on text that starts with `LEXTEST`; the pages in `TestPages/` provide such fields for browsers. `compare-rects` logs every positioning method side by side for the current field. Measured on 2026-10-19:

| | First underline or word | Full answer |
|---|---|---|
| Live check, Haiku 5.5 | ~1.0 s | ~1.1 s |
| Refine, Haiku 5.5 | ~0.8 s | ~0.9 s |
| Refine, Sonnet 5.5 | ~0.7 s | ~1.2 s |
| Refine, Opus 5.5 | ~1.0–2.4 s | ~1.8–2.6 s |

## Layout

- `Sources/LexCore`: sentence splitting, mapping Claude's fixes to word-level ranges, word diff, the local checker, prompts, and the Claude client (raw HTTP with SSE streaming).
- `Sources/LexCore/Dictation.swift`: dictation languages and engines, the pause detector that splits long dictation, the Google Speech-to-Text request, and the clean-up guard and spacing rules.
- `Sources/LexCore/Speech.swift`: read-aloud text chunking, language detection, the Google (API key or gcloud sign-in) and ElevenLabs clients, and the audio cache.
- `Sources/Lex`: Accessibility tracking, overlay, suggestion card, refine panel, reader and mini player, the dictation recorder, key tap and HUD, hotkeys, settings.
