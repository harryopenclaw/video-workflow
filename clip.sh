#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIPS_JSON="$SCRIPT_DIR/clips.json"
RAW_DIR="$SCRIPT_DIR/raw"
OUTPUT_DIR="$SCRIPT_DIR/output"
WATERMARK="$SCRIPT_DIR/watermark.png"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()  { printf "\033[1;34m[INFO]\033[0m  %s\n" "$*"; }
warn()  { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*"; }
error() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

check_deps() {
    local missing=()
    command -v yt-dlp  >/dev/null 2>&1 || missing+=(yt-dlp)
    command -v ffmpeg  >/dev/null 2>&1 || missing+=(ffmpeg)
    command -v ffprobe >/dev/null 2>&1 || missing+=(ffprobe)
    command -v jq      >/dev/null 2>&1 || missing+=(jq)
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}. Install them and retry."
    fi
}

filesize() {
    local bytes
    if [[ "$(uname)" == "Darwin" ]]; then
        bytes=$(stat -f%z "$1" 2>/dev/null || echo 0)
    else
        bytes=$(stat -c%s "$1" 2>/dev/null || echo 0)
    fi
    echo "$(( bytes / 1024 / 1024 ))MB"
}

# ---------------------------------------------------------------------------
# DOWNLOAD
# ---------------------------------------------------------------------------

do_download() {
    info "=== DOWNLOAD PHASE ==="
    [[ -f "$CLIPS_JSON" ]] || error "clips.json not found at $CLIPS_JSON"
    mkdir -p "$RAW_DIR"

    local count
    count=$(jq '.clips | length' "$CLIPS_JSON")
    info "Found $count clip(s) in clips.json"

    for i in $(seq 0 $(( count - 1 ))); do
        local id url start end note
        id=$(jq -r   ".clips[$i].id"    "$CLIPS_JSON")
        url=$(jq -r  ".clips[$i].url"   "$CLIPS_JSON")
        start=$(jq -r ".clips[$i].start" "$CLIPS_JSON")
        end=$(jq -r  ".clips[$i].end"   "$CLIPS_JSON")
        note=$(jq -r ".clips[$i].note // empty" "$CLIPS_JSON")

        local label="$id"
        [[ -n "$note" ]] && label="$id ($note)"

        # Check cache — skip if already normalised
        if ls "$RAW_DIR/$id".mp4 >/dev/null 2>&1; then
            info "[$label] already cached, skipping"
            continue
        fi

        info "[$label] Downloading $url ($start → $end) …"

        # Download the segment
        if ! yt-dlp \
            --download-sections "*${start}-${end}" \
            --force-keyframes-at-cuts \
            -f "bv*[height<=1080]+ba/b[height<=1080]" \
            --merge-output-format mp4 \
            -o "$RAW_DIR/${id}-raw.%(ext)s" \
            --no-playlist \
            "$url"; then
            warn "[$label] Download FAILED — skipping"
            continue
        fi

        # Find the downloaded file (could be .mp4 or .webm etc.)
        local src
        src=$(ls "$RAW_DIR/${id}-raw"* 2>/dev/null | head -1)
        if [[ -z "$src" ]]; then
            warn "[$label] No file found after download — skipping"
            continue
        fi

        # Normalise to consistent H.264 / AAC / 30fps / 1080p-max mp4
        info "[$label] Normalising to H.264 1080p 30fps …"
        ffmpeg -y -i "$src" \
            -vf "scale='min(1920,iw)':'min(1080,ih)':force_original_aspect_ratio=decrease" \
            -r 30 \
            -c:v libx264 -preset fast -crf 20 \
            -c:a aac -b:a 192k \
            -movflags +faststart \
            "$RAW_DIR/$id.mp4" \
            -loglevel warning

        # Clean up raw download
        rm -f "$src"
        info "[$label] Done"
    done

    info "Download phase complete."
}

# ---------------------------------------------------------------------------
# ASSEMBLE
# ---------------------------------------------------------------------------

do_assemble() {
    info "=== ASSEMBLE PHASE ==="
    mkdir -p "$OUTPUT_DIR"

    local count
    count=$(jq '.clips | length' "$CLIPS_JSON")
    local concat_list="$OUTPUT_DIR/concat.txt"
    > "$concat_list"

    local found=0
    for i in $(seq 0 $(( count - 1 ))); do
        local id
        id=$(jq -r ".clips[$i].id" "$CLIPS_JSON")
        local f="$RAW_DIR/$id.mp4"
        if [[ -f "$f" ]]; then
            echo "file '$f'" >> "$concat_list"
            found=$(( found + 1 ))
        else
            warn "Missing raw/$id.mp4 — skipping in assembly"
        fi
    done

    [[ $found -eq 0 ]] && error "No clips found in raw/. Run download first."

    info "Assembling $found clip(s) …"
    ffmpeg -y -f concat -safe 0 -i "$concat_list" \
        -c copy \
        "$OUTPUT_DIR/assembly.mp4" \
        -loglevel warning

    rm -f "$concat_list"
    info "Assembly complete → output/assembly.mp4 ($(filesize "$OUTPUT_DIR/assembly.mp4"))"
}

# ---------------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------------

do_export() {
    info "=== EXPORT PHASE ==="
    local assembly="$OUTPUT_DIR/assembly.mp4"
    [[ -f "$assembly" ]] || error "output/assembly.mp4 not found. Run assemble first."

    local has_wm=false
    if [[ -f "$WATERMARK" ]]; then
        has_wm=true
    else
        warn "watermark.png not found — exporting without watermark"
    fi

    # --- 16:9 Widescreen ---------------------------------------------------
    info "Exporting 16:9 widescreen (1920×1080) …"

    local filter_16x9="scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black"

    if $has_wm; then
        ffmpeg -y -i "$assembly" -i "$WATERMARK" \
            -filter_complex "
                [0:v]${filter_16x9}[base];
                [1:v]scale=iw*1920*0.15/iw:-1,format=rgba,colorchannelmixer=aa=0.7[wm];
                [base][wm]overlay=W-w-40:H-h-30[out]
            " \
            -map "[out]" -map 0:a? \
            -c:v libx264 -preset fast -crf 20 \
            -c:a aac -b:a 192k \
            -movflags +faststart \
            "$OUTPUT_DIR/final-16x9.mp4" \
            -loglevel warning
    else
        ffmpeg -y -i "$assembly" \
            -vf "$filter_16x9" \
            -c:v libx264 -preset fast -crf 20 \
            -c:a aac -b:a 192k \
            -movflags +faststart \
            "$OUTPUT_DIR/final-16x9.mp4" \
            -loglevel warning
    fi
    info "16:9 done → output/final-16x9.mp4 ($(filesize "$OUTPUT_DIR/final-16x9.mp4"))"

    # --- 9:16 Vertical ------------------------------------------------------
    info "Exporting 9:16 vertical (1080×1920) …"

    if $has_wm; then
        ffmpeg -y -i "$assembly" -i "$WATERMARK" \
            -filter_complex "
                [0:v]split=2[fg][bg];
                [bg]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=20:5[blurred];
                [fg]scale=1080:-2:force_original_aspect_ratio=decrease[scaled];
                [blurred][scaled]overlay=(W-w)/2:(H-h)/2[composed];
                [1:v]scale=iw*1080*0.25/iw:-1,format=rgba,colorchannelmixer=aa=0.7[wm];
                [composed][wm]overlay=(W-w)/2:H-h-50[out]
            " \
            -map "[out]" -map 0:a? \
            -c:v libx264 -preset fast -crf 20 \
            -c:a aac -b:a 192k \
            -movflags +faststart \
            "$OUTPUT_DIR/final-9x16.mp4" \
            -loglevel warning
    else
        ffmpeg -y -i "$assembly" \
            -filter_complex "
                [0:v]split=2[fg][bg];
                [bg]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=20:5[blurred];
                [fg]scale=1080:-2:force_original_aspect_ratio=decrease[scaled];
                [blurred][scaled]overlay=(W-w)/2:(H-h)/2[out]
            " \
            -map "[out]" -map 0:a? \
            -c:v libx264 -preset fast -crf 20 \
            -c:a aac -b:a 192k \
            -movflags +faststart \
            "$OUTPUT_DIR/final-9x16.mp4" \
            -loglevel warning
    fi
    info "9:16 done → output/final-9x16.mp4 ($(filesize "$OUTPUT_DIR/final-9x16.mp4"))"

    info "Export phase complete!"
}

# ---------------------------------------------------------------------------
# CLEAN
# ---------------------------------------------------------------------------

do_clean() {
    info "Cleaning raw/ and output/ …"
    rm -rf "$RAW_DIR" "$OUTPUT_DIR"
    mkdir -p "$RAW_DIR" "$OUTPUT_DIR"
    info "Clean complete."
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

check_deps

case "${1:-all}" in
    download)  do_download ;;
    assemble)  do_assemble ;;
    export)    do_export ;;
    clean)     do_clean ;;
    all)
        do_download
        do_assemble
        do_export
        ;;
    *)
        echo "Usage: $0 [download|assemble|export|clean]"
        echo "  (no argument runs the full pipeline)"
        exit 1
        ;;
esac
