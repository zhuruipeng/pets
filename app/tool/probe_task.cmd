@echo off
rem 跳出 WorkBuddy 进程树，验证「命名管道打不开」是不是它的钩子造成的。
set DART=E:\dev\flutter\bin\cache\dart-sdk\bin\dart.exe
set PROBE=C:\Users\Administrator\WorkBuddy\2026-09-28-20-54-43\pet-app\app\tool\probe_spawn.dart
set OUT=C:\Users\Administrator\AppData\Local\Temp\probe_ts.txt
"%DART%" "%PROBE%" > "%OUT%" 2>&1
echo EXITCODE=%ERRORLEVEL% >> "%OUT%"
