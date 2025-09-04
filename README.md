Usage:

    ./NStretcher --time=0.993 --pitch=200 --mode=1
    ./NStretcher --time=0.993 --pitch=200 --mode=2
    ./NStretcher --time=0.993 --pitch=200 --mode=3
    ./NStretcher --time=0.993 --pitch=200 --mode=4
    ./doFfmpeg.zsh -t 0.993 -p 1.12246
    ./doRubberband.zsh -t 0.993 -f 1.12246
    ./doFfmpeg.ps1
    ./batchR3.ps1

This program processes all wav files in the working folder by defualt. And it might be the best time-stretch and pitchshift program in the world? I'm not sure, and haven't decided what to do with it.

doFfmpeg.ps1 processes all wav files in the working folder with ffmpeg. Attention: Only two methods do both time stretch and pitchshift at one time, and others can not be compared with NStretcher.

batchR3.ps1 processes all wav files in the working folder with rubberband, whose R3 engine is really perfect! I guess ffmpeg only uses it's R2 engine because it runs so fast.


An easy benchmark:
[NStretcherBenchmark](./NStretcherBenchmark.pdf)

P.S.: 

Mode 2 is the most balanced mode. And mode 4 is an efficient mode. 

If a pitchshifter processes 50.05Hz wav perfectly, I guess it also has great performance on bass.

If a pitchshifter processes FreqScan.wav perfectly, I guess it also has great performance on realtime-changing frequency. (Not so sure like 50.05Hz. lol)


