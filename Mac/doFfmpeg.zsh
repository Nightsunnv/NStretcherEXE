#!/usr/bin/env zsh
# macOS zsh script

set -o pipefail
unsetopt nomatch 2>/dev/null
setopt null_glob
setopt extended_glob
zmodload zsh/datetime

# ============ 参数与默认值 ============
PITCH_RATIO=1.12246       
TIME_SCALE=0.993          
OUT_DIR="converted"      
OUTPUT_FORMAT="float32"   

print_usage() {
  cat <<EOF
用法: $0 [-p PitchRatio] [-t TimeScale] [-o OutDir] [-f OutputFormat]
参数:
  -p  变调倍率 (默认: ${PITCH_RATIO})
  -t  时间比例 (默认: ${TIME_SCALE})
  -o  输出目录 (默认: ${OUT_DIR})
  -f  输出格式: 16bit|24bit|32bit|float32|float64|flac (默认: ${OUTPUT_FORMAT})

示例:
  $0 -p 1.12246 -t 0.993 -o converted -f float32
EOF
}

while getopts ":p:t:o:f:h" opt; do
  case "$opt" in
    p) PITCH_RATIO="$OPTARG" ;;
    t) TIME_SCALE="$OPTARG" ;;
    o) OUT_DIR="$OPTARG" ;;
    f) OUTPUT_FORMAT="$OPTARG" ;;
    h) print_usage; exit 0 ;;
    \?) echo "无效参数: -$OPTARG" >&2; print_usage; exit 1 ;;
    :)  echo "选项 -$OPTARG 需要值" >&2; print_usage; exit 1 ;;
  esac
done

# ============ 输出编码映射 ============
typeset -A CODEC_MAP
CODEC_MAP=(
  [16bit]="pcm_s16le"
  [24bit]="pcm_s24le"
  [32bit]="pcm_s32le"
  [float32]="pcm_f32le"
  [float64]="pcm_f64le"
  [flac]="flac"
)

if [[ -z "${CODEC_MAP[$OUTPUT_FORMAT]}" ]]; then
  echo "不支持的输出格式: $OUTPUT_FORMAT" >&2
  echo "可选: ${(k)CODEC_MAP}" >&2
  exit 1
fi
OUTPUT_CODEC="${CODEC_MAP[$OUTPUT_FORMAT]}"
OUT_EXT="wav"
[[ "$OUTPUT_FORMAT" == "flac" ]] && OUT_EXT="flac"

echo "使用输出格式：$OUTPUT_FORMAT ($OUTPUT_CODEC)"

# ============ 依赖检测 ============
command -v ffmpeg >/dev/null 2>&1 || { echo "未找到 ffmpeg，请先安装 (brew install ffmpeg)"; exit 1; }
command -v ffprobe >/dev/null 2>&1 || { echo "未找到 ffprobe，请先安装 (brew install ffmpeg)"; exit 1; }

# ============ 计算派生参数 ============
tempo_target=$(( 1.0 / TIME_SCALE ))
tempo_fix=$(( tempo_target / PITCH_RATIO ))

echo "参数：变调倍率=$PITCH_RATIO, 时间比例=$TIME_SCALE"
echo "计算：目标tempo=$tempo_target, 校正tempo=$tempo_fix"

# ============ 统计结构 ============
typeset -F 10 total_start total_end total_elapsed
total_start="$EPOCHREALTIME"

typeset -A file_details
file_processing_order=() 

# 使用数字索引避免路径问题
file_index=0

# ============ 工具函数 ============
get_samplerate() {
  local sr
  sr="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
        -of default=nokey=1:noprint_wrappers=1 -- "$1" 2>/dev/null | head -n1)"
  [[ -n "$sr" ]] && echo "$sr" || echo ""
}

has_filter() {
  ffmpeg -hide_banner -filters 2>/dev/null | grep -qE "[[:space:]]$1[[:space:]]"
}

build_atempo_chain() {
  local remaining="$1"
  local chain=()
  local step step_str
  local epsilon=0.000001

  if (( remaining >= 0.5 && remaining <= 2.0 )); then
    printf "atempo=%.6f" "$remaining"
    return 0
  fi

  while (( remaining > 2.0 )); do
    step=$(( sqrt(remaining) ))
    (( step > 2.0 )) && step=2.0
    step_str=$(printf "%.6f" "$step")
    chain+=("atempo=${step_str}")
    remaining=$(( remaining / step ))
  done

  while (( remaining < 0.5 )); do
    step=$(( sqrt(remaining) ))
    (( step < 0.5 )) && step=0.5
    step_str=$(printf "%.6f" "$step")
    chain+=("atempo=${step_str}")
    remaining=$(( remaining / step ))
  done

  if (( abs(remaining - 1.0) > epsilon )); then
    step_str=$(printf "%.6f" "$remaining")
    chain+=("atempo=${step_str}")
  fi

  local IFS=,
  echo "${chain[*]}"
}

run_ffmpeg_with_timer() {
  local in="$1" af="$2" out="$3" codec="$4"
  local size_bytes rc=0
  local -F 10 size_mb dur speed
  local start_ns end_ns
  
  size_bytes=$(stat -f%z -- "$in" 2>/dev/null)
  [[ -z "$size_bytes" ]] && size_bytes=0
  size_mb=$(( size_bytes / 1048576.0 ))

  start_ns=$EPOCHREALTIME
  ffmpeg -hide_banner -y -i "$in" -af "$af" -c:a "$codec" "$out" >/dev/null 2>&1
  rc=$?
  end_ns=$EPOCHREALTIME

  dur=$(( (end_ns + 0.0) - (start_ns + 0.0) ))
  (( dur <= 0.000001 )) && dur=0.000001
  speed=$(( size_mb / dur ))

  printf "%d %.6f %.6f" "$rc" "$dur" "$speed"
}

# ============ 检测滤镜支持 ============
HAS_RUBBERBAND=true
HAS_ATEMPO=true
HAS_ASETRATE=true
HAS_SCALETEMPO=false

echo "滤镜支持情况：rubberband=$HAS_RUBBERBAND, atempo=$HAS_ATEMPO, asetrate=$HAS_ASETRATE, scaletempo=$HAS_SCALETEMPO"

# ============ 准备输出目录与输入列表 ============
mkdir -p -- "$OUT_DIR"

files=(*.(wav|WAV)(N))
if (( ${#files} == 0 )); then
  echo "当前目录没有 .wav 文件。"
  exit 0
fi

# ============ 处理每个文件 ============
for in_file in "${files[@]}"; do
  base="${in_file:r:t}"
  file_start="$EPOCHREALTIME"
  
  if [[ ! -f "$in_file" ]] || [[ ! -r "$in_file" ]]; then
    echo "跳过：文件不存在或不可读 -> $in_file" >&2
    continue
  fi
  
  # 使用数字索引作为键的前缀，避免路径问题
  ((file_index++))
  current_file_id="file_${file_index}"
  file_processing_order+=("$current_file_id")
  
  # 存储文件路径和基本信息
  file_details["${current_file_id}_path"]="$in_file"
  file_details["${current_file_id}_basename"]="$(basename "$in_file")"
  
  # 获取文件大小
  size_bytes=$(stat -f%z -- "$in_file" 2>/dev/null)
  if [[ -z "$size_bytes" ]] || (( size_bytes == 0 )); then
    echo "跳过：无法读取文件大小或文件为空 -> $in_file" >&2
    file_details["${current_file_id}_skipped"]="true"
    continue
  fi
  
  size_mb=$(( size_bytes / 1048576.0 ))
  file_details["${current_file_id}_size"]="$size_mb"
  
  echo
  echo "处理文件：${in_file} (大小: $(printf "%.2f" "$size_mb") MB)"

  # 读取采样率
  sr="$(get_samplerate "$in_file")"
  if [[ -z "$sr" ]] || (( sr == 0 )); then
    echo "跳过：无法读取采样率或采样率为0 -> $in_file" >&2
    file_details["${current_file_id}_skipped"]="true"
    continue
  fi
  echo "采样率：${sr} Hz"
  file_details["${current_file_id}_samplerate"]="$sr"

  # ========== 方案1：rubberband ==========
  if $HAS_RUBBERBAND; then
    echo
    echo "方案1 - Rubberband"
    filter="rubberband=pitch=${PITCH_RATIO}:tempo=${tempo_target}"
    out_file="${OUT_DIR}/${base}_p${PITCH_RATIO}_t${TIME_SCALE}_rubberband.${OUT_EXT}"
    echo "滤镜：$filter"

    read -r rc dur speed <<<"$(run_ffmpeg_with_timer "$in_file" "$filter" "$out_file" "$OUTPUT_CODEC")"
    
    if (( rc == 0 )) && [[ -f "$out_file" ]]; then
      file_details["${current_file_id}_rubberband_result"]="成功"
      file_details["${current_file_id}_rubberband_time"]="$dur"
      file_details["${current_file_id}_rubberband_speed"]="$speed"
      echo "✓ Rubberband 成功 - 耗时: $(printf "%.2f" "$dur")s (速度: $(printf "%.2f" "$speed") MB/s)"
    else
      file_details["${current_file_id}_rubberband_result"]="失败"
      file_details["${current_file_id}_rubberband_time"]="$dur"
      file_details["${current_file_id}_rubberband_speed"]="0"
      echo "✗ Rubberband 失败 - 耗时: $(printf "%.2f" "$dur")s"
    fi
  fi

  # ========== 方案2：asetrate + atempo ==========
  if $HAS_ASETRATE && $HAS_ATEMPO; then
    echo
    echo "方案2 - Asetrate + Atempo"
    new_sr=${$(( sr * PITCH_RATIO ))%.*}
    atempo_chain="$(build_atempo_chain "$tempo_fix")"
    filter="asetrate=${new_sr},aresample=${sr},${atempo_chain}"
    out_file="${OUT_DIR}/${base}_p${PITCH_RATIO}_t${TIME_SCALE}_asetrate_atempo.${OUT_EXT}"
    echo "滤镜：$filter"

    read -r rc dur speed <<<"$(run_ffmpeg_with_timer "$in_file" "$filter" "$out_file" "$OUTPUT_CODEC")"
    
    if (( rc == 0 )) && [[ -f "$out_file" ]]; then
      file_details["${current_file_id}_asetrate_atempo_result"]="成功"
      file_details["${current_file_id}_asetrate_atempo_time"]="$dur"
      file_details["${current_file_id}_asetrate_atempo_speed"]="$speed"
      echo "✓ Asetrate + Atempo 成功 - 耗时: $(printf "%.2f" "$dur")s (速度: $(printf "%.2f" "$speed") MB/s)"
    else
      file_details["${current_file_id}_asetrate_atempo_result"]="失败"
      file_details["${current_file_id}_asetrate_atempo_time"]="$dur"
      file_details["${current_file_id}_asetrate_atempo_speed"]="0"
      echo "✗ Asetrate + Atempo 失败 - 耗时: $(printf "%.2f" "$dur")s"
    fi
  fi

  # ========== 方案5：scaletempo ==========
  if $HAS_SCALETEMPO; then
    echo
    echo "方案5 - Scaletempo（仅变速，不变调）"
    atempo_chain="$(build_atempo_chain "$tempo_target")"
    filter="scaletempo=stride=0.3:overlap=0.2:search=14,${atempo_chain}"
    out_file="${OUT_DIR}/${base}_p${PITCH_RATIO}_t${TIME_SCALE}_scaletempo.${OUT_EXT}"
    echo "滤镜：$filter"

    read -r rc dur speed <<<"$(run_ffmpeg_with_timer "$in_file" "$filter" "$out_file" "$OUTPUT_CODEC")"
    
    if (( rc == 0 )) && [[ -f "$out_file" ]]; then
      file_details["${current_file_id}_scaletempo_result"]="成功"
      file_details["${current_file_id}_scaletempo_time"]="$dur"
      file_details["${current_file_id}_scaletempo_speed"]="$speed"
      echo "✓ Scaletempo 成功 - 耗时: $(printf "%.2f" "$dur")s (速度: $(printf "%.2f" "$speed") MB/s)"
    else
      file_details["${current_file_id}_scaletempo_result"]="失败"
      file_details["${current_file_id}_scaletempo_time"]="$dur"
      file_details["${current_file_id}_scaletempo_speed"]="0"
      echo "✗ Scaletempo 失败 - 耗时: $(printf "%.2f" "$dur")s"
    fi
  fi

  file_end="$EPOCHREALTIME"
  file_elapsed=$(( file_end - file_start ))
  file_details["${current_file_id}_total_time"]="$file_elapsed"
  echo
  echo "文件 '${in_file}' 处理完成 - 总耗时: $(printf "%.2f" "$file_elapsed")s"
done

# ============ 详细统计报告 ============
total_end="$EPOCHREALTIME"
total_elapsed=$(( total_end - total_start ))

echo
printf '%80s\n' | tr ' ' '='
echo "详细处理时间报告"
printf '%80s\n' | tr ' ' '='

echo
echo "总体统计："
echo "- 处理文件数量: ${#file_processing_order}"
echo "- 总处理时间: $(printf "%.2f" "$total_elapsed")s ($(printf "%.2f" $(( total_elapsed/60.0 )) ) 分钟)"

echo
echo "各文件详细处理时间："
echo

# 定义方案列表
schemes=()
$HAS_RUBBERBAND && schemes+=("rubberband")
$HAS_ASETRATE && $HAS_ATEMPO && schemes+=("asetrate_atempo")
$HAS_SCALETEMPO && schemes+=("scaletempo")

for file_id in "${file_processing_order[@]}"; do
  # 跳过被跳过的文件
  [[ "${file_details[${file_id}_skipped]}" == "true" ]] && continue
  
  file_name="${file_details[${file_id}_basename]}"
  file_size="${file_details[${file_id}_size]}"
  file_sr="${file_details[${file_id}_samplerate]}"
  file_total="${file_details[${file_id}_total_time]}"

  echo "📁 文件: $file_name"
  echo "   大小: $(printf "%.2f" "$file_size") MB | 采样率: ${file_sr} Hz | 总耗时: $(printf "%.2f" "$file_total")s"
  
  for scheme in "${schemes[@]}"; do
    result_key="${file_id}_${scheme}_result"
    time_key="${file_id}_${scheme}_time"
    speed_key="${file_id}_${scheme}_speed"
    
    result="${file_details[$result_key]}"
    if [[ -n "$result" ]]; then
      time_val="${file_details[$time_key]}"
      speed_val="${file_details[$speed_key]}"
      
      case "$scheme" in
        "rubberband")
          scheme_name="Rubberband       "
          ;;
        "asetrate_atempo")
          scheme_name="Asetrate+Atempo  "
          ;;
        "scaletempo")
          scheme_name="Scaletempo       "
          ;;
      esac
      
      if [[ "$result" == "成功" ]]; then
        echo "   ✓ ${scheme_name}: $(printf "%6.2f" "$time_val")s ($(printf "%6.2f" "$speed_val") MB/s)"
      else
        echo "   ✗ ${scheme_name}: $(printf "%6.2f" "$time_val")s (失败)"
      fi
    fi
  done
  echo
done

echo "完成。输出目录：$OUT_DIR"