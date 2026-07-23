#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error
import shutil

GROQ_BASE = "https://api.groq.com/openai/v1/audio"
CHUNK_DURATION = 600  # 10 minutes per chunk ~21MB FLAC, under 25MB limit


def iso_639_1(lang: str) -> str:
    mapping = {
        "japanese": "ja", "english": "en", "korean": "ko", "chinese": "zh",
        "spanish": "es", "french": "fr", "german": "de", "italian": "it",
        "portuguese": "pt", "russian": "ru", "arabic": "ar", "hindi": "hi",
        "thai": "th", "vietnamese": "vi", "indonesian": "id", "dutch": "nl",
        "polish": "pl", "turkish": "tr", "czech": "cs", "swedish": "sv",
        "danish": "da", "finnish": "fi", "norwegian": "no", "hungarian": "hu",
        "romanian": "ro", "ukrainian": "uk", "greek": "el",
    }
    return mapping.get(lang.lower(), lang[:2])


def to_srt_time(seconds: float) -> str:
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds - int(seconds)) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def segments_to_srt(segments: list) -> str:
    lines = []
    for i, seg in enumerate(segments, 1):
        start = to_srt_time(seg["start"])
        end = to_srt_time(seg["end"])
        text = seg["text"].strip()
        lines.append(str(i))
        lines.append(f"{start} --> {end}")
        lines.append(text)
        lines.append("")
    return "\n".join(lines)


def groq_request(endpoint: str, audio_path: str, api_key: str, model: str) -> dict:
    url = f"{GROQ_BASE}/{endpoint}"
    boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"

    def encode_multipart(field_name, filename, data):
        part = []
        part.append(f"--{boundary}".encode("utf-8"))
        part.append(f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"'.encode("utf-8"))
        part.append("Content-Type: audio/flac".encode("utf-8"))
        part.append(b"")
        part.append(data)
        return b"\r\n".join(part)

    def encode_field(field_name, value):
        part = []
        part.append(f"--{boundary}".encode("utf-8"))
        part.append(f'Content-Disposition: form-data; name="{field_name}"'.encode("utf-8"))
        part.append(b"")
        part.append(value.encode("utf-8"))
        return b"\r\n".join(part)

    with open(audio_path, "rb") as f:
        audio_data = f.read()

    body_parts = []
    body_parts.append(encode_multipart("file", os.path.basename(audio_path), audio_data))
    body_parts.append(encode_field("model", model))
    body_parts.append(encode_field("response_format", "verbose_json"))
    body_parts.append(f"--{boundary}--".encode("utf-8"))

    body = b"\r\n".join(body_parts)

    req = urllib.request.Request(url, data=body)
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("User-Agent", "PostmanRuntime/7.37.3")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")

    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.read().decode()}"}
    except Exception as e:
        return {"error": str(e)}


def extract_audio(video_path: str, output_path: str):
    cmd = [
        "ffmpeg", "-y", "-i", video_path,
        "-vn", "-ar", "16000", "-ac", "1", "-map", "0:a",
        "-c:a", "flac", "-f", "flac", output_path,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        if not os.path.exists(output_path) or os.path.getsize(output_path) == 0:
            print(f"ffmpeg error: {result.stderr}", file=sys.stderr)
            sys.exit(1)


def get_duration(audio_path: str) -> float:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "csv=p=0", audio_path],
        capture_output=True, text=True
    )
    return float(result.stdout.strip())


def split_audio(audio_path: str, chunk_dir: str, chunk_duration: int) -> list:
    base = os.path.splitext(os.path.basename(audio_path))[0]
    pattern = os.path.join(chunk_dir, f"{base}_chunk_%03d.flac")

    cmd = [
        "ffmpeg", "-y", "-i", audio_path,
        "-f", "segment", "-segment_time", str(chunk_duration),
        "-c:a", "flac", pattern,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ffmpeg split error: {result.stderr}", file=sys.stderr)
        sys.exit(1)
    chunks = sorted(
        [os.path.join(chunk_dir, f) for f in os.listdir(chunk_dir) if f.endswith(".flac")]
    )
    return chunks


def main():
    parser = argparse.ArgumentParser(description="Transcribe video to SRT subtitles")
    parser.add_argument("video_path", help="Path to the video file")
    parser.add_argument("--api-key", help="Groq API key (default: read from /run/secrets/nanoclaw_groq_api_key)")
    parser.add_argument("--model", default="whisper-large-v3-turbo", help="Whisper model for transcription")
    parser.add_argument("--translation-model", default="whisper-large-v3", help="Model for translation (must support translation endpoint)")
    parser.add_argument("--chunk-duration", type=int, default=CHUNK_DURATION, help="Duration of each audio chunk in seconds")
    args = parser.parse_args()

    api_key = args.api_key
    if not api_key:
        try:
            with open("/run/secrets/nanoclaw_groq_api_key") as f:
                api_key = f.read().strip()
        except FileNotFoundError:
            print("Error: No API key provided and /run/secrets/nanoclaw_groq_api_key not found", file=sys.stderr)
            sys.exit(1)

    video_path = args.video_path
    if not os.path.exists(video_path):
        print(f"Error: Video file not found: {video_path}", file=sys.stderr)
        sys.exit(1)

    tmpdir = tempfile.mkdtemp()
    try:
        audio_path = os.path.join(tmpdir, "audio.flac")
        print(f"Extracting audio from {video_path}...", file=sys.stderr)
        extract_audio(video_path, audio_path)

        duration = get_duration(audio_path)
        print(f"Audio duration: {duration:.0f}s ({duration/60:.1f} min)", file=sys.stderr)

        if duration <= args.chunk_duration:
            chunks = [audio_path]
            offsets = [0.0]
        else:
            print(f"Splitting audio into {args.chunk_duration}s chunks...", file=sys.stderr)
            chunk_dir = os.path.join(tmpdir, "chunks")
            os.makedirs(chunk_dir, exist_ok=True)
            raw_chunks = split_audio(audio_path, chunk_dir, args.chunk_duration)
            chunks = []
            offsets = []
            for i, ch in enumerate(raw_chunks):
                chunks.append(ch)
                offsets.append(i * args.chunk_duration)
            print(f"Split into {len(chunks)} chunks", file=sys.stderr)

        all_segments = []
        first_language = None
        print("Transcribing audio...", file=sys.stderr)
        for i, (chunk, offset) in enumerate(zip(chunks, offsets)):
            print(f"  Transcribing chunk {i+1}/{len(chunks)}...", file=sys.stderr)
            result = groq_request("transcriptions", chunk, api_key, args.model)
            if "error" in result:
                print(f"API error: {result['error']}", file=sys.stderr)
                sys.exit(1)
            if first_language is None:
                first_language = result.get("language", "unknown")
            segments = result.get("segments", [])
            for seg in segments:
                seg["start"] += offset
                seg["end"] += offset
            all_segments.extend(segments)

        language = first_language or "unknown"
        lang_code = iso_639_1(language)

        base = os.path.splitext(video_path)[0]

        srt_path = f"{base}.{lang_code}.srt"
        srt_content = segments_to_srt(all_segments)
        with open(srt_path, "w", encoding="utf-8") as f:
            f.write(srt_content)
        print(f"Saved: {srt_path}", file=sys.stderr)

        if lang_code != "en":
            print("Translating to English...", file=sys.stderr)
            all_en_segments = []
            for i, (chunk, offset) in enumerate(zip(chunks, offsets)):
                print(f"  Translating chunk {i+1}/{len(chunks)}...", file=sys.stderr)
                result = groq_request("translations", chunk, api_key, args.translation_model)
                if "error" in result:
                    print(f"Translation API error: {result['error']}", file=sys.stderr)
                    sys.exit(1)
                segments = result.get("segments", [])
                for seg in segments:
                    seg["start"] += offset
                    seg["end"] += offset
                all_en_segments.extend(segments)

            en_srt_path = f"{base}.en.srt"
            en_srt_content = segments_to_srt(all_en_segments)
            with open(en_srt_path, "w", encoding="utf-8") as f:
                f.write(en_srt_content)
            print(f"Saved: {en_srt_path}", file=sys.stderr)
        else:
            print("Language is English, skipping translation.", file=sys.stderr)

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print("Done.", file=sys.stderr)


if __name__ == "__main__":
    main()