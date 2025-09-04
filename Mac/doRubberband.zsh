#!/usr/bin/env zsh

# 高级版本：带进度显示、错误处理、统计信息、处理时间记录

setopt null_glob
setopt extended_glob

exe="rubberband"
out_dir="$(pwd)/output" 
max_jobs=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# 参数处理
print_usage() {
  cat <<EOF
用法: $0 [-j jobs] [-o output_dir] [-t tempo] [-f frequency] [-q]
参数:
  -j  并发任务数 (默认: $max_jobs)
  -o  输出目录 (默认: $out_dir)
  -t  tempo 参数 (默认: 0.993)
  -f  frequency 参数 (默认: 1.12246)
  -q  静默模式
  -h  显示帮助

示例:
  $0 -j 8 -o converted -t 0.993 -f 1.12246
EOF
}

tempo=0.993
frequency=1.12246
quiet=false

while getopts ":j:o:t:f:qh" opt; do
  case "$opt" in
    j) max_jobs="$OPTARG" ;;
    o) out_dir="$OPTARG" ;;
    t) tempo="$OPTARG" ;;
    f) frequency="$OPTARG" ;;
    q) quiet=true ;;
    h) print_usage; exit 0 ;;
    \?) echo "无效参数: -$OPTARG" >&2; print_usage; exit 1 ;;
  esac
done

# 检查依赖
# if [[ ! -x "$exe" ]]; then
#   echo "错误: 找不到可执行文件 $exe" >&2
#   echo "请确保文件存在且具有执行权限：chmod +x $exe" >&2
#   exit 1
# fi

# 创建输出目录
mkdir -p "$out_dir" || {
  echo "错误: 无法创建输出目录 $out_dir" >&2
  exit 1
}

# 获取文件列表
files=(*.wav(N))
if (( ${#files} == 0 )); then
  echo "当前目录没有找到 .wav 文件"
  exit 0
fi

total_files=${#files}

echo "找到 $total_files 个文件"
echo "并发任务: $max_jobs"
echo "输出目录: $out_dir"
echo "参数: -t $tempo -f $frequency"
echo

# 开始时间
start_time=$(date +%s)

# 创建临时处理脚本
temp_script=$(mktemp)
cat > "$temp_script" << 'EOF'
#!/usr/bin/env zsh

# 接收参数
wav_file="$1"
exe="$2"
out_dir="$3"
tempo="$4"
frequency="$5"
quiet="$6"

process_single_file() {
  local wav_file="$1"
  local in_file out_file base_name
  local file_start_time file_end_time file_duration
  
  # 记录文件开始处理时间
  file_start_time=$(date +%s.%N 2>/dev/null || date +%s)
  
  # 检查文件是否存在
  if [[ ! -f "$wav_file" ]]; then
    echo "failed:$wav_file:0 (文件不存在)"
    return 1
  fi
  
  in_file="$(realpath "$wav_file" 2>/dev/null)" || in_file="$wav_file"
  base_name="${wav_file:r}"
  out_file="$out_dir/${base_name}.wav"
  
  if [[ "$quiet" != "true" ]]; then
    printf "开始处理: %-30s -> %s\n" "$wav_file" "$(basename "$out_file")"
  fi
  
  # 执行 rubberband
  if "$exe" -t "$tempo" -f "$frequency" -3 -q "$in_file" "$out_file" >/dev/null 2>&1; then
    # 记录文件结束处理时间
    file_end_time=$(date +%s.%N 2>/dev/null || date +%s)
    
    # 计算处理时间
    if command -v bc >/dev/null 2>&1; then
      file_duration=$(echo "$file_end_time - $file_start_time" | bc 2>/dev/null || echo "0")
    else
      file_duration=$(( ${file_end_time%.*} - ${file_start_time%.*} ))
    fi
    
    if [[ "$quiet" != "true" ]]; then
      printf "✓ 完成: %-30s (用时: %.2fs)\n" "$wav_file" "$file_duration"
    fi
    echo "success:$wav_file:$file_duration"
    return 0
  else
    file_end_time=$(date +%s.%N 2>/dev/null || date +%s)
    if command -v bc >/dev/null 2>&1; then
      file_duration=$(echo "$file_end_time - $file_start_time" | bc 2>/dev/null || echo "0")
    else
      file_duration=$(( ${file_end_time%.*} - ${file_start_time%.*} ))
    fi
    
    echo "✗ 失败: $wav_file (用时: ${file_duration}s)" >&2
    echo "failed:$wav_file:$file_duration"
    return 1
  fi
}

# 调用处理函数
process_single_file "$wav_file"
EOF

chmod +x "$temp_script"

# 并行处理
if command -v parallel >/dev/null 2>&1; then
  # 使用 GNU parallel（推荐）
  echo "使用 GNU parallel 进行并行处理"
  results=$(printf '%s\n' "${files[@]}" | \
    parallel -j "$max_jobs" --line-buffer "$temp_script" {} "$exe" "$out_dir" "$tempo" "$frequency" "$quiet")
else
  # 使用 xargs 并行
  echo "使用 xargs 进行并行处理"
  results=$(printf '%s\n' "${files[@]}" | \
    xargs -n 1 -P "$max_jobs" -I {} "$temp_script" {} "$exe" "$out_dir" "$tempo" "$frequency" "$quiet")
fi

# 清理临时脚本
rm -f "$temp_script"

# 统计结果
completed=0
failed=0
total_processing_time=0
success_files=()
failed_files=()

# 处理结果并收集统计信息
while IFS= read -r line; do
  if [[ "$line" =~ ^success:(.+):(.+)$ ]]; then
    completed=$(( completed + 1 ))
    filename="${match[1]}"
    duration="${match[2]}"
    success_files+=("$filename:$duration")
    if command -v bc >/dev/null 2>&1; then
      total_processing_time=$(echo "$total_processing_time + $duration" | bc 2>/dev/null || echo "$total_processing_time")
    else
      total_processing_time=$(( total_processing_time + ${duration%.*} ))
    fi
  elif [[ "$line" =~ ^failed:(.+):(.+)$ ]]; then
    failed=$(( failed + 1 ))
    filename="${match[1]}"
    duration="${match[2]}"
    failed_files+=("$filename:$duration")
  fi
done <<< "$results"

# 结束时间
end_time=$(date +%s)
duration=$(( end_time - start_time ))

# 最终报告
echo
printf '%70s\n' | tr ' ' '='
echo "处理完成统计"
printf '%70s\n' | tr ' ' '='
echo "总文件数: $total_files"
echo "成功处理: $completed"
echo "处理失败: $failed"
echo "总耗时: ${duration}s"
if command -v bc >/dev/null 2>&1; then
  printf "总处理时间: %.2fs\n" "$total_processing_time"
else
  echo "总处理时间: ${total_processing_time}s"
fi
if (( duration > 0 )); then
  files_per_minute=$(( total_files * 60 / duration ))
  echo "平均速度: $files_per_minute 文件/分钟"
fi
echo "输出目录: $out_dir"

# 显示每个文件的处理时间详情
if (( completed > 0 )); then
  echo
  printf '%70s\n' | tr ' ' '-'
  echo "成功处理的文件及耗时："
  printf '%70s\n' | tr ' ' '-'
  for file_info in "${success_files[@]}"; do
    filename="${file_info%:*}"
    file_duration="${file_info#*:}"
    if command -v bc >/dev/null 2>&1; then
      printf "  ✓ %-40s %8.2fs\n" "$filename" "$file_duration"
    else
      printf "  ✓ %-40s %8ss\n" "$filename" "$file_duration"
    fi
  done
fi

# 如果有失败的文件，显示详情
if (( failed > 0 )); then
  echo
  printf '%70s\n' | tr ' ' '-'
  echo "失败的文件及耗时："
  printf '%70s\n' | tr ' ' '-'
  for file_info in "${failed_files[@]}"; do
    filename="${file_info%:*}"
    file_duration="${file_info#*:}"
    if command -v bc >/dev/null 2>&1; then
      printf "  ✗ %-40s %8.2fs\n" "$filename" "$file_duration"
    else
      printf "  ✗ %-40s %8ss\n" "$filename" "$file_duration"
    fi
  done
fi

# 如果安装了 bc，显示更详细的统计
if command -v bc >/dev/null 2>&1 && (( completed > 0 )); then
  echo
  printf '%70s\n' | tr ' ' '-'
  echo "处理时间统计分析："
  printf '%70s\n' | tr ' ' '-'
  
  # 计算平均处理时间
  avg_time=$(echo "scale=2; $total_processing_time / $completed" | bc)
  printf "平均每文件处理时间: %.2fs\n" "$avg_time"
  
  # 找出最快和最慢的文件
  fastest_time=999999
  slowest_time=0
  fastest_file=""
  slowest_file=""
  
  for file_info in "${success_files[@]}"; do
    filename="${file_info%:*}"
    file_duration="${file_info#*:}"
    
    if (( $(echo "$file_duration < $fastest_time" | bc -l) )); then
      fastest_time="$file_duration"
      fastest_file="$filename"
    fi
    
    if (( $(echo "$file_duration > $slowest_time" | bc -l) )); then
      slowest_time="$file_duration"
      slowest_file="$filename"
    fi
  done
  
  printf "最快处理文件: %s (%.2fs)\n" "$fastest_file" "$fastest_time"
  printf "最慢处理文件: %s (%.2fs)\n" "$slowest_file" "$slowest_time"
fi

echo
printf '%70s\n' | tr ' ' '='
