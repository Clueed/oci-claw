---
name: create-video-subtitles
description: Transcribe video files into SRT subtitle files using Groq's Whisper API. Extracts audio (16kHz mono MP3), sends to Groq for transcription and translation, saves SRT files in the detected language and English. Use when the user asks to transcribe a video or create subtitles.
---

# Create Video Subtitles Skill

Transcribes video files into SRT subtitle files using Groq's Whisper API.

> `<skill-path>` below refers to this skill's absolute directory path (where this SKILL.md lives).

## Resolving the input

The user may give you a file path directly, or they may give you the name of a
**scene** in the Stash library (e.g. "Daniele Orth") instead of a path.

- If the input already looks like an existing file path, use it as-is.
- Otherwise, treat it as a search term and look it up via the Stash API
  (`http://localhost:9999/graphql`, see the **stash** skill) to find the file:

  ```bash
  curl -s -X POST http://localhost:9999/graphql -H "Content-Type: application/json" \
    -d '{"query":"{ findScenes(filter: { q: \"SEARCH_TERM\" }) { scenes { id title files { path } } } }"}'
  ```

  Use the returned `files[].path` as the video path for transcription. If
  multiple scenes match, ask the user which one they mean before proceeding.

## Usage

```bash
nix shell nixpkgs#ffmpeg-full nixpkgs#python3 --command python3 <skill-path>/scripts/transcribe.py "<path/to/video.mp4>"
```

The script reads the API key from `/run/secrets/nanoclaw_groq_api_key` automatically.

## Output Files

SRT files are placed in the same directory as the video file:

| File | Contents |
|------|----------|
| `Video Name.ll.srt` | Original language transcription (ISO 639-1 code) |
| `Video Name.en.srt` | English translation |

## How It Works

1. Extracts audio via ffmpeg (16kHz mono MP3 @ 64kbps)
2. Sends to Groq `/v1/audio/transcriptions` with `whisper-large-v3` — detects language, transcribes, returns per-segment timestamps as SRT
3. If detected language is not English, sends to `/v1/audio/translations` with `whisper-large-v3` and saves English SRT
4. If already English, only creates `.en.srt`

## Dependencies

- `ffmpeg-full` (via nixpkgs)
- `python3` (via nixpkgs)
- Groq API key at `/run/secrets/nanoclaw_groq_api_key`