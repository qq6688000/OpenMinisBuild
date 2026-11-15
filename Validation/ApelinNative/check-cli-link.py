#!/usr/bin/env python3
"""Run fixed native link argv against SDK; execute actual C inspector on host."""
from pathlib import Path
import ctypes as C
import os, re, struct, subprocess, tempfile
r = Path(__file__).resolve().parents[2]
n = r / 'src/ios/NativeOffloads'
sdk = os.environ.get('SDKROOT', '/opt/theos/sdks/iPhoneOS16.5.sdk')
cc = os.environ.get('CLANG', 'clang')
ld = os.environ.get('LD64', 'ld64.lld')
class Info(C.Structure):
    _fields_ = [('exists', C.c_bool), ('valid', C.c_bool), ('size', C.c_ulonglong),
                ('arch', C.c_char*16), ('filetype', C.c_char*16),
                ('dependency_count', C.c_uint), ('dependencies', (C.c_char*256)*32),
                ('pie', C.c_bool), ('has_main', C.c_bool), ('has_ios_build', C.c_bool),
                ('min_ios', C.c_uint), ('has_code_signature', C.c_bool),
                ('signature_size', C.c_ulonglong), ('signature_blobs', C.c_uint),
                ('code_directory_size', C.c_ulonglong), ('error', C.c_char*48)]
with tempfile.TemporaryDirectory(prefix='cli-link-') as tmp:
    p = Path(tmp)
    subprocess.run(['sh', str(r/'Validation/ApelinNative/check-cli-compile.sh'), tmp], check=True)
    source = (n/'NativeCLICompile.inc').read_text()
    # Consume production argv, failing closed on any new dynamic expression.
    declaration = source.split('const char *linkArgs[] = {',1)[1].split('};',1)[0]
    tokens = re.findall(r'"(?:[^"\\]|\\.)*"|[A-Za-z][A-Za-z.]*', declaration)
    args = []
    for token in tokens:
        if token == 'NULL': continue
        if token == 'linker.fileSystemRepresentation': args.append(ld)
        elif token == 'sdk.fileSystemRepresentation': args.append(sdk)
        elif token.startswith('"'): args.append(token[1:-1])
        else: raise AssertionError('unexpected dynamic link argument: '+token)
    assert args[1:] == ['-arch','arm64','-platform_version','ios','16.0','16.5','-syslibroot',sdk,'-pie','-e','_main','-no_adhoc_codesign','main.o','-lSystem','-lobjc','-framework','Foundation','-o','hello-cli']
    subprocess.run(args, cwd=p, check=True)
    subprocess.run([cc,'-shared','-fPIC','-Wall','-Wextra','-Werror',str(n/'NativeBuildMachOCore.c'),'-o',str(p/'inspect.so')], check=True)
    lib = C.CDLL(str(p/'inspect.so'))
    lib.NBMachOParse.argtypes = [C.c_void_p,C.c_size_t,C.POINTER(Info)]
    def inspect(data):
        i=Info(); buf=C.create_string_buffer(data)
        lib.NBMachOParse(buf,len(data),C.byref(i)); return i
    data=(p/'hello-cli').read_bytes(); i=inspect(data)
    assert i.valid and i.arch==b'arm64' and i.filetype==b'executable'
    assert i.pie and i.has_main and i.has_ios_build and i.min_ios==0x100000
    assert not i.has_code_signature
    deps={bytes(i.dependencies[j]).split(b'\0')[0].decode() for j in range(i.dependency_count)}
    required={'/usr/lib/libSystem.B.dylib','/usr/lib/libobjc.A.dylib','/System/Library/Frameworks/Foundation.framework/Foundation'}
    assert required <= deps <= required | {'/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation'}
    # Malformed dependency offsets and missing terminating NUL must fail closed.
    off=32
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        cmd,size=struct.unpack_from('<II',data,off)
        if cmd==12:
            bad=bytearray(data); struct.pack_into('<I',bad,off+8,size)
            assert not inspect(bytes(bad)).valid
            bad=bytearray(data); nameoff=struct.unpack_from('<I',bad,off+8)[0]
            bad[off+nameoff:off+size]=b'X'*(size-nameoff)
            assert not inspect(bytes(bad)).valid
            break
        off+=size
    else: raise AssertionError('no dependency command')
    print('PASS: production fixed linker argv; arm64 iOS MH_EXECUTE, PIE, LC_MAIN, unsigned; dependencies:', sorted(deps))
    print('PASS: host actual Mach-O core rejects invalid dependency offsets / unterminated names; iOS adapter strict compile/link')
    print('LIMIT: no device launch, signing, install, full Swift/Xcode build, or runtime claim')
