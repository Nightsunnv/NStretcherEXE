# PowerShell 7+
$exe = ".\rubberband-program-r3.exe"
$outDir = Join-Path (Get-Location) "output"
$maxJobs = [Environment]::ProcessorCount
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Get-ChildItem -File -Filter *.wav | ForEach-Object -Parallel {
    param($exe)

    $in  = $_.FullName
    $out = Join-Path $using:outDir ($_.BaseName + ".wav")

    & $using:exe -t 0.993 -f 1.12246 -3 -q $in $out | Out-Null
} -ThrottleLimit $maxJobs