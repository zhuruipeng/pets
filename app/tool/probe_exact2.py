# 第二刀：判断 231 到底是「实例被别人抢先占了」还是「访问模式被拒」。
#
# 判别方法：把 nMaxInstances 从 1 放大到 255。
#   - 若放大后成功  -> 说明有人在 Dart 之前抢连了这条单实例管道（劫持/监听）
#   - 若仍然失败    -> 说明跟实例数无关，是这一对访问模式被系统拒绝
import ctypes
import uuid
from ctypes import wintypes

k32 = ctypes.WinDLL('kernel32', use_last_error=True)

PIPE_ACCESS_INBOUND = 0x00000001
PIPE_ACCESS_OUTBOUND = 0x00000002
PIPE_ACCESS_DUPLEX = 0x00000003
FILE_FLAG_OVERLAPPED = 0x40000000
BYTE_WAIT = 0x00000000
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_READ_ATTRIBUTES = 0x00000080
FILE_WRITE_ATTRIBUTES = 0x00000100
OPEN_EXISTING = 3
INVALID = wintypes.HANDLE(-1).value


class SA(ctypes.Structure):
    _fields_ = [('nLength', wintypes.DWORD),
                ('lpSecurityDescriptor', ctypes.c_void_p),
                ('bInheritHandle', wintypes.BOOL)]


k32.CreateNamedPipeW.restype = wintypes.HANDLE
k32.CreateNamedPipeW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
    wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
k32.CreateFileW.restype = wintypes.HANDLE
k32.CreateFileW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p,
    wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
k32.WaitNamedPipeW.restype = wintypes.BOOL
k32.WaitNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD]


def run(label, server_mode, client_access, client_flags, max_inst=1,
        wait_first=False):
    name = r'\\.\pipe\dart_%s_1' % uuid.uuid4()
    sa = SA(ctypes.sizeof(SA), None, True)

    h = k32.CreateNamedPipeW(name, server_mode, BYTE_WAIT, max_inst,
                             1024, 1024, 0, None)
    if h == INVALID:
        print('%-40s 建管道失败 err=%d' % (label, ctypes.get_last_error()))
        return

    if wait_first:
        ok = k32.WaitNamedPipeW(name, 2000)
        print('   (WaitNamedPipe -> %s)' % ('OK' if ok else
              'err=%d' % ctypes.get_last_error()))

    c = k32.CreateFileW(name, client_access, 0, ctypes.byref(sa),
                        OPEN_EXISTING, client_flags, None)
    if c == INVALID:
        print('%-40s 连管道失败 err=%d' % (label, ctypes.get_last_error()))
    else:
        print('%-40s OK' % label)
        k32.CloseHandle(c)
    k32.CloseHandle(h)


def main():
    OV = FILE_FLAG_OVERLAPPED

    run('1 OUTBOUND + GENERIC_READ（现状）',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ,
        FILE_READ_ATTRIBUTES | OV)

    run('2 OUTBOUND + READ，实例数放大到 255',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ,
        FILE_READ_ATTRIBUTES | OV, max_inst=255)

    run('3 OUTBOUND + READ|WRITE',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ | GENERIC_WRITE,
        FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | OV)

    run('4 OUTBOUND + 纯 READ_DATA(不请求属性)',
        PIPE_ACCESS_OUTBOUND | OV, 0x0001,
        0)

    run('5 DUPLEX + READ|WRITE（对照组）',
        PIPE_ACCESS_DUPLEX | OV, GENERIC_READ | GENERIC_WRITE,
        FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | OV)

    run('6 INBOUND + GENERIC_WRITE（B 的对照组）',
        PIPE_ACCESS_INBOUND | OV, GENERIC_WRITE,
        FILE_WRITE_ATTRIBUTES | OV)

    run('7 OUTBOUND + READ，先 WaitNamedPipe',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ,
        FILE_READ_ATTRIBUTES | OV, wait_first=True)

    run('8 服务端不带 OVERLAPPED 的 DUPLEX 对照',
        PIPE_ACCESS_DUPLEX, GENERIC_READ | GENERIC_WRITE, 0)


if __name__ == '__main__':
    main()
