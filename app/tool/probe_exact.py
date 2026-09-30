# 逐个参数复刻 Dart 的 CreateProcessPipe，二分出到底哪个参数触发 231。
#
# 源出处（flutter_engine/third_party/dart/runtime/bin/process_win.cc）：
#   stdin 分支 (kInheritRead):
#     CreateNamedPipeW(name, PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
#                      PIPE_TYPE_BYTE | PIPE_WAIT, 1, 1024, 1024, 0, nullptr)
#     CreateFileW(name, GENERIC_READ, 0, &sa(bInherit=TRUE), OPEN_EXISTING,
#                 FILE_READ_ATTRIBUTES | FILE_FLAG_OVERLAPPED, nullptr)
#   stdout/stderr 分支 (kInheritWrite):
#     CreateNamedPipeW(name, PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED, ...)
#     CreateFileW(name, GENERIC_WRITE, 0, &sa(bInherit=TRUE), OPEN_EXISTING,
#                 FILE_WRITE_ATTRIBUTES | FILE_FLAG_OVERLAPPED, nullptr)
import ctypes
import uuid
from ctypes import wintypes

k32 = ctypes.WinDLL('kernel32', use_last_error=True)

PIPE_ACCESS_INBOUND = 0x00000001
PIPE_ACCESS_OUTBOUND = 0x00000002
FILE_FLAG_OVERLAPPED = 0x40000000
PIPE_TYPE_BYTE = 0x00000000
PIPE_WAIT = 0x00000000
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_READ_ATTRIBUTES = 0x00000080
FILE_WRITE_ATTRIBUTES = 0x00000100
OPEN_EXISTING = 3
INVALID = wintypes.HANDLE(-1).value


class SECURITY_ATTRIBUTES(ctypes.Structure):
    _fields_ = [
        ('nLength', wintypes.DWORD),
        ('lpSecurityDescriptor', ctypes.c_void_p),
        ('bInheritHandle', wintypes.BOOL),
    ]


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


def run(label, server_mode, server_pipe_mode, client_access,
        use_sa, client_flags):
    name = r'\\.\pipe\dart_%s_1' % uuid.uuid4()
    sa = SECURITY_ATTRIBUTES(
        ctypes.sizeof(SECURITY_ATTRIBUTES), None, True,
    ) if use_sa else None

    h = k32.CreateNamedPipeW(name, server_mode, server_pipe_mode, 1,
                             1024, 1024, 0, None)
    if h == INVALID:
        print('%-42s 建管道失败 err=%d' % (label, ctypes.get_last_error()))
        return

    c = k32.CreateFileW(name, client_access, 0, ctypes.byref(sa) if sa else None,
                        OPEN_EXISTING, client_flags, None)
    if c == INVALID:
        print('%-42s 连管道失败 err=%d  <== 复现' % (label, ctypes.get_last_error()))
    else:
        print('%-42s OK' % label)
        k32.CloseHandle(c)
    k32.CloseHandle(h)


def main():
    BYTE_WAIT = PIPE_TYPE_BYTE | PIPE_WAIT

    # A: stdin 分支，完全照抄
    run('A stdin 全套参数（照抄源码）',
        PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED, BYTE_WAIT,
        GENERIC_READ, True, FILE_READ_ATTRIBUTES | FILE_FLAG_OVERLAPPED)

    # B: stdout 分支，完全照抄
    run('B stdout 全套参数（照抄源码）',
        PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED, BYTE_WAIT,
        GENERIC_WRITE, True, FILE_WRITE_ATTRIBUTES | FILE_FLAG_OVERLAPPED)

    # C: stdin 分支，但客户端不加任何 flags
    run('C stdin + 客户端 flags=0',
        PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED, BYTE_WAIT,
        GENERIC_READ, True, 0)

    # D: stdin 分支，但不传 SECURITY_ATTRIBUTES
    run('D stdin + 不传 SECURITY_ATTRIBUTES',
        PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED, BYTE_WAIT,
        GENERIC_READ, False, FILE_READ_ATTRIBUTES | FILE_FLAG_OVERLAPPED)

    # E: stdin 分支，但服务端不带 FILE_FLAG_OVERLAPPED
    run('E stdin + 服务端不带 OVERLAPPED',
        PIPE_ACCESS_OUTBOUND, BYTE_WAIT,
        GENERIC_READ, True, FILE_READ_ATTRIBUTES | FILE_FLAG_OVERLAPPED)

    # F: 只客户端带 OVERLAPPED，服务端不带
    run('F stdin + 客户端只带 OVERLAPPED',
        PIPE_ACCESS_OUTBOUND, BYTE_WAIT,
        GENERIC_READ, True, FILE_FLAG_OVERLAPPED)


if __name__ == '__main__':
    main()
