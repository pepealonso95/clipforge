# ClipForge

macOS auto-editor for raw interview footage. Drop one or more video files, write a prompt, and ClipForge:

1. Concatenates the inputs into a single master timeline (re-encodes if codecs/resolutions differ)
2. Extracts audio and runs speech-to-text (whisper.cpp local OR OpenAI Whisper API)
3. Sends the transcript + your prompt + optional sample scripts to **Claude Code** or **Codex** running headlessly
4. The AI selects verbatim clips (no rewriting) and orders them
5. ffmpeg trims each clip and stitches a final `stitched.mp4`

Per requested script you get:
- `script.md` — ordered clips with timestamps and verbatim text
- `stitched.mp4` — final cut
- `clips/01.mp4 … NN.mp4` — individual clips so you can rearrange manually

## Requirements

- macOS 14+ (built/tested on macOS 26 Tahoe / Apple Silicon)
- Xcode 15+
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Homebrew (the bundled `ffmpeg` / `ffprobe` / `whisper-cli` binaries depend on `/opt/homebrew/lib` dylibs)
- `claude` (Claude Code CLI) and/or `codex` (Codex CLI) on your PATH
- Optional: `OPENAI_API_KEY` if you choose Whisper API mode

## Setup

```bash
# 1. Generate the Xcode project
xcodegen

# 2. Open in Xcode
open ClipForge.xcodeproj

# 3. Build & run (⌘R)
```

Or build from CLI:

```bash
xcodebuild -project ClipForge.xcodeproj -scheme ClipForge -configuration Debug build
```

## First-run

1. Open **Settings** (⌘,) → **Whisper** tab → click **Download model** (default: `base.en`, ~140 MB)
2. Settings → **AI CLI** tab → confirm `claude` and/or `codex` paths show ✓
3. Back in the main window:
   - Drop video files
   - Pick output folder
   - Name the project
   - Write a prompt like *"Make 3× 10s Instagram clips, theme: founder lessons"*
   - Click **Generate**

## Output layout

```
<output>/<project>/
  working/
    master.mov       ← concatenated source
    audio.wav
    transcript.json
    segments.json    ← per-source-file → [start,end] in master
    scripts.json     ← raw AI output
  instagram-10s/
    script.md
    stitched.mp4
    clips/01.mp4, 02.mp4, …
  linkedin-1min/
    …
```

## Architecture

- **SwiftUI** native macOS, no third-party Swift packages
- `Process`-based CLI execution wrapped in `BinaryRunner`
- All Foundation: `URLSession`, `JSONDecoder`, `AVKit`
- Bundled binaries in `ClipForge/Resources/Bin/` (folder reference)
- Prompts in `ClipForge/Resources/Prompts/system.md`

See `~/.claude/plans/i-wanted-to-make-abstract-meadow.md` for the original design plan.

## Re-bundling the binaries

`ClipForge/Resources/Bin/{ffmpeg,ffprobe,whisper-cli}` were copied from `/opt/homebrew/bin/`. `whisper-cli` is dynamically linked and its embedded rpath (`@loader_path/../lib`) doesn't resolve inside the app bundle. After copying it from Homebrew, patch + re-sign:

```bash
cp -L /opt/homebrew/bin/whisper-cli ClipForge/Resources/Bin/whisper-cli
install_name_tool -add_rpath /opt/homebrew/lib ClipForge/Resources/Bin/whisper-cli
codesign --force --sign - ClipForge/Resources/Bin/whisper-cli
```

ffmpeg and ffprobe are statically linked enough to work without this step.

## Known limitations

- Bundled binaries are dynamically linked against Homebrew dylibs. The app expects `/opt/homebrew/` to be present at runtime. For true portability you'd need `install_name_tool` rewrites of every dylib + bundling them, or static binaries.
- Frame-accurate cuts re-encode each clip with `libx264 -preset fast -crf 20`. Fast for short interviews, slower for long ones.
- OpenAI Whisper API has a 25 MB upload limit; the app re-encodes to opus 32 kbps mono 16 kHz which fits ~2.5 hours of speech.
