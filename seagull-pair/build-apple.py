#!/usr/bin/env python3
"""Fail-closed macOS/Xcode build; never downloads, installs or rewrites headers."""
import argparse
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
INSTALL = '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/SeagullPair.dylib'
SUBSTRATE = '@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
FRAMEWORKS = ('CoreGraphics', 'UIKit', 'Foundation', 'QuartzCore')
DEPLOYMENT = '16.1'
# Supported iOS userland arm64e ABI, independent of the SDK release number.
# mach/machine.h: ARM64E = 2, PTRAUTH_ABI = 0x80000000.
# Keep unknown capability/ABI bits closed until their semantics are verified.
ARM64E = 2
PTRAUTH_ABI = 0x80000000
SUPPORTED_ABI_FLAGS = {PTRAUTH_ABI}  # Versioned userland ABI version 0.


def packed_version(text):
    """Parse Apple's major[.minor[.patch]] into Mach-O xxxx.yy.zz."""
    require(re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', text),
            f'Invalid Apple SDK version: {text!r}')
    parts = list(map(int, text.split('.')))
    parts += [0] * (3 - len(parts))
    major, minor, patch = parts
    require(major <= 0xffff and minor <= 0xff and patch <= 0xff,
            f'Apple SDK version cannot fit LC_BUILD_VERSION: {text!r}')
    return (major << 16) | (minor << 8) | patch


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def run(args):
    args = list(map(str, args))
    print('+ ' + ' '.join(args), flush=True)
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=True)
    if result.stdout:
        print(result.stdout, end='' if result.stdout.endswith('\n') else '\n')
    return result.stdout.strip()


class MachO:
    def __init__(self, path, kind):
        self.data = path.read_bytes()
        magic, cpu, subtype, filetype, count, size, _, _ = self.unpack('<8I', 0)
        require((magic, cpu, subtype & 0xffffff, filetype) ==
                (0xfeedfacf, 0x100000c, ARM64E, kind),
                f'{path}: expected thin arm64e, type {kind}; '
                f'got {magic:#x}/{cpu:#x}/{subtype:#x}/{filetype}. No header patching.')
        abi_flags = subtype & 0xff000000
        require(abi_flags in SUPPORTED_ABI_FLAGS,
                f'{path}: unsupported arm64e capability/ABI flags {abi_flags:#010x}; '
                'expected versioned userland ABI version 0 (0x80000000). '
                'Unversioned, kernel and unknown ABI encodings require review.')
        self.commands, self.sections, self.segments, self.names = {}, [], [], {}
        offset = 32
        self.slice(offset, size)
        for _ in range(count):
            cmd, length = self.unpack('<II', offset)
            require(length >= 8 and length % 8 == 0 and offset + length <= 32 + size,
                    'Invalid Mach-O command bounds')
            self.commands[cmd] = offset
            if cmd == 0x19:
                require(length >= 72, 'Truncated segment')
                vm, vmsize, fileoff, filesize = self.unpack('<4Q', offset + 24)
                nsects = self.unpack('<I', offset + 64)[0]
                require(72 + nsects * 80 <= length, 'Invalid section count')
                self.segments.append((vm, vmsize, fileoff, filesize))
                for i in range(nsects):
                    s = offset + 72 + i * 80
                    addr, sz, off, _, reloc, nreloc = self.unpack('<QQ4I', s + 32)
                    self.sections.append((addr, sz, off, reloc, nreloc))
            if cmd in (0xc, 0xd, 0x80000018, 0x8000001f):
                start = self.unpack('<I', offset + 8)[0]
                require(24 <= start < length, 'Invalid dylib name offset')
                self.names[self.cstring(offset + start, offset + length)] = cmd
            offset += length
        require(offset == 32 + size, 'Load command size mismatch')

    def slice(self, offset, size):
        require(offset >= 0 and size >= 0 and offset + size <= len(self.data),
                'Truncated Mach-O data')
        return self.data[offset:offset + size]

    def unpack(self, fmt, offset):
        return struct.unpack(fmt, self.slice(offset, struct.calcsize(fmt)))

    def cstring(self, offset, end=None):
        end = len(self.data) if end is None else end
        raw = self.slice(offset, end - offset)
        require(b'\0' in raw, 'Unterminated Mach-O string')
        return raw.split(b'\0', 1)[0].decode('utf-8')

    def symbols(self):
        require(2 in self.commands, 'Missing symbol table')
        symoff, count, stroff, strsize = self.unpack('<4I', self.commands[2] + 8)
        self.slice(stroff, strsize)
        result = {}
        for i in range(count):
            name, typ, sect, _, value = self.unpack('<IBBHQ', symoff + i * 16)
            require(name < strsize, 'Invalid symbol string index')
            result[self.cstring(stroff + name, stroff + strsize)] = (i, typ, sect, value)
        return result

    def version(self, expected_sdk):
        require(0x32 in self.commands, 'Missing LC_BUILD_VERSION')
        command = self.commands[0x32]
        _, length, plat, minimum, sdk, ntools = self.unpack('<6I', command)
        require(length == 24 + ntools * 8, 'Invalid LC_BUILD_VERSION size/tool count')
        require(expected_sdk >= packed_version(DEPLOYMENT), 'SDK is older than deployment target')
        require((plat, minimum, sdk) == (2, packed_version(DEPLOYMENT), expected_sdk),
                f'Expected iOS minimum {DEPLOYMENT}, selected SDK {expected_sdk:#x}; '
                f'got platform/minimum/SDK {plat}/{minimum:#x}/{sdk:#x}')

    def linked(self, expected_sdk):
        self.version(expected_sdk)
        require(self.names.get(INSTALL) == 0xd, 'Incorrect LC_ID_DYLIB')
        require(self.names.get(SUBSTRATE) == 0xc, 'Incorrect RootHide substrate load path')
        for name in FRAMEWORKS:
            require(self.names.get(f'/System/Library/Frameworks/{name}.framework/{name}') == 0xc,
                    f'Missing required framework: {name}')
        for name, cmd in self.names.items():
            if cmd != 0xd:
                require(name == SUBSTRATE or name.startswith(('/usr/lib/', '/System/Library/')),
                        f'Unexpected dependency: {name}')

    def auth_object(self):
        symbols = self.symbols()
        for slot, target in (('_local_pointer', '_local_target'),
                             ('_external_pointer', '_getpid')):
            require(slot in symbols and target in symbols, f'Missing probe symbol {slot}/{target}')
            _, _, section, value = symbols[slot]
            require(0 < section <= len(self.sections), 'Invalid probe section')
            addr, size, off, reloc, count = self.sections[section - 1]
            delta = value - addr
            require(0 <= delta <= size - 8, 'Probe slot outside section')
            matches = []
            for i in range(count):
                address, bits = self.unpack('<iI', reloc + i * 8)
                if address == delta:
                    matches.append(bits)
            require(len(matches) == 1, f'{slot}: expected one authenticated relocation')
            bits = matches[0]
            require((bits >> 28, (bits >> 27) & 1, (bits >> 25) & 3,
                     (bits >> 24) & 1, bits & 0xffffff) ==
                    (11, 1, 3, 0, symbols[target][0]),
                    f'{slot}: missing ARM64_RELOC_AUTHENTICATED_POINTER to {target}')
            require(self.unpack('<Q', off + delta)[0] == 0x8000000000000000,
                    f'{slot}: expected IA key, zero discriminator/addend, no address diversity')

    def auth_linked(self):
        require(0x80000034 in self.commands, 'Missing LC_DYLD_CHAINED_FIXUPS')
        base, length = self.unpack('<2I', self.commands[0x80000034] + 8)
        self.slice(base, length)
        def u(fmt, relative):
            require(0 <= relative and relative + struct.calcsize(fmt) <= length,
                    'Chained fixup bounds error')
            return self.unpack(fmt, base + relative)
        version, starts, imports, strings, count, form, strform = u('<7I', 0)
        require(version == 0 and strform == 0 and form in (1, 2),
                'Unsupported chained fixup/import encoding')
        names = []
        for i in range(count):
            record = u('<I', imports + i * (4 if form == 1 else 8))[0]
            nameoff = strings + (record >> 9)
            require(nameoff < length, 'Invalid chained import name')
            names.append(self.cstring(base + nameoff, base + length))
        symbols = self.symbols()
        require(all(n in symbols for n in ('_local_pointer', '_external_pointer', '_local_target')),
                'Probe symbols missing from linked image')
        wanted = {symbols[n][3]: n for n in ('_local_pointer', '_external_pointer')}
        image = min(vm for vm, _, _, size in self.segments if size)
        found = set()
        segcount = u('<I', starts)[0]
        require(segcount == len(self.segments), 'Chained segment count mismatch')
        for index in range(segcount):
            relative = u('<I', starts + 4 + index * 4)[0]
            if not relative:
                continue
            pos = starts + relative
            size, page_size, ptrformat, segment_offset, maxptr, pages = u('<IHHQIH', pos)
            require(ptrformat in (9, 12) and page_size in (4096, 16384) and maxptr == 0,
                    f'Unsupported iOS arm64e userland chain format {ptrformat}')
            require(size >= 22 + pages * 2 and pos + size <= length, 'Invalid chain start size')
            vm, _, fileoff, filesize = self.segments[index]
            require(vm == image + segment_offset, 'Segment offset mismatch')
            for page in range(pages):
                start = u('<H', pos + 22 + page * 2)[0]
                if start == 0xffff:
                    continue
                require(not start & 0x8000, 'Multi-start chain unsupported; fail closed')
                cursor = page * page_size + start
                while True:
                    require(page * page_size <= cursor and cursor + 8 <= (page + 1) * page_size
                            and cursor + 8 <= filesize, 'Chain escaped its page/segment')
                    raw = self.unpack('<Q', fileoff + cursor)[0]
                    address = vm + cursor
                    if address in wanted:
                        name = wanted[address]
                        require(raw >> 63 == 1 and ((raw >> 49) & 3) == 0
                                and ((raw >> 48) & 1) == 0 and ((raw >> 32) & 0xffff) == 0,
                                f'{name}: missing expected authenticated IA fixup')
                        bind = (raw >> 62) & 1
                        if name == '_local_pointer':
                            require(bind == 0 and image + (raw & 0xffffffff) == symbols['_local_target'][3],
                                    'Local pointer is not an authenticated rebase to local_target')
                        else:
                            mask = 0xffffff if ptrformat == 12 else 0xffff
                            ordinal = raw & mask
                            require(bind == 1 and (raw & 0xffffffff) == ordinal
                                    and ordinal < len(names) and names[ordinal] == '_getpid',
                                    'External pointer is not an authenticated bind to getpid')
                        found.add(name)
                    delta = ((raw >> 51) & 0x7ff) * 8
                    if not delta:
                        break
                    cursor += delta
        require(found == set(wanted.values()), 'Both authenticated probe slots must appear in chains')

    def signed(self):
        require(0x1d in self.commands, 'Missing LC_CODE_SIGNATURE')
        offset, size = self.unpack('<2I', self.commands[0x1d] + 8)
        require(size > 0, 'Empty signature')
        self.slice(offset, size)


PROBE = r'''#include <unistd.h>
#include <ptrauth.h>
#if !defined(__arm64e__) || !__has_feature(ptrauth_calls)
#error Apple arm64e pointer authentication is required
#endif
__attribute__((noinline, visibility("hidden"))) int local_target(void) { return 7; }
int (* __ptrauth(ptrauth_key_function_pointer, 0, 0) local_pointer)(void) = local_target;
pid_t (* __ptrauth(ptrauth_key_function_pointer, 0, 0) external_pointer)(void) = getpid;
__attribute__((noinline)) int probe_call(void) {
    return local_pointer() + external_pointer();
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--smoke', action='store_true', help='ABI/signature probe only; no package')
    parser.add_argument('--signer', choices=('codesign', 'ldid'), default='codesign')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist-apple')
    args = parser.parse_args()
    require(platform.system() == 'Darwin',
            'macOS with full Xcode Apple toolchain required; Linux/LLD is not supported')
    require(Path('/usr/bin/xcrun').is_file(), 'Missing /usr/bin/xcrun')
    xcrun = ['/usr/bin/xcrun', '--sdk', 'iphoneos']
    developer = Path(run(['/usr/bin/xcode-select', '-p']))
    if os.environ.get('DEVELOPER_DIR'):
        developer = Path(os.environ['DEVELOPER_DIR']).resolve()
        if developer.suffix == '.app':
            developer = developer / 'Contents/Developer'
    require((developer / 'Platforms/iPhoneOS.platform').is_dir(), 'Select full Xcode, not CommandLineTools')
    sdk = Path(run([*xcrun, '--show-sdk-path'])).resolve()
    sdkversion = run([*xcrun, '--show-sdk-version'])
    sdk_packed = packed_version(sdkversion)
    require(sdk_packed >= packed_version(DEPLOYMENT),
            f'iPhoneOS SDK >= {DEPLOYMENT} required, got {sdkversion}; select a newer full Xcode')
    print(f'Building for iOS {DEPLOYMENT} with iPhoneOS SDK {sdkversion}', flush=True)
    require(str(sdk).startswith(str(developer.resolve()) + '/'), 'SDK must belong to selected Xcode')
    for name in FRAMEWORKS:
        require((sdk / f'System/Library/Frameworks/{name}.framework/Headers').is_dir(),
                f'Missing SDK headers for {name}')
    tools = {}
    for name in ('clang', 'ld'):
        tool = Path(run([*xcrun, '--find', name])).resolve()
        require(str(tool).startswith(str(developer.resolve()) + '/'),
                f'{name} is outside selected Xcode')
        tools[name] = tool
    require('Apple clang version' in run([tools['clang'], '--version']), 'Apple clang required')
    ldversion = run([tools['ld'], '-v'])
    require('PROJECT:ld-' in ldversion and 'LLD' not in ldversion, 'Real Apple ld required')
    signer = '/usr/bin/codesign' if args.signer == 'codesign' else shutil.which('ldid')
    require(signer and Path(signer).is_file(), f'Missing signer: {args.signer}')
    dpkg = shutil.which('dpkg-deb')
    if not args.smoke:
        require(dpkg, 'Missing dpkg-deb (install dpkg separately)')
        require('--root-owner-group' in run([dpkg, '--help']), 'dpkg-deb lacks --root-owner-group')
        require((ROOT / 'PairTweak.m').is_file(), 'Missing PairTweak.m')
    stub = (ROOT / 'vendor/libsubstrate.tbd').read_text()
    require(re.search(r"install-name:\s*['\"]?" + re.escape(SUBSTRATE) + r"['\"]?\s*$", stub, re.M),
            'substrate stub has wrong RootHide install-name')
    require(re.search(r'archs:\s*\[\s*arm64e\s*\]', stub) and
            re.search(r'platform:\s*ios\s*$', stub, re.M), 'Expected iOS arm64e substrate stub')
    require((ROOT / 'vendor/substrate.h').is_file(), 'Missing substrate header')
    flags = ['-arch', 'arm64e', f'-miphoneos-version-min={DEPLOYMENT}', '-isysroot', sdk,
             '-fobjc-arc', '-fblocks', '-I', ROOT / 'vendor', '-Werror=implicit-function-declaration']

    def compile_file(source, output, extra):
        run([*xcrun, 'clang', *flags, *extra, source, '-o', output])

    def link(obj, output):
        command = [tools['ld'], '-dylib', '-arch', 'arm64e', '-platform_version', 'ios', DEPLOYMENT, sdkversion,
                   '-syslibroot', sdk, '-fixup_chains', '-install_name', INSTALL,
                   '-o', output, obj, '-L', ROOT / 'vendor', '-lsubstrate', '-lSystem', '-lobjc']
        for framework in FRAMEWORKS:
            command.extend(['-framework', framework])
        run(command)
        MachO(output, 6).linked(sdk_packed)

    def sign(output, probe=False):
        if args.signer == 'codesign':
            run([signer, '--force', '--sign', '-', '--timestamp=none', output])
            run([signer, '--verify', '--strict', '--verbose=2', output])
        else:
            run([signer, '-Cadhoc', '-S', output])
            # Require native verification too; a load command alone is not proof.
            run(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', output])
        binary = MachO(output, 6)
        binary.linked(sdk_packed)
        binary.signed()
        if probe:
            binary.auth_linked()

    with tempfile.TemporaryDirectory(prefix='seagull-apple-') as tmp:
        work = Path(tmp)
        source, asm, obj, dylib = [work / ('probe' + suffix) for suffix in ('.m', '.s', '.o', '.dylib')]
        source.write_text(PROBE)
        compile_file(source, asm, ['-O0', '-S'])
        assembly = asm.read_text()
        require(all(re.search(pattern, assembly) for pattern in
                    (r'\bpacibsp\b', r'\bblraa[z]?\b', r'\bretab\b')),
                'Authenticated indirect-call/return code generation missing')
        compile_file(source, obj, ['-O0', '-c'])
        MachO(obj, 1).auth_object()
        link(obj, dylib)
        MachO(dylib, 6).auth_linked()
        sign(dylib, probe=True)
        if args.smoke:
            print('Apple ABI/signature smoke passed. No package built; device runtime remains untested.')
            return
        obj, dylib = work / 'PairTweak.o', work / 'SeagullPair.dylib'
        # PairTweak.m imports PairPanel.m; compiling both separately would duplicate symbols.
        compile_file(ROOT / 'PairTweak.m', obj, ['-O2', '-c'])
        MachO(obj, 1)
        link(obj, dylib)
        sign(dylib)
        stage = work / 'stage'
        target = stage / 'Library/MobileSubstrate/DynamicLibraries'
        target.mkdir(parents=True)
        (stage / 'DEBIAN').mkdir()
        control = (ROOT / 'control').read_text()
        fields = dict(re.findall(r'^([A-Za-z][A-Za-z-]*):[ \t]*(.*)$', control, re.M))
        require(fields.get('Architecture') == 'iphoneos-arm64e', 'Incorrect control architecture')
        package, version = fields.get('Package', ''), fields.get('Version', '')
        require(re.fullmatch(r'[a-z0-9][a-z0-9+.-]+', package) and
                re.fullmatch(r'[0-9][A-Za-z0-9.+:~\-]*', version), 'Invalid package/version')
        shutil.copyfile(ROOT / 'control', stage / 'DEBIAN/control')
        shutil.copyfile(dylib, target / dylib.name)
        (target / 'SeagullPair.plist').write_bytes(plistlib.dumps(
            {'Filter': {'Bundles': ['com.apple.springboard']}}, fmt=plistlib.FMT_XML))
        for current, _, files in os.walk(stage):
            os.chmod(current, 0o755)
            for name in files:
                os.chmod(Path(current) / name, 0o755 if name.endswith('.dylib') else 0o644)
        filename = f'{package}_{version}_iphoneos-arm64e.deb'
        archive = work / filename
        run([dpkg, '--root-owner-group', '-Zgzip', '--build', stage, archive])
        require(run([dpkg, '--field', archive, 'Architecture']) == 'iphoneos-arm64e',
                'Packaged architecture mismatch')
        args.output.mkdir(parents=True, exist_ok=True)
        # Atomic publication only after every check. No existing file is a success signal.
        fd, pending = tempfile.mkstemp(prefix='.apple-package-', dir=args.output)
        try:
            with os.fdopen(fd, 'wb') as stream, archive.open('rb') as src:
                shutil.copyfileobj(src, stream)
            os.chmod(pending, 0o644)
            os.replace(pending, args.output / filename)
        finally:
            if os.path.exists(pending):
                os.unlink(pending)
        print(f'Built {args.output / filename}; not installed or device-validated.')


if __name__ == '__main__':
    try:
        main()
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout)
        raise SystemExit(f'BUILD FAILED (exit {error.returncode}); no new package published')
    except (OSError, RuntimeError, ValueError, struct.error) as error:
        raise SystemExit(f'BUILD FAILED: {error}; no new package published')
