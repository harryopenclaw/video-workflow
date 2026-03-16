# Video Clip Workflow

Downloads specific segments from YouTube videos, assembles them into a compilation, and exports in two formats with optional watermark.

## Outputs

- **16:9 Widescreen** (`output/final-16x9.mp4`) — 1920×1080, for LinkedIn / full-screen
- **9:16 Vertical** (`output/final-9x16.mp4`) — 1080×1920, for Reels / Shorts (blurred background bars fill the frame)

Both include a burned-in watermark logo (bottom-right for 16:9, bottom-center for 9:16).

## Dependencies

- [yt-dlp](https://github.com/yt-dlp/yt-dlp)
- [ffmpeg](https://ffmpeg.org/) (with libx264 and AAC support)
- [jq](https://jqlang.github.io/jq/)

All three must be on your PATH.

## Usage

```bash
# Run the full pipeline: download → assemble → export
./clip.sh

# Run individual phases
./clip.sh download    # Download clips to raw/
./clip.sh assemble    # Concatenate raw/ clips into output/assembly.mp4
./clip.sh export      # Produce final 16:9 and 9:16 from assembly.mp4
./clip.sh clean       # Delete raw/ and output/ to start fresh
```

## clips.json format

```json
{
  "title": "My Compilation",
  "clips": [
    {
      "id": "clip-1",
      "url": "https://www.youtube.com/watch?v=VIDEOID",
      "start": "1:23",
      "end": "1:45",
      "note": "Optional label for this clip"
    }
  ]
}
```

- **id** — unique identifier, used for caching and filenames
- **url** — YouTube video URL
- **start** / **end** — timestamps in `M:SS` or `H:MM:SS` format
- **note** — optional human-readable label (shown in progress output)

Downloaded clips are cached in `raw/` — delete a clip's file to re-download it, or run `./clip.sh clean` to start fresh.

## Watermark

Replace `watermark.png` with your own logo. Recommendations:

- PNG with transparent background
- At least 400px wide for clarity
- The script scales it automatically (15% of video width for 16:9, 25% for 9:16)
- Rendered at 70% opacity

If `watermark.png` is missing, the script exports without a watermark and prints a warning.
