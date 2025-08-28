Usage:

    .\NStretcher.exe --time=0.5 --pitch=700 --mode=2

This program processes all wav files in the working folder by defualt. And it might be the best time-stretch and pitchshift program in the world? I'm not sure, and haven't decided what to do with it.

doFfmpeg.ps1 processes all wav files in the working folder with ffmpeg. Attention: Only two methods do both time stretch and pitchshift at one time, and others can not be compared with NStretcher.

batchR3.ps1 processes all wav files in the working folder with rubberband, whose R3 engine is really perfect! I guess ffmpeg only uses it's R2 engine because it runs so fast.

Maybe I will upload a benchmark soon.

P.S.: 

Mode 2 is the most balanced mode. And mode 4 is an efficient mode. 

If a pitchshifter processes 50.05Hz wav perfectly, I guess it also has great performance on bass.

If a pitchshifter processes FreqScan.wav perfectly, I guess it also has great performance on realtime-changing frequency. (Not so sure like 50.05Hz. lol)


