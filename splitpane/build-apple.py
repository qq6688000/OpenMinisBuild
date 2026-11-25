#!/usr/bin/env python3
"""Fail-closed macOS/Xcode arm64e build for SplitPane.

Uses real Apple ld -fixup_chains. The installed Linux LLVM/LLD 19 path is
not an Apple arm64e release toolchain; never patch Mach-O headers here.
"""
import argparse, os, plistlib, re, shlex, shutil, struct, subprocess, tempfile
from pathlib import Path
import platform

ROOT = Path(__file__).resolve().parent
INSTALL = '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/SplitPane.dylib'
FRAMEWORKS = ('CoreGraphics', 'UIKit', 'Foundation', 'CoreFoundation', 'QuartzCore')
# Settings loads Preferences.framework. Only its superclass/ivar symbols may
# resolve dynamically; unrelated unresolved symbols must remain link errors.
PREFS_DYNAMIC_SYMBOLS = ('_OBJC_CLASS_$_PSListController',
                         '_OBJC_METACLASS_$_PSListController',
                         '_OBJC_IVAR_$_PSListController._specifiers')
DEPLOYMENT = '16.1'
ARM64E = 2
PTRAUTH_ABI = 0x80000000

def require(ok, msg):
    if not ok: raise RuntimeError(msg)

def run(args):
    args = list(map(str, args))
    print('+ ' + shlex.join(args), flush=True)
    r = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, check=True)
    if r.stdout: print(r.stdout, end='' if r.stdout.endswith('\n') else '\n')
    return r.stdout.strip()

def packed_version(text):
    m = re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', text)
    require(m, f'Invalid SDK version {text!r}')
    parts = [int(x) for x in text.split('.')]
    parts += [0]*(3-len(parts))
    require(parts[0]<=65535 and parts[1]<=255 and parts[2]<=255,
            f'SDK version out of Mach-O range: {text}')
    return (parts[0]<<16)|(parts[1]<<8)|parts[2]

def package_metadata():
    """Fail closed instead of silently compiling a mismatched 'dev' release."""
    fields = {}
    for line in (ROOT/'control').read_text().splitlines():
        if not line or line[0].isspace():
            continue
        key, sep, value = line.partition(':')
        require(sep and key not in fields, f'Invalid/duplicate control field: {key}')
        fields[key] = value.strip()
    for key in ('Package', 'Version', 'Architecture'):
        require(fields.get(key), f'Missing control {key}')
    require(fields['Architecture'] == 'iphoneos-arm64e',
            'This builder requires control Architecture: iphoneos-arm64e')
    version = fields['Version']
    require(re.fullmatch(r'[0-9][A-Za-z0-9.+:~\-]*', version), 'Invalid control Version')
    numeric = re.match(r'(?:[0-9]+:)?([0-9]+(?:\.[0-9]+){0,2})(?=[+~\-]|$)', version)
    require(numeric, 'Version needs a numeric upstream version for bundle metadata')
    parts = numeric.group(1).split('.')
    fields['BundleVersion'] = '.'.join(parts + ['0']*(3-len(parts)))
    return fields


def source_files(directory):
    sources = sorted((ROOT/directory).rglob('*.m'))
    require(sources, f'No Objective-C sources in {directory}')
    unexpected = sorted(p for p in (ROOT/directory).rglob('*')
                        if p.suffix in ('.mm', '.c', '.cc', '.cpp', '.cxx', '.s', '.S'))
    require(not unexpected, f'Add explicit language/link flags for: {unexpected}')
    return sources


class MachO:
    def __init__(self, path, kind, need_auth=True):
        d = Path(path).read_bytes()
        self.d=d; self.path=path
        magic,cpu,sub,ftype,ncmds,sizeofcmds,_,_ = self.unpack('<8I', 0)
        require((magic,cpu,sub&0xffffff,ftype)==(0xfeedfacf,0x100000c,ARM64E,kind),
                f'{path}: expected thin arm64e type {kind}, got {magic:#x}/{cpu:#x}/{sub:#x}/{ftype}. NO HEADER PATCHING.')
        if need_auth:
            require((sub & 0xff000000)==PTRAUTH_ABI,
                    f'{path}: unsupported arm64e ABI flags {sub&0xff000000:#010x}; expected versioned userland ABI 0')
        end=32+sizeofcmds
        require(end<=len(d) and ncmds<=sizeofcmds//8, f'{path}: invalid load command area')
        off=32; self.commands={}; self.command_sizes={}
        for _ in range(ncmds):
            cmd,sz=self.unpack('<II',off,end)
            require(sz>=8 and sz%8==0 and off+sz<=end, f'{path}: invalid load command bounds')
            self.commands.setdefault(cmd,[]).append(off)
            self.command_sizes[off]=sz
            off+=sz
        require(off==end, f'{path}: load command size mismatch')

    def unpack(self, fmt, off, end=None):
        if end is None: end=len(self.d)
        require(0<=off and off+struct.calcsize(fmt)<=end<=len(self.d),
                f'{self.path}: truncated/out-of-bounds Mach-O data at {off}')
        return struct.unpack_from(fmt,self.d,off)

    def has_chained(self):
        return 0x80000034 in self.commands

    def fixup_formats(self):
        """Return (imports_format, set(segment_pointer_formats)), checking bounds."""
        offs=self.commands.get(0x80000034,[])
        require(len(offs)==1, f'{self.path}: expected one LC_DYLD_CHAINED_FIXUPS')
        off=offs[0]
        do,ds=self.unpack('<II',off+8,off+self.command_sizes[off])
        end=do+ds
        require(ds>=28 and end<=len(self.d), f'{self.path}: invalid fixups data bounds')
        version,starts,imports,symbols,icnt,ifmt,sfmt=self.unpack('<7I',do,end)
        require(version==0 and sfmt in (0,1), f'{self.path}: unsupported fixups header')
        width={1:4,2:8,3:16}.get(ifmt)
        require(width is not None, f'{self.path}: unsupported chained imports format {ifmt}')
        require(symbols<=ds and imports<=ds and icnt*width<=ds-imports,
                f'{self.path}: chained imports/symbols out of bounds')
        require(starts>=28, f'{self.path}: invalid chained starts offset')
        si=do+starts
        sc,=self.unpack('<I',si,end)
        require(sc<=(end-si-4)//4, f'{self.path}: invalid fixup segment count')
        fmts=set()
        for s in range(sc):
            so,=self.unpack('<I',si+4+4*s,end)
            if so:
                seg=si+so
                size,_,pfmt,_,_,pages=self.unpack('<IHHQIH',seg,end)
                require(size>=22+2*pages and seg+size<=end,
                        f'{self.path}: invalid chained segment bounds')
                fmts.add(pfmt)
        return (ifmt,fmts)

    def validate(self, require_signature=False):
        require(self.has_chained(), f'{self.path}: missing LC_DYLD_CHAINED_FIXUPS')
        require(not any(c in self.commands for c in (0x80000022,0x22)),
                f'{self.path}: classic LC_DYLD_INFO present alongside chained')
        builds=self.commands.get(0x32,[])
        require(len(builds)==1, f'{self.path}: expected one LC_BUILD_VERSION')
        off=builds[0]
        target,minimum,sdk,_=self.unpack('<4I',off+8,off+self.command_sizes[off])
        require(target==2 and minimum==packed_version(DEPLOYMENT) and sdk>=minimum,
                f'{self.path}: expected iOS {DEPLOYMENT} device platform')
        ifmt,fmts=self.fixup_formats()
        # Import table encoding and segment pointer format are independent.
        # 1/2/3 are IMPORT / IMPORT_ADDEND / IMPORT_ADDEND64; the supported
        # ARM64E segment formats are 1, USERLAND(9), USERLAND24(12).
        require(ifmt in (1,2,3), f'{self.path}: unsupported imports format {ifmt}')
        require(bool(fmts) and all(f in (1,9,12) for f in fmts),
                f'{self.path}: segment pointer formats {fmts}, expected ARM64E (1/9/12)')
        if require_signature:
            signatures=self.commands.get(0x1d,[])
            require(len(signatures)==1, f'{self.path}: missing/duplicate code signature')
            off=signatures[0]
            start,size=self.unpack('<II',off+8,off+self.command_sizes[off])
            require(size>0 and start+size<=len(self.d), f'{self.path}: invalid code signature bounds')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check-toolchain', action='store_true',
                        help='Check Xcode/tool identities only; does not prove a product build')
    args = parser.parse_args()
    metadata = package_metadata()
    version = metadata['Version']
    main_sources = source_files('Sources')
    prefs_sources = source_files('Preferences')
    plistlib.loads((ROOT/'Preferences/Resources/Root.plist').read_bytes())
    require(platform.system()=='Darwin',
            'macOS + full Xcode required for this release builder; Linux LLVM/LLD 19 is not supported')
    require(Path('/usr/bin/xcrun').is_file(),'Missing xcrun')
    xcrun=['/usr/bin/xcrun','--sdk','iphoneos']
    developer=Path(run(['/usr/bin/xcode-select','-p']))
    if os.environ.get('DEVELOPER_DIR'):
        developer=Path(os.environ['DEVELOPER_DIR']).resolve()
        if developer.suffix=='.app': developer=developer/'Contents/Developer'
    require((developer/'Platforms/iPhoneOS.platform').is_dir(),'Select full Xcode, not CLT')
    sdk=Path(run([*xcrun,'--show-sdk-path'])).resolve()
    sdkversion=run([*xcrun,'--show-sdk-version'])
    require(packed_version(sdkversion)>=packed_version(DEPLOYMENT),
            f'iPhoneOS SDK >= {DEPLOYMENT} required, got {sdkversion}')
    print(f'Building iOS {DEPLOYMENT} with SDK {sdkversion}',flush=True)
    tools={}
    for n in ('clang','ld'):
        t=Path(run([*xcrun,'--find',n])).resolve()
        require(str(t).startswith(str(developer.resolve())+'/'),f'{n} outside Xcode')
        tools[n]=t
    require('Apple clang version' in run([tools['clang'],'--version']),'Apple clang required')
    ldv=run([tools['ld'],'-v'])
    require(re.search(r'PROJECT:ld(?:64)?-', ldv) and 'LLD' not in ldv,
            'Real Apple ld required (not LLD)')
    signer='/usr/bin/codesign'
    require(Path(signer).is_file(), 'Missing Apple codesign')
    dpkg=shutil.which('dpkg-deb')
    require(dpkg,'Missing dpkg-deb')
    if args.check_toolchain:
        print('Tool identities checked; compile/link/sign/device validation still required.')
        return

    inc=[ROOT/'vendor/include', ROOT/'Sources', ROOT/'Preferences', ROOT/'Preferences/vendor/include']

    common=['-arch','arm64e',f'-miphoneos-version-min={DEPLOYMENT}','-isysroot',str(sdk),
            '-fobjc-arc','-fblocks','-fno-modules','-fPIC','-O2','-g0',
            '-Wno-deprecated-declarations','-Wno-unused-variable','-Wno-nullability-completeness',
            '-Wno-objc-multiple-method-names','-Wno-unguarded-availability-new',
            '-fvisibility=hidden']
    # One control Version drives the runtime macro, bundle metadata, and deb.
    common.extend([f'-DSP_VERSION="{version}"', '-DSDK16'])
    for i in inc: common.extend(['-I',str(i)])

    with tempfile.TemporaryDirectory(prefix='splitpane-apple-') as td:
        work=Path(td); objs=[]
        for src in main_sources:
            o=work/'objects'/src.relative_to(ROOT).with_suffix('.o')
            o.parent.mkdir(parents=True, exist_ok=True)
            run([tools['clang'],*common,'-c',str(src),'-o',str(o)]);objs.append(o)
        for o in objs: MachO(o,1)

        dylib=work/'SplitPane.dylib'
        link=[tools['ld'],'-dylib','-arch','arm64e','-platform_version','ios',DEPLOYMENT,sdkversion,
              '-syslibroot',str(sdk),'-fixup_chains','-install_name',INSTALL,
              '-o',str(dylib),*objs,'-L',str(ROOT/'vendor'),'-lSystem','-lobjc']
        for fw in FRAMEWORKS: link.extend(['-framework',fw])
        run(link)
        MachO(dylib,6).validate()
        print('main dylib: arm64e + ARM64E chained fixups OK')

        prefs=[]
        for src in prefs_sources:
            o=work/'objects'/src.relative_to(ROOT).with_suffix('.o')
            o.parent.mkdir(parents=True, exist_ok=True)
            run([tools['clang'],*common,'-c',str(src),'-o',str(o)]);prefs.append(o)
            MachO(o,1)
        prefs_bin=work/'SplitPanePrefs'
        link=[tools['ld'],'-bundle','-arch','arm64e','-platform_version','ios',DEPLOYMENT,sdkversion,
              '-syslibroot',str(sdk),'-fixup_chains','-undefined','error',
              '-o',str(prefs_bin),*prefs,'-lSystem','-lobjc']
        for symbol in PREFS_DYNAMIC_SYMBOLS: link.extend(['-U',symbol])
        for fw in FRAMEWORKS: link.extend(['-framework',fw])
        run(link)
        MachO(prefs_bin,8).validate()
        print('prefs bundle: arm64e + ARM64E chained fixups OK')

        for f,kind in ((dylib,6),(prefs_bin,8)):
            run([signer,'--force','--sign','-','--timestamp=none',str(f)])
            run([signer,'--verify','--strict','--verbose=2',str(f)])
            MachO(f,kind).validate(require_signature=True)

        stage=work/'stage'
        dl=stage/'Library/MobileSubstrate/DynamicLibraries';dl.mkdir(parents=True)
        pb=stage/'Library/PreferenceBundles/SplitPanePrefs.bundle';pb.mkdir(parents=True)
        pl=stage/'Library/PreferenceLoader/Preferences';pl.mkdir(parents=True)
        (stage/'DEBIAN').mkdir()
        shutil.copyfile(dylib,dl/dylib.name)
        (dl/'SplitPane.plist').write_bytes(plistlib.dumps(
            {'Filter':{'Bundles':['com.apple.springboard']}},fmt=plistlib.FMT_XML))
        shutil.copyfile(prefs_bin,pb/prefs_bin.name)
        (pb/'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleDevelopmentRegion':'zh_CN','CFBundleExecutable':'SplitPanePrefs',
            'CFBundleIdentifier':'com.seagull.splitpane.prefs','CFBundleInfoDictionaryVersion':'6.0',
            'CFBundlePackageType':'BNDL','CFBundleShortVersionString':metadata['BundleVersion'],
            'CFBundleVersion':metadata['BundleVersion'],'SPDebianVersion':version,
            'NSPrincipalClass':'SPRootListController'},fmt=plistlib.FMT_XML))
        shutil.copyfile(ROOT/'Preferences/Resources/Root.plist',pb/'Root.plist')
        (pl/'SplitPane.plist').write_bytes(plistlib.dumps({
            'entry':{'bundle':'SplitPanePrefs','cell':'PSLinkCell','detail':'SPRootListController',
                     'isController':True,'label':'SplitPane 上下分屏'}},fmt=plistlib.FMT_XML))
        shutil.copyfile(ROOT/'control',stage/'DEBIAN/control')
        for cur,_,files in os.walk(stage):
            os.chmod(cur,0o755)
            for n in files:
                p=Path(cur)/n
                os.chmod(p,0o755 if p.name in ('SplitPane.dylib','SplitPanePrefs') else 0o644)
        out=ROOT/'dist-apple';out.mkdir(exist_ok=True)
        deb=out/f"SplitPane_{version}_{metadata['Architecture']}.deb"
        # Publish atomically: a failed dpkg invocation must not leave a new,
        # partial .deb in the artifact glob. Keep prior valid builds untouched.
        with tempfile.TemporaryDirectory(prefix='.package-',dir=out) as pd:
            pending=Path(pd)/deb.name
            run([dpkg,'--root-owner-group','-Zgzip','--build',str(stage),str(pending)])
            for field in ('Package','Version','Architecture'):
                require(run([dpkg,'--field',str(pending),field])==metadata[field],
                        f'Packaged {field} does not match control')
            os.replace(pending,deb)
        print(f'Built {deb} ({deb.stat().st_size} bytes); NOT device-validated.')

if __name__=='__main__':
    try: main()
    except subprocess.CalledProcessError as e:
        if e.stdout: print(e.stdout)
        raise
