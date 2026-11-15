#!/usr/bin/env python3
"""Offline, fail-closed experimental RootHide build. Never installs anything."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
SDK = Path('/opt/theos/sdks/iPhoneOS16.5.sdk')
INSTALL = '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/SeagullPair.dylib'
SUBSTRATE = '@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
NAME = 'com.minis.seagullpair_0.1.0_iphoneos-arm64e.deb'
FLAGS = ['-target', 'arm64e-apple-ios16.1', '-isysroot', str(SDK),
         '-fobjc-arc', '-fblocks', '-fptrauth-calls', '-fptrauth-returns',
         '-fptrauth-intrinsics', '-I', str(ROOT / 'vendor')]


def run(args):
    print('+ ' + ' '.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout


def macho(path, kind):
    data = path.read_bytes()
    if len(data) < 32:
        raise RuntimeError(f'{path}: truncated Mach-O')
    magic, cpu, subtype, filetype, count, size, _, _ = struct.unpack_from('<8I', data)
    if (magic, cpu, subtype & 0xffffff, filetype) != (0xfeedfacf, 0x100000c, 2, kind):
        raise RuntimeError(f'{path.name}: expected genuine arm64e Mach-O type {kind}; '
                           f'got magic={magic:#x}, cpu={cpu:#x}, subtype={subtype:#x}, type={filetype}. '
                           'No header rewriting is permitted; fix the toolchain.')
    names, signed = [], False
    offset = 32
    if offset + size > len(data):
        raise RuntimeError('truncated load commands')
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > 32 + size:
            raise RuntimeError('invalid load command')
        if cmd in (0xc, 0xd, 0x80000018, 0x8000001f):
            start = struct.unpack_from('<I', data, offset + 8)[0]
            names.append(data[offset + start:offset + length].split(b'\0')[0].decode())
        signed |= cmd == 0x1d
        offset += length
    return names, signed


def link(ld, obj, out):
    print(run([ld, '-dylib', '-arch', 'arm64e', '-platform_version', 'ios', '16.1', '16.5',
               '-syslibroot', SDK, '-install_name', INSTALL, '-o', out, obj,
               '-L', ROOT / 'vendor', '-lsubstrate', '-lSystem', '-lobjc',
               '-framework', 'UIKit', '-framework', 'Foundation', '-framework', 'QuartzCore',
               '-framework', 'CoreGraphics']))
    names, _ = macho(out, 6)
    for expected in (INSTALL, SUBSTRATE):
        if expected not in names:
            raise RuntimeError(f'Missing load command: {expected}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke', action='store_true', help='temporary independent ABI probe; no package')
    args = parser.parse_args()
    tools = {n: shutil.which(n) for n in ('clang', 'ld64.lld', 'ldid', 'dpkg-deb')}
    if not all(tools.values()) or not SDK.is_dir():
        raise RuntimeError('Required local tools or iPhoneOS16.5.sdk missing; no downloads attempted')
    version = run([tools['clang'], '--version'])
    print(version)
    if not re.search(r'clang version 19\.', version):
        raise RuntimeError('This build requires clang 19')
    print(run([tools['ld64.lld'], '--version']))
    source = ROOT / 'PairTweak.m'
    if not args.smoke and not source.is_file():
        raise RuntimeError('PairTweak.m is missing; supply the parent-owned source first')
    with tempfile.TemporaryDirectory(prefix='seagull-pair-', dir='/tmp') as tmp:
        work = Path(tmp)
        probe = work / 'abi.m'
        probe.write_text('#if !__has_feature(ptrauth_calls)\n#error Missing ptrauth calls\n#endif\n'
                         'int probe(int (*f)(int), int x) { return f(x)+1; }\n')
        asm, obj, dylib = work / 'abi.s', work / 'abi.o', work / 'abi.dylib'
        print(run([tools['clang'], *FLAGS, '-S', probe, '-o', asm]))
        assembly = asm.read_text()
        if not all(re.search(pattern, assembly) for pattern in
                   (r'\bpacibsp\b', r'\bblraa[z]?\b', r'\bretab\b')):
            raise RuntimeError('Pointer-authentication code generation probe failed')
        print(run([tools['clang'], *FLAGS, '-c', probe, '-o', obj]))
        macho(obj, 1)
        link(tools['ld64.lld'], obj, dylib)
        if args.smoke:
            print(run([tools['ldid'], '-Cadhoc', '-S', dylib]))
            if not macho(dylib, 6)[1]:
                raise RuntimeError('Signature load command missing')
            print('ABI smoke passed; no production source or package built. Device ABI remains untested.')
            return
        obj, dylib = work / 'PairTweak.o', work / 'SeagullPair.dylib'
        print(run([tools['clang'], *FLAGS, '-O2', '-c', source, '-o', obj]))
        macho(obj, 1)
        link(tools['ld64.lld'], obj, dylib)
        print(run([tools['ldid'], '-Cadhoc', '-S', dylib]))
        if not macho(dylib, 6)[1]:
            raise RuntimeError('Signature load command missing')
        stage = work / 'stage'
        target = stage / 'Library/MobileSubstrate/DynamicLibraries'
        target.mkdir(parents=True)
        (stage / 'DEBIAN').mkdir()
        shutil.copyfile(ROOT / 'control', stage / 'DEBIAN/control')
        shutil.copyfile(dylib, target / 'SeagullPair.dylib')
        (target / 'SeagullPair.plist').write_bytes(plistlib.dumps(
            {'Filter': {'Bundles': ['com.apple.springboard']}}, fmt=plistlib.FMT_XML))
        for current, dirs, files in os.walk(stage):
            os.chmod(current, 0o755)
            for name in files:
                os.chmod(Path(current) / name, 0o755 if name.endswith('.dylib') else 0o644)
        archive = work / NAME
        print(run([tools['dpkg-deb'], '--root-owner-group', '-Zgzip', '--build', stage, archive]))
        destination = ROOT / 'dist'
        destination.mkdir(exist_ok=True)
        pending = destination / (NAME + '.tmp')
        shutil.copyfile(archive, pending)
        os.replace(pending, destination / NAME)
        print(f'Built {destination / NAME}; not installed. Existing old dist files are not build evidence.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or '', flush=True)
        raise SystemExit(f'BUILD FAILED (exit {error.returncode}); no package published')
    except (OSError, RuntimeError, ValueError) as error:
        raise SystemExit(f'BUILD FAILED: {error}')
