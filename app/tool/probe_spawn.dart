// 探针：dart 能不能创建子进程。
// 三种模式分开测，因为 Dart 的 Process.run / start 在 Windows 上
// 分别走「命名管道重定向」和「继承句柄」两条不同的代码路径。
import 'dart:io';

void main() async {
  stdout.write('dart pid=$pid\n');

  // 1) runSync：同步，内部走 CreatePipe
  try {
    final r = Process.runSync('cmd', ['/c', 'ver']);
    stdout.write('runSync OK rc=${r.exitCode} out=${r.stdout.toString().trim()}\n');
  } catch (e) {
    stdout.write('runSync FAIL: $e\n');
  }

  // 2) run：异步，同样走 CreatePipe
  try {
    final r = await Process.run('cmd', ['/c', 'ver']);
    stdout.write('run OK rc=${r.exitCode}\n');
  } catch (e) {
    stdout.write('run FAIL: $e\n');
  }

  // 3) start + inheritStdio：不建管道，继承父进程句柄
  try {
    final p = await Process.start(
      'cmd',
      ['/c', 'ver'],
      mode: ProcessStartMode.inheritStdio,
    );
    stdout.write('start(inheritStdio) OK pid=${p.pid} rc=${await p.exitCode}\n');
  } catch (e) {
    stdout.write('start(inheritStdio) FAIL: $e\n');
  }
}
