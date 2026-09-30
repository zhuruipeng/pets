// 探针 2：制造失败后停住，留出时间窗让外部枚举 \\.\pipe\。
//
// 失败时 Dart 创建的管道服务端仍然活着（这正是 BUSY 的前提），
// 所以只要进程不停，那个管道名就能被看见。
import 'dart:io';

void main() async {
  stdout.write('probe2 pid=$pid 开始\n');
  for (var i = 1; i <= 6; i++) {
    try {
      final r = await Process.run('cmd', ['/c', 'echo hi']);
      stdout.write('第 $i 次 OK rc=${r.exitCode}\n');
    } catch (e) {
      final msg = e.toString().split('\n').first;
      stdout.write('第 $i 次 FAIL: $msg\n');
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  stdout.write('probe2 结束\n');
}
