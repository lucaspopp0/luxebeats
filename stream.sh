#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/.lib.sh"

if [[ -z "$YOUTUBE_STREAM_KEY" ]]; then
    echo "Missing YOUTUBE_STREAM_KEY"
    exit 1
fi

if [[ -z "$FILES" ]]; then
    echo "Missing FILES"
    exit 1
fi

if [[ -d "$FILES" ]]; then
    lock_dir "$FILES" || exit 1
    trap 'unlock_dir "$FILES"' EXIT
    files=($FILES/*.mp4)
else
    IFS=','
    files=($FILES)
    unset IFS

    for file in "${files[@]}"; do
        if ! [[ -f "$file" ]]; then
            echo "File not found: $file"
            exit 1
        fi
    done
fi

if [[ "${#files[@]}" = "0" ]]; then
    echo "No files to stream"
    exit 2
fi

parse_now () {
    current_time=$(date '+%T')
    current_h=$(echo "$current_time" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+)/\1/p')
    current_h=$(parseint "$current_h")
    current_m=$(echo "$current_time" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+)/\2/p')
    current_m=$(parseint "$current_m")
    current_s=$(echo "$current_time" | sed -nE 's/([0-9]+):([0-9]+):([0-9]+)/\3/p')
    current_s=$(parseint "$current_s")

    current_ms=$(( (current_s * ms_per_s) + (current_m * ms_per_m) + (current_h * ms_per_h) ))
}

parse_offset () {
    parse_now

    json_details='[]'
    start_ms=0
    for i in "${!files[@]}"; do
        file="${files[i]}"
        duration_ff=$(ffprobe "$file" 2>&1 | sed -nE 's/ +Duration: ([:.0-9]+),.+/\1/p' | head -1)
        file_duration_ms=$(parse_duration "$duration_ff")
        end_ms=$(( start_ms + file_duration_ms ))

        json_details=$(jq -nrc \
            --argjson jd "$json_details" \
            --argjson s "$start_ms" \
            --argjson e "$end_ms" \
            '$jd | . += [{ start: $s, end: $e }]')

        start_ms="$end_ms"
    done

    full_duration_ms="$start_ms"
    echo "total duration: $full_duration_ms"

    # calculate current offset in total videos duration
    offset_ms=$(( current_ms % full_duration_ms ))

    offset_index=0
    for i in "${!files[@]}"; do
        start=$(echo "${json_details}" | jq -rc ".[$i].start")
        end=$(echo "${json_details}" | jq -rc ".[$i].end")
        if (( "$start" <= "$offset_ms" )) && (( "$offset_ms" <= "$end" )); then
            offset_ms=$(( offset_ms - start ))
            offset_index="$i"
            break
        fi
    done

    offset=$(duration_from_ms "$offset_ms")
}

run_stream () {
    parse_offset
    echo "Beginning with video index: $offset_index"
    echo "Using start offset: $offset"

    for i in "${!files[@]}"; do
        ss="00:00:00.00"
        if (( "$i" < "$offset_index" )); then
            continue
        elif [[ "$i" == "$offset_index" ]]; then
            ss="$offset"
        fi

        ffmpeg \
            -hide_banner \
            -re \
            -ss "$ss" \
            -i "${files[$i]}" \
            -pix_fmt yuvj420p \
            -x264-params keyint=48:min-keyint=48:scenecut=-1 \
            -b:v 4500k \
            -b:a 128k \
            -ar 44100 \
            -acodec aac \
            -vcodec libx264 \
            -preset ultrafast \
            -tune stillimage \
            -threads 4 \
            -f flv \
            "rtmp://a.rtmp.youtube.com/live2/$YOUTUBE_STREAM_KEY"
    done
}

retries=0
while (( retries < 3 )); do
    run_stream || retries=$(( retries + 1 ))
done
