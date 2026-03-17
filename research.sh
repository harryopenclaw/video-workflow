#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESEARCH_DIR="$SCRIPT_DIR/research"
CAPTIONS_DIR="$RESEARCH_DIR/captions"
SLIDES_DIR="$RESEARCH_DIR/slides"
SCORES_DIR="$RESEARCH_DIR/scores"
VIDEOS_FILE="$RESEARCH_DIR/videos.jsonl"
BRIEFING_FILE="$SCRIPT_DIR/briefing.md"
CLIPS_FILE="$SCRIPT_DIR/clips-research.json"

# Defaults
LOOKBACK_DAYS=60
MIN_SCORE=7
TOP_N=20

# ---------------------------------------------------------------------------
# Speakers
# ---------------------------------------------------------------------------

SPEAKERS=(
    "Sam Altman"
    "Satya Nadella"
    "Jensen Huang"
    "Dario Amodei"
    "Sundar Pichai"
    "Mark Zuckerberg"
    "Elon Musk"
    "Yann LeCun"
    "Demis Hassabis"
    "Mustafa Suleyman"
    "Andrew Ng"
    "Fei-Fei Li"
    "Reid Hoffman"
    "Vinod Khosla"
    "Eric Schmidt"
    "Bill Gates"
    "Emad Mostaque"
    "Ilya Sutskever"
    "Greg Brockman"
    "Yoshua Bengio"
    "Geoffrey Hinton"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

info()    { printf "\033[1;34m[%s]\033[0m  %s\n" "$1" "$2"; }
warn()    { printf "\033[1;33m[WARN]\033[0m  %s\n" "$*"; }
error()   { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }
success() { printf "\033[1;32m[DONE]\033[0m  %s\n" "$*"; }

slugify() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-'
}

check_deps() {
    local missing=()
    command -v yt-dlp  >/dev/null 2>&1 || missing+=(yt-dlp)
    command -v ffmpeg  >/dev/null 2>&1 || missing+=(ffmpeg)
    command -v claude  >/dev/null 2>&1 || missing+=(claude)
    command -v jq      >/dev/null 2>&1 || missing+=(jq)
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}. Install them and retry."
    fi
}

ensure_dirs() {
    mkdir -p "$CAPTIONS_DIR" "$SLIDES_DIR" "$SCORES_DIR"
}

date_after() {
    if [[ "$(uname)" == "Darwin" ]]; then
        date -v-"${LOOKBACK_DAYS}d" +%Y%m%d
    else
        date -d "-${LOOKBACK_DAYS} days" +%Y%m%d
    fi
}

today() {
    date +%Y-%m-%d
}

# ---------------------------------------------------------------------------
# PHASE 1: SEARCH
# ---------------------------------------------------------------------------

search_videos() {
    info "SEARCH" "Searching YouTube for AI leader talks (last ${LOOKBACK_DAYS} days)..."
    local after
    after=$(date_after)
    info "SEARCH" "Date filter: after $after"

    local total_found=0

    # Clear previous results but preserve cache
    > "$VIDEOS_FILE"

    for speaker in "${SPEAKERS[@]}"; do
        local slug
        slug=$(slugify "$speaker")
        info "SEARCH" "Searching: $speaker"

        local search_terms=(
            "${speaker} AI 2026"
            "${speaker} AI predictions"
            "${speaker} artificial intelligence"
        )

        for term in "${search_terms[@]}"; do
            # yt-dlp search: get id and title pairs
            local raw_output
            if raw_output=$(yt-dlp "ytsearch5:${term}" \
                --get-id --get-title \
                --dateafter "$after" \
                --no-download \
                --no-warnings \
                --ignore-errors \
                2>/dev/null); then

                # Parse pairs: title on odd lines, id on even lines
                local line_num=0
                local title=""
                while IFS= read -r line; do
                    line_num=$((line_num + 1))
                    if (( line_num % 2 == 1 )); then
                        title="$line"
                    else
                        local vid_id="$line"
                        # Validate it looks like a YouTube ID (11 chars)
                        if [[ ${#vid_id} -ge 8 && ${#vid_id} -le 15 ]]; then
                            printf '%s\n' "$(jq -n \
                                --arg id "$vid_id" \
                                --arg title "$title" \
                                --arg speaker "$speaker" \
                                --arg slug "$slug" \
                                '{id: $id, title: $title, speaker: $speaker, slug: $slug}')" \
                                >> "$VIDEOS_FILE"
                            total_found=$((total_found + 1))
                        fi
                    fi
                done <<< "$raw_output"
            fi

            # Rate limit
            sleep 2
        done
    done

    # Deduplicate by video ID
    if [[ -s "$VIDEOS_FILE" ]]; then
        local before_dedup
        before_dedup=$(wc -l < "$VIDEOS_FILE" | tr -d ' ')
        local deduped
        deduped=$(jq -s 'unique_by(.id)' "$VIDEOS_FILE")
        # Rewrite as JSONL
        echo "$deduped" | jq -c '.[]' > "$VIDEOS_FILE"
        local after_dedup
        after_dedup=$(wc -l < "$VIDEOS_FILE" | tr -d ' ')
        success "Found $before_dedup results, $after_dedup unique videos after dedup"
    else
        warn "No videos found. Try broadening the search or increasing --days."
    fi
}

# ---------------------------------------------------------------------------
# PHASE 2: CAPTIONS
# ---------------------------------------------------------------------------

fetch_captions() {
    info "CAPTION" "Downloading captions for discovered videos..."

    [[ -s "$VIDEOS_FILE" ]] || error "No videos found. Run search phase first."

    local total=0 downloaded=0 cached=0

    while IFS= read -r line; do
        local vid_id
        vid_id=$(echo "$line" | jq -r '.id')
        total=$((total + 1))

        # Check cache
        if ls "$CAPTIONS_DIR/${vid_id}"*.vtt >/dev/null 2>&1; then
            cached=$((cached + 1))
            continue
        fi

        local title
        title=$(echo "$line" | jq -r '.title')
        info "CAPTION" "Fetching: $title ($vid_id)"

        if yt-dlp \
            --write-auto-subs \
            --sub-lang en \
            --skip-download \
            --no-warnings \
            -o "$CAPTIONS_DIR/%(id)s" \
            "https://www.youtube.com/watch?v=${vid_id}" \
            2>/dev/null; then
            downloaded=$((downloaded + 1))
        else
            warn "Failed to get captions for $vid_id"
        fi

        sleep 2
    done < "$VIDEOS_FILE"

    success "Captions: $downloaded new, $cached cached, $total total videos"
}

# ---------------------------------------------------------------------------
# PHASE 3: SCORING
# ---------------------------------------------------------------------------

# Parse VTT into 7-10 second windows
# Output: TAB-delimited lines: start_sec, end_sec, start_fmt, end_fmt, text
parse_vtt_windows() {
    local vtt_file="$1"
    local window_sec=8  # Target ~8 seconds per window

    python3 - "$vtt_file" "$window_sec" <<'PYEOF'
import re, sys

vtt_file = sys.argv[1]
window_sec = int(sys.argv[2])

ts_re = re.compile(
    r'(\d{2}):(\d{2}):(\d{2})\.\d+\s*-->\s*(\d{2}):(\d{2}):(\d{2})\.\d+'
)
tag_re = re.compile(r'<[^>]*>')

# --- Pass 1: extract (start_sec, end_sec, text) cues from VTT ---
cues = []
with open(vtt_file, encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

collecting = False
start = end = None
text_parts = []

def emit():
    if start is not None and text_parts:
        cues.append((start, end, ' '.join(text_parts)))

for raw in lines:
    line = raw.rstrip('\n\r')
    m = ts_re.search(line)
    if m:
        s = int(m.group(1))*3600 + int(m.group(2))*60 + int(m.group(3))
        e = int(m.group(4))*3600 + int(m.group(5))*60 + int(m.group(6))
        if start is None:
            start = s
        end = e
        collecting = True
        continue
    if line == '' or line.startswith('NOTE') or line.startswith('WEBVTT') \
       or line.startswith('Kind:') or line.startswith('Language:'):
        emit()
        start = end = None
        text_parts = []
        collecting = False
        continue
    if collecting:
        cleaned = tag_re.sub('', line)
        if cleaned.strip():
            text_parts.append(cleaned.strip())

emit()

# --- Pass 2: group cues into ~window_sec windows ---
buf_start = buf_end = -1
buf_text = ''

def flush():
    if buf_start >= 0 and buf_text:
        sm, ss = divmod(buf_start, 60)
        em, es = divmod(buf_end, 60)
        print(f'{buf_start}\t{buf_end}\t{sm}:{ss:02d}\t{em}:{es:02d}\t{buf_text}')

for s, e, t in cues:
    if buf_start < 0:
        buf_start, buf_end, buf_text = s, e, t
        continue
    if e - buf_start <= window_sec + 2:
        buf_end = e
        buf_text += ' ' + t
    else:
        flush()
        buf_start, buf_end, buf_text = s, e, t

flush()
PYEOF
}

score_quotes() {
    info "SCORE" "Scoring caption windows with Claude CLI (batched per video)..."

    [[ -s "$VIDEOS_FILE" ]] || error "No videos found. Run search phase first."

    local MAX_WINDOWS=50

    # Collect all scored results
    local all_scores_file="$SCORES_DIR/all_scores.jsonl"
    > "$all_scores_file"

    local vid_count=0 total_windows=0 scored_count=0

    while IFS= read -r video_line; do
        local vid_id speaker title slug
        vid_id=$(echo "$video_line" | jq -r '.id')
        speaker=$(echo "$video_line" | jq -r '.speaker')
        title=$(echo "$video_line" | jq -r '.title')
        slug=$(echo "$video_line" | jq -r '.slug')

        # Find VTT file
        local vtt_file
        vtt_file=$(ls "$CAPTIONS_DIR/${vid_id}"*.vtt 2>/dev/null | head -1)
        [[ -n "$vtt_file" ]] || continue

        # Check for cached scores
        local score_cache="$SCORES_DIR/${vid_id}.jsonl"
        if [[ -f "$score_cache" && -s "$score_cache" ]]; then
            cat "$score_cache" >> "$all_scores_file"
            info "SCORE" "  (cached) $speaker — $title"
            vid_count=$((vid_count + 1))
            continue
        fi

        # Parse all windows from VTT into parallel arrays
        local -a w_start_sec=() w_end_sec=() w_start_fmt=() w_end_fmt=() w_text=()
        while IFS=$'\t' read -r ss es sf ef tx; do
            # Skip windows with fewer than 8 words
            local wc
            wc=$(echo "$tx" | wc -w | tr -d ' ')
            [[ $wc -ge 8 ]] || continue
            w_start_sec+=("$ss")
            w_end_sec+=("$es")
            w_start_fmt+=("$sf")
            w_end_fmt+=("$ef")
            w_text+=("$tx")
        done < <(parse_vtt_windows "$vtt_file")

        local num_windows=${#w_text[@]}

        # Skip videos with fewer than 15 windows (~2 min of content)
        if [[ $num_windows -lt 15 ]]; then
            info "SCORE" "  Skipping $title — only $num_windows windows (< 2 min)"
            continue
        fi

        # Cap at MAX_WINDOWS (take evenly spaced sample if over limit)
        local -a idx=()
        if [[ $num_windows -le $MAX_WINDOWS ]]; then
            for (( i=0; i<num_windows; i++ )); do idx+=("$i"); done
        else
            # Evenly sample MAX_WINDOWS indices
            for (( i=0; i<MAX_WINDOWS; i++ )); do
                idx+=("$(( i * num_windows / MAX_WINDOWS ))")
            done
        fi

        local use_count=${#idx[@]}
        total_windows=$((total_windows + use_count))
        vid_count=$((vid_count + 1))
        info "SCORE" "Processing: $speaker — $title ($use_count windows)"

        # Build numbered window list for the prompt
        local prompt_windows=""
        local win_num=0
        for i in "${idx[@]}"; do
            win_num=$((win_num + 1))
            prompt_windows+="Window ${win_num} [${w_start_fmt[$i]}-${w_end_fmt[$i]}]: ${w_text[$i]}
"
        done

        local prompt="Here are ${use_count} caption windows from ${speaker} speaking at \"${title}\".

Score each window 1-10 for poignancy as an AI prediction. Consider: boldness, specificity, quotability, novelty. Only score highly if it contains a genuine prediction or bold claim about AI's future.

Return ONLY a JSON array, no markdown fences, no extra text:
[{\"window\": 1, \"score\": N, \"reason\": \"brief reason\", \"is_prediction\": true/false}, ...]

${prompt_windows}"

        # Single Claude call for all windows in this video
        local result
        if result=$(echo "$prompt" | gtimeout 120 claude --permission-mode bypassPermissions --print 2>/dev/null); then
            # Extract JSON array from response (strip markdown fences if present)
            local json_array
            json_array=$(echo "$result" | sed 's/```json//g; s/```//g' | tr '\n' ' ' | grep -o '\[.*\]' | head -1)

            if [[ -n "$json_array" ]] && echo "$json_array" | jq '.' >/dev/null 2>&1; then
                > "$score_cache"

                # Process each scored window
                local arr_len
                arr_len=$(echo "$json_array" | jq 'length')

                for (( j=0; j<arr_len; j++ )); do
                    local w_num w_score w_reason w_pred
                    w_num=$(echo "$json_array" | jq -r ".[$j].window // 0")
                    w_score=$(echo "$json_array" | jq -r ".[$j].score // 0")
                    w_reason=$(echo "$json_array" | jq -r ".[$j].reason // \"\"")
                    w_pred=$(echo "$json_array" | jq -r ".[$j].is_prediction // false")

                    # Filter: must be a prediction and meet minimum score
                    if [[ "$w_pred" == "true" && "$w_score" -ge "$MIN_SCORE" ]] 2>/dev/null; then
                        # Map window number back to original index
                        local orig_idx
                        if [[ $w_num -ge 1 && $w_num -le $use_count ]]; then
                            orig_idx=${idx[$((w_num - 1))]}
                        else
                            continue
                        fi

                        scored_count=$((scored_count + 1))
                        local entry
                        entry=$(jq -n \
                            --arg vid_id "$vid_id" \
                            --arg speaker "$speaker" \
                            --arg title "$title" \
                            --arg slug "$slug" \
                            --arg text "${w_text[$orig_idx]}" \
                            --argjson score "$w_score" \
                            --arg reason "$w_reason" \
                            --arg start_fmt "${w_start_fmt[$orig_idx]}" \
                            --arg end_fmt "${w_end_fmt[$orig_idx]}" \
                            --argjson start_sec "${w_start_sec[$orig_idx]}" \
                            --argjson end_sec "${w_end_sec[$orig_idx]}" \
                            '{
                                vid_id: $vid_id,
                                speaker: $speaker,
                                title: $title,
                                slug: $slug,
                                text: $text,
                                score: $score,
                                reason: $reason,
                                start: $start_fmt,
                                end: $end_fmt,
                                start_sec: $start_sec,
                                end_sec: $end_sec
                            }')
                        echo "$entry" >> "$score_cache"
                        echo "$entry" >> "$all_scores_file"
                        info "SCORE" "  [${w_score}/10] ${w_text[$orig_idx]:0:80}..."
                    fi
                done

                # If no matches, still create the cache file to mark as processed
                [[ -f "$score_cache" ]] || > "$score_cache"
            else
                warn "Failed to parse Claude response for $vid_id"
            fi
        else
            warn "Claude CLI failed/timed out for $vid_id — skipping"
        fi

    done < "$VIDEOS_FILE"

    # Sort by score descending and keep top N
    if [[ -s "$all_scores_file" ]]; then
        local sorted
        sorted=$(jq -s 'sort_by(-.score) | .[:'"$TOP_N"']' "$all_scores_file")
        echo "$sorted" | jq -c '.[]' > "$all_scores_file"
        local final_count
        final_count=$(wc -l < "$all_scores_file" | tr -d ' ')
        success "Scored $total_windows windows from $vid_count videos. Found $scored_count hits, top $final_count kept (score >= $MIN_SCORE)."
    else
        warn "No quotes scored above threshold ($MIN_SCORE)."
    fi
}

# ---------------------------------------------------------------------------
# PHASE 4: OUTPUT
# ---------------------------------------------------------------------------

generate_briefing() {
    info "OUTPUT" "Generating briefing.md..."

    local scores_file="$SCORES_DIR/all_scores.jsonl"
    [[ -s "$scores_file" ]] || error "No scored quotes. Run score phase first."

    local generated
    generated=$(today)

    {
        echo "# AI Insights Research Briefing"
        echo "Generated: ${generated}"
        echo "Lookback: ${LOOKBACK_DAYS} days | Min score: ${MIN_SCORE}/10"
        echo ""
        echo "## Top Quotes (scored ${MIN_SCORE}+/10)"
        echo ""

        local rank=0
        while IFS= read -r line; do
            rank=$((rank + 1))
            local speaker score text title vid_id start end start_sec reason
            speaker=$(echo "$line" | jq -r '.speaker')
            score=$(echo "$line" | jq -r '.score')
            text=$(echo "$line" | jq -r '.text')
            title=$(echo "$line" | jq -r '.title')
            vid_id=$(echo "$line" | jq -r '.vid_id')
            start=$(echo "$line" | jq -r '.start')
            end=$(echo "$line" | jq -r '.end')
            start_sec=$(echo "$line" | jq -r '.start_sec')
            reason=$(echo "$line" | jq -r '.reason')

            echo "### ${rank}. ${speaker} — ${score}/10"
            echo "> \"${text}\""
            echo ""
            echo "Source: ${title}"
            echo "Timestamp: ${start}–${end}"
            echo "URL: https://youtube.com/watch?v=${vid_id}&t=${start_sec}"
            echo "Why it's good: ${reason}"
            echo ""
        done < "$scores_file"
    } > "$BRIEFING_FILE"

    success "Briefing written to briefing.md"
}

generate_clips_json() {
    info "OUTPUT" "Generating clips-research.json..."

    local scores_file="$SCORES_DIR/all_scores.jsonl"
    [[ -s "$scores_file" ]] || error "No scored quotes. Run score phase first."

    local generated
    generated=$(today)

    # Build clips array
    local clips="[]"
    local n=0

    while IFS= read -r line; do
        n=$((n + 1))
        local slug vid_id start end speaker text score
        slug=$(echo "$line" | jq -r '.slug')
        vid_id=$(echo "$line" | jq -r '.vid_id')
        start=$(echo "$line" | jq -r '.start')
        end=$(echo "$line" | jq -r '.end')
        speaker=$(echo "$line" | jq -r '.speaker')
        text=$(echo "$line" | jq -r '.text')
        score=$(echo "$line" | jq -r '.score')

        # Truncate note to 120 chars
        local note="${text:0:120}"

        clips=$(echo "$clips" | jq \
            --arg id "clip-${slug}-${n}" \
            --arg url "https://youtube.com/watch?v=${vid_id}" \
            --arg start "$start" \
            --arg end "$end" \
            --arg speaker "$speaker" \
            --arg note "$note" \
            --argjson score "$score" \
            '. + [{
                id: $id,
                url: $url,
                start: $start,
                end: $end,
                speaker: $speaker,
                note: $note,
                score: $score
            }]')
    done < "$scores_file"

    jq -n \
        --arg title "AI Research Compilation - ${generated}" \
        --argjson clips "$clips" \
        '{title: $title, clips: $clips}' > "$CLIPS_FILE"

    success "Clips written to clips-research.json ($(echo "$clips" | jq 'length') clips)"
}

# ---------------------------------------------------------------------------
# SLIDE GENERATION
# ---------------------------------------------------------------------------

make_slide() {
    local id="$1"
    local speaker="$2"
    local quote_text="$3"
    local output_file="$SLIDES_DIR/${id}.mp4"

    if [[ -f "$output_file" ]]; then
        info "SLIDE" "  Cached: $id"
        return 0
    fi

    info "SLIDE" "  Generating slide: $speaker"

    # Escape special characters for ffmpeg drawtext
    local escaped_quote
    escaped_quote=$(printf '%s' "$quote_text" | sed "s/'/\\\\\\\\'/g" | sed 's/:/\\:/g' | sed 's/%/%%/g')
    local escaped_speaker
    escaped_speaker=$(printf '%s' "$speaker" | sed "s/'/\\\\\\\\'/g" | sed 's/:/\\:/g')

    # Word-wrap: insert newlines roughly every 50 chars at word boundaries
    local wrapped_quote
    wrapped_quote=$(echo "$escaped_quote" | fold -s -w 50 | head -8 | tr '\n' '|' | sed 's/|$//')
    # Replace | with actual newline for drawtext
    wrapped_quote=$(echo "$wrapped_quote" | sed 's/|/\n/g')

    ffmpeg -y \
        -f lavfi -i "color=c=0x0f0f1a:s=1920x1080:d=7,format=yuv420p" \
        -f lavfi -i "anullsrc=r=44100:cl=stereo" \
        -filter_complex "
            [0:v]drawbox=x=0:y=0:w=1920:h=1080:c=0x1a1a2e@0.5:t=fill,
            drawtext=text='${escaped_speaker}':
                fontcolor=white:fontsize=64:
                x=(w-text_w)/2:y=h*0.2:
                font=Arial,
            drawtext=text='${wrapped_quote}':
                fontcolor=white:fontsize=36:
                x=(w-text_w)/2:y=(h-text_h)/2:
                font=Arial:line_spacing=16,
            drawtext=text='immediac.com':
                fontcolor=0x888888:fontsize=24:
                x=w-text_w-40:y=h-th-30:
                font=Arial,
            fade=t=in:st=0:d=0.5,
            fade=t=out:st=6.5:d=0.5[outv]
        " \
        -map "[outv]" -map 1:a \
        -c:v libx264 -preset fast -crf 20 \
        -c:a aac -b:a 128k \
        -shortest \
        -movflags +faststart \
        "$output_file" \
        -loglevel warning

    if [[ -f "$output_file" ]]; then
        info "SLIDE" "  Created: $output_file"
    else
        warn "Slide generation failed for $id"
    fi
}

generate_slides() {
    info "SLIDE" "Generating slides for high-scoring quotes..."

    local scores_file="$SCORES_DIR/all_scores.jsonl"
    [[ -s "$scores_file" ]] || error "No scored quotes. Run score phase first."

    local n=0 generated=0

    while IFS= read -r line; do
        n=$((n + 1))
        local score slug speaker text
        score=$(echo "$line" | jq -r '.score')
        slug=$(echo "$line" | jq -r '.slug')
        speaker=$(echo "$line" | jq -r '.speaker')
        text=$(echo "$line" | jq -r '.text')

        # Generate slides for score >= 8
        if [[ "$score" -ge 8 ]] 2>/dev/null; then
            local slide_id="slide-${slug}-${n}"
            make_slide "$slide_id" "$speaker" "$text"
            generated=$((generated + 1))

            # Add slide entry to clips-research.json if it exists
            if [[ -f "$CLIPS_FILE" ]]; then
                local updated
                updated=$(jq \
                    --arg id "$slide_id" \
                    --arg speaker "$speaker" \
                    --arg note "${text:0:120}" \
                    --argjson score "$score" \
                    --arg file "research/slides/${slide_id}.mp4" \
                    '.clips += [{
                        id: $id,
                        speaker: $speaker,
                        note: $note,
                        score: $score,
                        type: "slide",
                        file: $file
                    }]' "$CLIPS_FILE")
                echo "$updated" | jq '.' > "$CLIPS_FILE"
            fi
        fi
    done < "$scores_file"

    success "Generated $generated slide(s)"
}

# ---------------------------------------------------------------------------
# FULL PIPELINE
# ---------------------------------------------------------------------------

run_all() {
    info "PIPELINE" "Starting full research pipeline"
    echo "  Lookback: ${LOOKBACK_DAYS} days"
    echo "  Min score: ${MIN_SCORE}/10"
    echo "  Speakers: ${#SPEAKERS[@]}"
    echo ""

    search_videos
    echo ""
    fetch_captions
    echo ""
    score_quotes
    echo ""
    generate_briefing
    generate_clips_json
    generate_slides

    echo ""
    success "Research pipeline complete!"
    echo "  Briefing:  $BRIEFING_FILE"
    echo "  Clips:     $CLIPS_FILE"
    echo "  Slides:    $SLIDES_DIR/"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $0 [command] [options]

Commands:
  (none)     Run full pipeline
  search     Search phase only
  captions   Download captions only
  score      Re-score existing captions
  output     Regenerate briefing + clips JSON
  slides     Regenerate slides only

Options:
  --days N       Lookback period in days (default: 60)
  --min-score N  Minimum poignancy score (default: 7)
  --help         Show this help
EOF
}

# Parse options
COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            LOOKBACK_DAYS="$2"
            shift 2
            ;;
        --min-score)
            MIN_SCORE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        search|captions|score|output|slides)
            COMMAND="$1"
            shift
            ;;
        *)
            error "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

check_deps
ensure_dirs

case "${COMMAND:-all}" in
    search)   search_videos ;;
    captions) fetch_captions ;;
    score)    score_quotes ;;
    output)
        generate_briefing
        generate_clips_json
        ;;
    slides)   generate_slides ;;
    all)      run_all ;;
esac
