# Quill

A personal Grammarly for macOS: checks what you type in any app, and refines a sentence the moment you finish it.

## How it works

- **Instant layer:** macOS's own spelling and grammar checker runs on every keystroke, offline, in a few milliseconds.
- **Claude layer:** each sentence goes to Claude Haiku 5.5 the moment you finish it (`.` `!` `?` or a line break), or after a 0.7-second pause on a longer unfinished sentence.
  - **Fast:** Claude answers one line per fix, streamed, and each underline appears as its line arrives (about 1 s). The prompt is cached.
  - **Cached per sentence:** results are stored by sentence text, so editing one sentence never re-checks the others.
  - **No flicker:** while you edit a sentence, its existing underlines stay up until the re-check returns.
  - **Authoritative:** once Claude has reviewed a sentence, the spell checker's flags on names and jargon there are cleared.
- **Refine:** press **⌃⌥R** after you finish a sentence. A panel streams a rewrite from Claude Sonnet 5.5 (changeable in Settings) with the changes highlighted.
  - **↵** replaces the text in place.
  - **⌘1–7** applies Improve, Fix only, Shorter, Clearer, Friendlier, Formal or Direct, stacked on the current version.
  - Type an instruction ("less salesy") and press **↵** to apply it.
  - **Tab** switches scope: sentence, paragraph, or the whole field.
  - **⌘Z** undoes a step, **⌘C** copies, **⌘D** toggles the change view, **esc** closes.
  - With a selection, the shortcut refines the selection. The badge next to the field refines the whole field.

Hover an underline to see the fix and apply it with a click. In message boxes and other small fields, the card opens above or below the field so it never covers your text. A click that lands just as the card appears is ignored, and clicking anywhere else dismisses it.

## Build

```bash
./scripts/build.sh --open
```

The script builds a release binary, wraps it as `Quill.app`, signs it with your Apple Development identity and installs it to `~/Applications`. A stable signature keeps the Accessibility grant and Keychain access across rebuilds.

On first launch:
1. Allow Quill under System Settings › Privacy & Security › Accessibility.
2. Paste an Anthropic API key in Settings (it's stored in your Keychain), then click **Test connection**.

## Notes

- Text you type in checked apps is sent to the Anthropic API with your key. Password fields are never read. Terminals, code editors and password managers are off by default; turn Quill off for any app from the menu-bar icon.
- Edits go through Accessibility in native apps. In Chromium-based apps (Chrome, Dia, Arc, Codex) and Electron apps (Slack, Claude, Linear, Notion), Quill selects the text and pastes, then restores your clipboard, so the editor's own undo and state stay intact. Chromium apps are recognised by their renderer helper app, not by name. Before replacing anything, Quill checks that the selected text is exactly the words it means to fix, and aborts otherwise.
- Finding where a word is on screen varies by app. Quill tries, in order, and remembers per field what worked:
  1. the field's own position API (native apps, Chrome);
  2. the text runs inside rich editors (Claude, Slack);
  3. text markers;
  4. measuring the text against a run's frame (Dia; single-line text only);
  5. hit-testing.
  Positions that cover the whole field are rejected. Where nothing works, the badge still shows the issue count and refine still works.
- Suggestions that would mangle text, such as several words replaced by nothing or by bare punctuation, are dropped.
- Removing a word takes one neighbouring space with it. In paste-based apps, the removal is a Delete keystroke on the verified selection, since editors ignore an empty paste. Placeholders like "(remove)" in Claude's answer count as deletions, and when Claude corrects itself mid-answer, the later fix wins.
- Debug log (timings and counts only, never your text): `defaults write dev.quill.app debugLog -bool true`, then see `~/Library/Logs/Quill.log`.

## Testing

`swift test` runs the core tests. With debug logging on, Quill also accepts commands posted as the distributed notification `dev.quill.debug`:
- `benchmark` and `quality` time and spot-check the models on fixed sample sentences.
- `dump-field`, `apply-first` and `refine-accept` drive the real fix and refine paths.

The field commands only act on TextEdit, or on text that starts with `QUILLTEST`; the pages in `TestPages/` provide such fields for browsers. `compare-rects` logs every positioning method side by side for the current field. Measured on 2026-10-19:

| | First underline or word | Full answer |
|---|---|---|
| Live check, Haiku 5.5 | ~1.0 s | ~1.1 s |
| Refine, Haiku 5.5 | ~0.8 s | ~0.9 s |
| Refine, Sonnet 5.5 | ~0.7 s | ~1.2 s |
| Refine, Opus 5.5 | ~1.0–2.4 s | ~1.8–2.6 s |

## Layout

- `Sources/QuillCore`: sentence splitting, mapping Claude's fixes to word-level ranges, word diff, the local checker, prompts, and the Claude client (raw HTTP with SSE streaming).
- `Sources/Quill`: Accessibility tracking, overlay, suggestion card, refine panel, hotkey, settings.
