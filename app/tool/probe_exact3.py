# 第三刀：给管道挂一个显式安全描述符，看默认 DACL 是不是被改坏了。
#
# 若显式 SD 能让 OUTBOUND + READ 成功 -> 问题在「默认 DACL 只给了写、没给读」
# 若显式 SD 仍然 231            -> 问题在更下层（内核过滤驱动）
import ctypes
import uuid
from ctypes import wintypes

k32 = ctypes.WinDLL('kernel32', use_last_error=True)
adv = ctypes.WinDLL('advapi32', use_last_error=True)

PIPE_ACCESS_INBOUND = 0x00000001
PIPE_ACCESS_OUTBOUND = 0x00000002
FILE_FLAG_OVERLAPPED = 0x40000000
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
k32.LocalFree.argtypes = [ctypes.c_void_p]
adv.ConvertStringSecurityDescriptorToSecurityDescriptorW.restype = wintypes.BOOL
adv.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [
    wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p),
    ctypes.POINTER(wintypes.ULONG)]


def make_sd(sddl):
    p = ctypes.c_void_p()
    n = wintypes.ULONG()
    ok = adv.ConvertStringSecurityDescriptorToSecurityDescriptorW(
        sddl, 1, ctypes.byref(p), ctypes.byref(n))
    return p if ok else None


def run(label, server_mode, client_access, client_flags, sddl=None):
    name = r'\\.\pipe\dart_%s_1' % uuid.uuid4()

    sd = make_sd(sddl) if sddl else None
    srv_sa = None
    if sddl:
        if sd is None:
            print('%-46s SDDL 解析失败' % label)
            return
        srv_sa = SA(ctypes.sizeof(SA), ctypes.cast(sd, ctypes.c_void_p), False)

    h = k32.CreateNamedPipeW(
        name, server_mode, 0, 1, 1024, 1024, 0,
        ctypes.byref(srv_sa) if srv_sa else None)
    if h == INVALID:
        print('%-46s 建管道失败 err=%d' % (label, ctypes.get_last_error()))
        if sd:
            k32.LocalFree(ctypes.cast(sd, ctypes.c_void_p))
        return

    cli_sa = SA(ctypes.sizeof(SA), None, True)
    c = k32.CreateFileW(name, client_access, 0, ctypes.byref(cli_sa),
                        OPEN_EXISTING, client_flags, None)
    if c == INVALID:
        print('%-46s 连管道失败 err=%d' % (label, ctypes.get_last_error()))
    else:
        print('%-46s OK' % label)
        k32.CloseHandle(c)
    k32.CloseHandle(h)
    if sd:
        k32.LocalFree(ctypes.cast(sd, ctypes.c_void_p))


def main():
    OV = FILE_FLAG_OVERLAPPED
    READ_FLAGS = FILE_READ_ATTRIBUTES | OV

    run('基准 OUTBOUND + READ（默认 DACL）',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ, READ_FLAGS)

    run('OUTBOUND + READ，SD 显式给 Everyone 完全控制',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ, READ_FLAGS,
        'D:(A;;GA;;;WD)')

    run('OUTBOUND + READ，SD 显式给 Everyone 只读',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ, READ_FLAGS,
        'D:(A;;GR;;;WD)')

    run('OUTBOUND + READ，SD 给 Everyone 读写',
        PIPE_ACCESS_OUTBOUND | OV, GENERIC_READ, READ_FLAGS,
        'D:(A;;GRGW;;;WD)')

    run('对照 INBOUND + WRITE，显式 SD Everyone 完全控制',
        PIPE_ACCESS_INBOUND | OV, GENERIC_WRITE,
        FILE_WRITE_ATTRIBUTES | OV, 'D:(A;;GA;;;WD)')

    run('对照 DUPLEX + READ|WRITE，显式 SD Everyone 完全控制',
        PIPE_ACCESS_OUTBOUND | 0x00000001 | OV,
        GENERIC_READ | GENERIC_WRITE,
        FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES | OV, 'D:(A;;GA;;;WD)')


if __name__ == '__main__':
    main()
