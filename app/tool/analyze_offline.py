# -*- coding: utf-8 -*-
"""离线跑一遍 Dart 分析 —— 绕开 dartdev，直接跟 analysis server 讲 LSP。

## 为什么需要它

`flutter analyze` / `dart analyze` 都是 dartdev 的内置命令，它们**用 Dart 自己的
`Process.start` 去拉 analysis_server 子进程**。本机有 HIPS 按完整性级别拦命名管道，
于是非提权终端里必报：

    CreateFile failed 231 (所有的管道范例都在使用中)
    Command: dartaotruntime.exe ...\\analysis_server_aot.dart.snapshot ...

而 Python 创建子进程走的是另一条路，实测完全正常。所以这里自己当 LSP 客户端：
起 server → didOpen 全部 .dart → 收 publishDiagnostics。用的是同一个分析服务、
同一份 `analysis_options.yaml`，结果与 `flutter analyze` 同源。

实测（2026-09-30）：`flutter analyze` 报 35 条，本脚本报的也是 35 条，逐条一致。

## 用法

    python tool/analyze_offline.py            # 分析本脚本所在的 app/
    python tool/analyze_offline.py <项目目录>

退出码：有 error 级诊断时 1，否则 0。

## 两个已知行为（别当成 bug）

1. 分析服务**只对有诊断的文件**推 publishDiagnostics，全干净时一条都不推。
   所以退出判据是「静默」而不是「收齐 N 个文件的推送」—— 否则全绿时它会
   一直等到超时。反过来说：只要还在推就说明它还在干活。
2. 首次 initialize 要加载整个 SDK，冷启动可能要几十秒，所以给的时间比较宽。
"""
import json
import os
import queue
import shutil
import subprocess
import sys
import threading
import time
from collections import Counter

ERRLOG = os.path.join(os.environ.get('TEMP', os.getcwd()), 'dart_analyze_offline.err')

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def find_dart_sdk():
    """按优先级找 Dart SDK：显式变量 → FLUTTER_ROOT → PATH 上的 flutter → 本机默认。"""
    cands = []
    if os.environ.get('DART_SDK'):
        cands.append(os.environ['DART_SDK'])
    if os.environ.get('FLUTTER_ROOT'):
        cands.append(os.path.join(os.environ['FLUTTER_ROOT'], 'bin', 'cache', 'dart-sdk'))
    flutter = shutil.which('flutter')
    if flutter:
        root = os.path.dirname(os.path.dirname(os.path.realpath(flutter)))
        cands.append(os.path.join(root, 'bin', 'cache', 'dart-sdk'))
    # 本机（老板的开发机）的固定位置，最后一个兜底
    cands.append(r'E:\dev\flutter\bin\cache\dart-sdk')

    for c in cands:
        if c and os.path.isfile(os.path.join(c, 'bin', 'dartaotruntime.exe')):
            return c
    return None


def to_uri(path):
    return 'file:///' + os.path.abspath(path).replace('\\', '/')


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    app = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.dirname(here)

    if not os.path.isfile(os.path.join(app, 'pubspec.yaml')):
        print('不是 Dart 包目录（没有 pubspec.yaml）: %s' % app)
        return 2

    sdk = find_dart_sdk()
    if sdk is None:
        print('找不到 Dart SDK。请设 FLUTTER_ROOT 或 DART_SDK 环境变量。')
        return 2

    targets = []
    for top in ('lib', 'test', 'tool', 'bin'):
        base = os.path.join(app, top)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            for fn in sorted(filenames):
                if fn.endswith('.dart'):
                    targets.append(os.path.join(dirpath, fn))

    print('Dart SDK: %s' % sdk)
    print('分析 %d 个文件...' % len(targets))

    errfile = open(ERRLOG, 'wb')
    proc = subprocess.Popen(
        [os.path.join(sdk, 'bin', 'dartaotruntime.exe'),
         os.path.join(sdk, 'bin', 'snapshots', 'analysis_server_aot.dart.snapshot'),
         '--protocol=lsp',
         '--client-id=analyze-offline',
         '--client-version=1.0',
         '--dart-sdk', sdk],
        cwd=app, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errfile)

    def send(obj):
        body = json.dumps(obj).encode('utf-8')
        proc.stdin.write(b'Content-Length: %d\r\n\r\n' % len(body))
        proc.stdin.write(body)
        proc.stdin.flush()

    def read_exact(n):
        buf = b''
        while len(buf) < n:
            chunk = proc.stdout.read(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    def read_msg():
        length = None
        while True:
            line = proc.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b'content-length:'):
                length = int(line.split(b':', 1)[1].strip())
        if length is None:
            return None
        raw = read_exact(length)
        return None if raw is None else json.loads(raw.decode('utf-8'))

    inbox = queue.Queue()

    def reader():
        while True:
            try:
                m = read_msg()
            except Exception:
                break
            if m is None:
                break
            inbox.put(m)

    threading.Thread(target=reader, daemon=True).start()

    root_uri = to_uri(app)
    send({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
        'processId': os.getpid(),
        'clientInfo': {'name': 'analyze-offline', 'version': '1.0'},
        'rootUri': root_uri,
        'workspaceFolders': [{'uri': root_uri, 'name': os.path.basename(app)}],
        'capabilities': {
            'textDocument': {'publishDiagnostics': {'relatedInformation': True}},
            'workspace': {'workspaceFolders': True},
        },
    }})

    ready = False
    deadline = time.time() + 240
    while time.time() < deadline:
        try:
            msg = inbox.get(timeout=2)
        except queue.Empty:
            continue
        if msg.get('id') == 1:
            if 'result' in msg:
                ready = True
            else:
                print('initialize 失败: %s' % json.dumps(msg.get('error'), ensure_ascii=False))
                return 3
            break
    if not ready:
        print('initialize 超时；server 日志见 %s' % ERRLOG)
        return 3

    send({'jsonrpc': '2.0', 'method': 'initialized', 'params': {}})

    for path in targets:
        try:
            text = open(path, 'r', encoding='utf-8').read()
        except Exception as exc:
            print('  跳过 %s (%s)' % (path, exc))
            continue
        send({'jsonrpc': '2.0', 'method': 'textDocument/didOpen', 'params': {
            'textDocument': {'uri': to_uri(path), 'languageId': 'dart',
                             'version': 1, 'text': text}}})

    diags = {}
    last = time.time()
    start = time.time()
    quiet = 0
    while True:
        if time.time() - start > 300:
            print('总超时（已有 %d 个文件推送诊断）' % len(diags))
            break
        try:
            msg = inbox.get(timeout=1)
        except queue.Empty:
            if time.time() - last > 45:
                quiet = int(time.time() - last)
                break
            continue
        last = time.time()
        if msg.get('method') == 'textDocument/publishDiagnostics':
            p = msg['params']
            diags[p['uri']] = p.get('diagnostics', [])

    try:
        send({'jsonrpc': '2.0', 'id': 99, 'method': 'shutdown', 'params': None})
        send({'jsonrpc': '2.0', 'method': 'exit', 'params': None})
    except Exception:
        pass
    try:
        proc.wait(timeout=10)
    except Exception:
        proc.kill()

    sev = {1: 'error', 2: 'warning', 3: 'info', 4: 'hint'}
    rows = []
    for uri, items in diags.items():
        path = uri.replace('file:///', '').replace('/', '\\')
        for d in items:
            r = d.get('range', {}).get('start', {})
            rows.append((
                sev.get(d.get('severity', 3), '?'),
                path, r.get('line', 0) + 1, r.get('character', 0) + 1,
                d.get('code', '') or '',
                (d.get('message', '') or '').replace('\n', ' '),
            ))
    rank = {'error': 0, 'warning': 1, 'info': 2, 'hint': 3, '?': 4}
    rows.sort(key=lambda x: (rank.get(x[0], 4), x[1], x[2]))

    print()
    for r in rows:
        print('%s:%d:%d  [%s] %s  %s' % (r[1], r[2], r[3], r[0], r[4], r[5]))
    print()
    counts = Counter(r[0] for r in rows)
    print('汇总: %s  共 %d 条' % (dict(counts) or '{}', len(rows)))
    print('（%d 个文件有诊断推送；静默 %ds 后判定分析完成）' % (len(diags), quiet))
    return 1 if counts.get('error') else 0


if __name__ == '__main__':
    sys.exit(main())
