# 决定性实验：复刻 Dart 的建管道流程，但换不同前缀。
#
# Dart 的 CreateProcessPipe 做两件事：
#   1) CreateNamedPipeW(name, PIPE_ACCESS_INBOUND, ..., nMaxInstances=1, ...)
#   2) CreateFileW(name, GENERIC_WRITE, ..., OPEN_EXISTING, ...)  ← 子进程那端
# 如果第 2 步失败且 GetLastError=231，说明这条管道被别人抢先连走了。
#
# 对比 dart_ 前缀和普通前缀，就能判断是「全局管道故障」还是「针对 dart 的钩子」。
import ctypes
import uuid
from ctypes import wintypes

k32 = ctypes.WinDLL('kernel32', use_last_error=True)

PIPE_ACCESS_INBOUND = 0x00000001
PIPE_TYPE_BYTE = 0x00000000
PIPE_READMODE_BYTE = 0x00000000
PIPE_WAIT = 0x00000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3
INVALID = wintypes.HANDLE(-1).value

k32.CreateNamedPipeW.restype = wintypes.HANDLE
k32.CreateNamedPipeW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
    wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
]
k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
    wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
]


def probe(name):
    """建管道 + 连管道，返回结果字符串。"""
    h = k32.CreateNamedPipeW(
        name,
        PIPE_ACCESS_INBOUND,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        1,  # nMaxInstances —— 单实例，跟 Dart 一致
        0, 0, 0, None,
    )
    if h == INVALID:
        return 'CreateNamedPipe FAIL err=%d' % ctypes.get_last_error()

    c = k32.CreateFileW(name, GENERIC_WRITE, 0, None, OPEN_EXISTING, 0, None)
    if c == INVALID:
        out = 'CreateFile FAIL err=%d' % ctypes.get_last_error()
    else:
        out = 'CreateFile OK'
        k32.CloseHandle(c)
    k32.CloseHandle(h)
    return out


def main():
    u = str(uuid.uuid4())
    cases = [
        ('dart_%s_0  (stdin 影子)' % u, r'\\.\pipe\dart_%s_0' % u),
        ('dart_%s_1  (stdout 影子)' % u, r'\\.\pipe\dart_%s_1' % u),
        ('dart_%s_2  (stderr 影子)' % u, r'\\.\pipe\dart_%s_2' % u),
        ('wbprobe_%s  (普通前缀)' % u[:8], r'\\.\pipe\wbprobe_%s' % u),
        ('一个裸名 no_prefix_%s' % u[:8], r'\\.\pipe\%s' % u),
    ]
    for label, name in cases:
        print('%-28s -> %s' % (label, probe(name)))


if __name__ == '__main__':
    main()
