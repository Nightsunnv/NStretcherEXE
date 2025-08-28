#!/usr/bin/env pwsh
# PowerShell 7 script - 修正版
# 批量将当前目录下的 .wav 文件按指定变调与时间比例转换，输出到 converted 子目录

param(
    [double]$PitchRatio = 1.12246,
    [double]$TimeScale  = 0.993,
    [string]$OutDir     = "converted",
    [string]$OutputFormat = "float32"
)

$codecMap = @{
    "16bit"   = "pcm_s16le"
    "24bit"   = "pcm_s24le" 
    "32bit"   = "pcm_s32le"
    "float32" = "pcm_f32le"
    "float64" = "pcm_f64le"
    "flac"    = "flac"
}

$outputCodec = $codecMap[$OutputFormat]
Write-Host "使用输出格式：$OutputFormat ($outputCodec)"

# 时间统计变量
$totalStartTime = Get-Date
$processingStats = @()
$schemeStats = @{}

# 确保 ffmpeg 和 ffprobe 可用
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffprobe = Get-Command ffprobe -ErrorAction SilentlyContinue
if (-not $ffmpeg -or -not $ffprobe) {
    Write-Error "未找到 ffmpeg 或 ffprobe，请先安装并将其加入 PATH。"
    exit 1
}

# 计算 tempo 值：tempo 是速度倍率（时长的倒数）
$tempoTarget = 1.0 / $TimeScale            # 目标速度 = 1/t
$tempoFix    = $tempoTarget / $PitchRatio  # 用在 asetrate 组合中，把速度校正到目标

Write-Host "参数：变调倍率=$PitchRatio, 时间比例=$TimeScale"
Write-Host "计算：目标tempo=$tempoTarget, 校正tempo=$tempoFix"

# 读取采样率的函数
function Get-SampleRate {
    param([string]$Path)
    $args = @(
        "-v","error",
        "-select_streams","a:0",
        "-show_entries","stream=sample_rate",
        "-of","default=noprint_wrappers=1:nokey=1",
        $Path
    )
    $val = & ffprobe @args | Select-Object -First 1
    if (-not $val) { return $null }
    return [int]$val
}

# 构建 atempo 链的函数（处理超出 [0.5,2.0] 范围的情况）
function Build-AtempoChain {
    param([double]$Tempo)
    
    if ($Tempo -ge 0.5 -and $Tempo -le 2.0) {
        return "atempo=$Tempo"
    }

    $chain = @()
    $remaining = $Tempo

    while ($remaining -gt 2.0) {
        $step = [Math]::Min(2.0, [Math]::Sqrt($remaining))
        $chain += "atempo=$step"
        $remaining = $remaining / $step
    }
    
    while ($remaining -lt 0.5) {
        $step = [Math]::Max(0.5, [Math]::Sqrt($remaining))
        $chain += "atempo=$step"
        $remaining = $remaining / $step
    }
    
    if ($remaining -ne 1.0) {
        $chain += "atempo=$remaining"
    }
    
    return ($chain -join ",")
}

# 辅助函数：检测滤镜是否受支持
function Test-FFmpegFilter {
    param([string]$FilterName)
    $filters = & ffmpeg -hide_banner -filters 2>$null
    return ($filters -match "\s$FilterName\s")
}

$hasRubberband = Test-FFmpegFilter -FilterName "rubberband"
$hasAtempo     = Test-FFmpegFilter -FilterName "atempo"
$hasAsetrate   = Test-FFmpegFilter -FilterName "asetrate"
$hasScaletempo = Test-FFmpegFilter -FilterName "scaletempo"

Write-Host "滤镜支持情况：rubberband=$hasRubberband, atempo=$hasAtempo, asetrate=$hasAsetrate, scaletempo=$hasScaletempo"

# 输出目录
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# 列出输入文件
$inputs = Get-ChildItem -File -Filter "*.wav"
if ($inputs.Count -eq 0) {
    Write-Host "当前目录没有 .wav 文件。"
    exit 0
}

# 处理每个文件
foreach ($inputFile in $inputs) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($inputFile.Name)
    $fileStartTime = Get-Date
    $fileStats = @{
        FileName = $inputFile.Name
        FileSize = [math]::Round($inputFile.Length / 1MB, 2)
        Schemes = @{}
        TotalTime = $null
    }
    
    Write-Host "`n处理文件：$($inputFile.Name) (大小: $($fileStats.FileSize) MB)"
    
    # 读取采样率
    $sampleRate = Get-SampleRate $inputFile.FullName
    if (-not $sampleRate) {
        Write-Warning "跳过（无法读取采样率）：$($inputFile.Name)"
        continue
    }
    Write-Host "采样率：$sampleRate Hz"

    # 方案1：rubberband
    if ($hasRubberband) {
        Write-Host "`n方案1 - Rubberband"
        $filter = "rubberband=pitchq=${PitchRatio}:tempo=${tempoTarget}"
        $outFile = Join-Path $OutDir "${base}_p${PitchRatio}_t${TimeScale}_rubberband.wav"
        
        Write-Host "滤镜：$filter"
        
        # 测量处理时间
        $processTime = Measure-Command {
            & ffmpeg -hide_banner -y -i $inputFile.FullName -af $filter -c:a $outputCodec $outFile
        }
        
        $success = ($LASTEXITCODE -eq 0)
        $fileStats.Schemes['rubberband'] = @{
            Success = $success
            Time = $processTime.TotalSeconds
            Speed = if($success) { [math]::Round($fileStats.FileSize / $processTime.TotalSeconds, 2) } else { 0 }
        }
        
        if ($success) {
            Write-Host "✓ Rubberband 处理成功 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s (速度: $($fileStats.Schemes['rubberband'].Speed) MB/s)"
        } else {
            Write-Warning "✗ Rubberband 处理失败 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s"
        }
        
        # 累计方案统计
        if (-not $schemeStats['rubberband']) {
            $schemeStats['rubberband'] = @{ TotalTime = 0; SuccessCount = 0; FailCount = 0 }
        }
        $schemeStats['rubberband'].TotalTime += $processTime.TotalSeconds
        if ($success) { 
            $schemeStats['rubberband'].SuccessCount++ 
        } else { 
            $schemeStats['rubberband'].FailCount++ 
        }
    }

    # 方案2：asetrate + atempo
    if ($hasAsetrate -and $hasAtempo) {
        Write-Host "`n方案2 - Asetrate + Atempo"
        $newSampleRate = [int]($sampleRate*$PitchRatio)
        $atempoChain = Build-AtempoChain -Tempo $tempoFix
        $filter = "asetrate=${newSampleRate},aresample=${sampleRate},${atempoChain}"
        $outFile = Join-Path $OutDir "${base}_p${PitchRatio}_t${TimeScale}_asetrate_atempo.wav"
        
        Write-Host "滤镜：$filter"
        
        $processTime = Measure-Command {
            & ffmpeg -hide_banner -y -i $inputFile.FullName -af $filter -c:a $outputCodec $outFile
        }
        
        $success = ($LASTEXITCODE -eq 0)
        $fileStats.Schemes['asetrate_atempo'] = @{
            Success = $success
            Time = $processTime.TotalSeconds
            Speed = if($success) { [math]::Round($fileStats.FileSize / $processTime.TotalSeconds, 2) } else { 0 }
        }
        
        if ($success) {
            Write-Host "✓ Asetrate + Atempo 处理成功 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s (速度: $($fileStats.Schemes['asetrate_atempo'].Speed) MB/s)"
        } else {
            Write-Warning "✗ Asetrate + Atempo 处理失败 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s"
        }
        
        if (-not $schemeStats['asetrate_atempo']) {
            $schemeStats['asetrate_atempo'] = @{ TotalTime = 0; SuccessCount = 0; FailCount = 0 }
        }
        $schemeStats['asetrate_atempo'].TotalTime += $processTime.TotalSeconds
        if ($success) { 
            $schemeStats['asetrate_atempo'].SuccessCount++ 
        } else { 
            $schemeStats['asetrate_atempo'].FailCount++ 
        }
    }

    # 方案3：atempo only
    if ($hasAtempo) {
        Write-Host "`n方案3 - Atempo Only（仅变速，不变调）"
        $atempoChain = Build-AtempoChain -Tempo $tempoTarget
        $filter = $atempoChain
        $outFile = Join-Path $OutDir "${base}_p${PitchRatio}_t${TimeScale}_atempo_only.wav"
        
        Write-Host "滤镜：$filter"
        
        $processTime = Measure-Command {
            & ffmpeg -hide_banner -y -i $inputFile.FullName -af $filter -c:a $outputCodec $outFile
        }
        
        $success = ($LASTEXITCODE -eq 0)
        $fileStats.Schemes['atempo_only'] = @{
            Success = $success
            Time = $processTime.TotalSeconds
            Speed = if($success) { [math]::Round($fileStats.FileSize / $processTime.TotalSeconds, 2) } else { 0 }
        }
        
        if ($success) {
            Write-Host "✓ Atempo Only 处理成功 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s (速度: $($fileStats.Schemes['atempo_only'].Speed) MB/s)"
        } else {
            Write-Warning "✗ Atempo Only 处理失败 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s"
        }
        
        if (-not $schemeStats['atempo_only']) {
            $schemeStats['atempo_only'] = @{ TotalTime = 0; SuccessCount = 0; FailCount = 0 }
        }
        $schemeStats['atempo_only'].TotalTime += $processTime.TotalSeconds
        if ($success) { 
            $schemeStats['atempo_only'].SuccessCount++ 
        } else { 
            $schemeStats['atempo_only'].FailCount++ 
        }
    }

    # 方案4：asetrate + aresample only（同比变调变速，简单粗暴）
    if ($hasAsetrate) {
        Write-Host "`n方案4 - Asetrate + Aresample Only（同比变调变速）"
        $newSampleRate = [int]($sampleRate*$PitchRatio)
        $filter = "asetrate=${newSampleRate},aresample=${sampleRate}"
        $outFile = Join-Path $OutDir "${base}_p${PitchRatio}_t${TimeScale}_asetrate_aresample_only.wav"
        
        $ffmpegArgs = @(
            "-hide_banner", "-y",
            "-i", $inputFile.FullName,
            "-af", $filter,
            "-c:a", $outputCodec,
            $outFile
        )
        
        Write-Host "滤镜：$filter"
        
        $processTime = Measure-Command {
            & ffmpeg @ffmpegArgs
        }
        
        $success = ($LASTEXITCODE -eq 0)
        $fileStats.Schemes['asetrate_aresample_only'] = @{
            Success = $success
            Time = $processTime.TotalSeconds
            Speed = if($success) { [math]::Round($fileStats.FileSize / $processTime.TotalSeconds, 2) } else { 0 }
        }
        
        if ($success -and (Test-Path $outFile)) {
            Write-Host "✓ Asetrate + Aresample Only 处理成功 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s (速度: $($fileStats.Schemes['asetrate_aresample_only'].Speed) MB/s)"
        } else {
            Write-Warning "✗ Asetrate + Aresample Only 处理失败 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s"
        }
    }

    # 方案5：scaletempo（变速不变调，作为参考）
    if ($hasScaletempo) {
        Write-Host "`n方案5 - Scaletempo（仅变速，不变调）"
        $atempoChain = Build-AtempoChain -Tempo $tempoTarget
        $filter = "scaletempo=stride=0.3:overlap=0.2:search=14,${atempoChain}"
        $outFile = Join-Path $OutDir "${base}_p${PitchRatio}_t${TimeScale}_scaletempo.wav"
        
        $ffmpegArgs = @(
            "-hide_banner", "-y",
            "-i", $inputFile.FullName,
            "-af", $filter,
            "-c:a", $outputCodec,
            $outFile
        )
        
        Write-Host "滤镜：$filter"
        
        $processTime = Measure-Command {
            & ffmpeg @ffmpegArgs
        }
        
        $success = ($LASTEXITCODE -eq 0)
        $fileStats.Schemes['scaletempo'] = @{
            Success = $success
            Time = $processTime.TotalSeconds
            Speed = if($success) { [math]::Round($fileStats.FileSize / $processTime.TotalSeconds, 2) } else { 0 }
        }
        
        if ($success -and (Test-Path $outFile)) {
            Write-Host "✓ Scaletempo 处理成功 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s (速度: $($fileStats.Schemes['scaletempo'].Speed) MB/s)"
        } else {
            Write-Warning "✗ Scaletempo 处理失败 - 耗时: $([math]::Round($processTime.TotalSeconds, 2))s"
        }
    }

    # 计算文件总处理时间
    $fileEndTime = Get-Date
    $fileStats.TotalTime = ($fileEndTime - $fileStartTime).TotalSeconds
    $processingStats += $fileStats
    
    Write-Host "`n文件 '$($inputFile.Name)' 处理完成 - 总耗时: $([math]::Round($fileStats.TotalTime, 2))s"
}

# 输出详细统计报告
$totalEndTime = Get-Date
$totalProcessTime = ($totalEndTime - $totalStartTime).TotalSeconds

Write-Host "`n" + ("="*80)
Write-Host "处理时间统计报告"
Write-Host ("="*80)

# 总体统计
Write-Host "`n总体统计："
Write-Host "- 处理文件数量: $($processingStats.Count)"
Write-Host "- 总处理时间: $([math]::Round($totalProcessTime, 2))s ($([math]::Round($totalProcessTime/60, 2)) 分钟)"
$totalFileSize = ($processingStats | Measure-Object -Property FileSize -Sum).Sum
Write-Host "- 总文件大小: $([math]::Round($totalFileSize, 2)) MB"
Write-Host "- 平均处理速度: $([math]::Round($totalFileSize / $totalProcessTime, 2)) MB/s"

# 各方案性能对比
Write-Host "`n各方案性能对比："
foreach ($scheme in $schemeStats.Keys | Sort-Object) {
    $stats = $schemeStats[$scheme]
    $avgTime = if ($stats.SuccessCount -gt 0) { [math]::Round($stats.TotalTime / $stats.SuccessCount, 2) } else { 0 }
    Write-Host "- ${scheme}:"
    Write-Host "  成功: $($stats.SuccessCount), 失败: $($stats.FailCount)"
    Write-Host "  总耗时: $([math]::Round($stats.TotalTime, 2))s"
    Write-Host "  平均耗时: ${avgTime}s"
}

# 每个文件的详细统计
Write-Host "`n每个文件的处理详情："
foreach ($fileStat in $processingStats) {
    Write-Host "`n文件: $($fileStat.FileName) ($($fileStat.FileSize) MB)"
    Write-Host "总耗时: $([math]::Round($fileStat.TotalTime, 2))s"
    foreach ($scheme in $fileStat.Schemes.Keys | Sort-Object) {
        $s = $fileStat.Schemes[$scheme]
        $status = if ($s.Success) { "✓" } else { "✗" }
        Write-Host "  ${scheme}: ${status} $([math]::Round($s.Time, 2))s ($($s.Speed) MB/s)"
    }
}

Write-Host "`n完成。输出目录：$OutDir"