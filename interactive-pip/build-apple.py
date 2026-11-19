#!/usr/bin/env python3
"""Fail-closed macOS/Xcode arm64e build for InteractivePiP.

Uses real Apple ld -fixup_chains. Linux/LLD is structurally incapable of
producing iOS arm64e userland binaries; never patch Mach-O headers here.
"""
import argparse, os, plistlib, re, shutil, struct, subprocess, tempfile
from pathlib import Path
import platform

ROOT = Path(__file__).resolve().parent
INSTALL = '@loader_path/.jbroot/Library/MobileSubstrate/DynamicLibraries/InteractivePiP.dylib'
PREFS_INSTALL = '@loader_path/.jbroot/Library/PreferenceBundles/InteractivePiPPrefs.bundle/InteractivePiPPrefs'
SUBSTRATE = '@loader_path/.jbroot/usr/lib/libsubstrate.dylib'
ROOTHIDE = '@loader_path/.jbroot/usr/lib/libroothide.dylib'
FRAMEWORKS = ('CoreGraphics', 'UIKit', 'Foundation', 'QuartzCore')
DEPLOYMENT = '16.1'
ARM64E = 2
PTRAUTH_ABI = 0x80000000

def require(ok, msg):
    if not ok: raise RuntimeError(msg)

def run(args):
    args = list(map(str, args))
    print('+ ' + ' '.join(args), flush=True)
    r = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, check=True)
    if r.stdout: print(r.stdout, end='' if r.stdout.endswith('\n') else '\n')
    return r.stdout.strip()

def packed_version(text):
    m = re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', text)
    require(m, f'Invalid SDK version {text!r}')
    parts = [int(x) for x in text.split('.')]
    parts += [0]*(3-len(parts))
    return (parts[0]<<16)|(parts[1]<<8)|parts[2]

class MachO:
    def __init__(self, path, kind, need_auth=True):
        d = path.read_bytes()
        magic,cpu,sub,ftype,ncmds,sizeofcmds,_,_ = struct.unpack_from('<8I', d, 0)
        require((magic,cpu,sub&0xffffff,ftype)==(0xfeedfacf,0x100000c,ARM64E,kind),
                f'{path}: expected thin arm64e type {kind}, got {magic:#x}/{cpu:#x}/{sub:#x}/{ftype}. NO HEADER PATCHING.')
        if need_auth:
            require((sub & 0xff000000)==PTRAUTH_ABI,
                    f'{path}: unsupported arm64e ABI flags {sub&0xff000000:#010x}; expected versioned userland ABI 0')
        self.d=d; self.path=path
        off=32; self.commands={}
        for _ in range(ncmds):
            cmd,sz=struct.unpack_from('<II',d,off)
            require(sz>=8 and off+sz<=32+sizeofcmds,'Invalid load command bounds')
            self.commands.setdefault(cmd,[]).append(off)
            off+=sz
        require(off==32+sizeofcmds,'Load command size mismatch')

    def has_chained(self):
        return 0x80000034 in self.commands or 0x34 in self.commands

    def fixup_formats(self):
        """Return (imports_format, set(segment_pointer_formats))."""
        offs = self.commands.get(0x80000034,[]) + self.commands.get(0x34,[])
        if not offs: return (None,set())
        off=offs[0]; do,ds=struct.unpack_from('<II',self.d,off+8)
        h=self.d[do:do+ds]
        # dyld_chained_fixups_header: fixups_version,starts_offset,imports_offset,
        # symbols_offset,imports_count,imports_format,symbols_format
        _,_,_,_,icnt,ifmt,_=struct.unpack_from('<7I',h,0)
        si=do+struct.unpack_from('<I',h,4)[0]
        sc=struct.unpack_from('<I',self.d,si)[0]
        fmts=set()
        for s in range(sc):
            so=struct.unpack_from('<I',self.d,si+4+4*s)[0]
            if so:
                # dyld_chained_starts_in_segment: size(4),page_size(2),pointer_format(2)
                fmts.add(struct.unpack_from('<H',self.d,si+so+6)[0])
        return (ifmt,fmts)

    def validate(self):
        require(self.has_chained(), f'{self.path}: missing LC_DYLD_CHAINED_FIXUPS')
        require(not any(c in self.commands for c in (0x80000022,0x22)),
                f'{self.path}: classic LC_DYLD_INFO present alongside chained')
        ifmt,fmts=self.fixup_formats()
        # Pointer formats are independent of the imports table encoding.
        # Apple Xcode 16.x ld uses ARM64E_USERLAND24 (ptrformat 12) for
        # rebased pointers and ARM64E_USERLAND (9) on older linkers.
        # imports_format: 1=DYLD_CHAINED_IMPORT, 2=DYLD_CHAINED_IMPORT_ADDEND.
        require(ifmt in (1,2), f'{self.path}: imports format {ifmt}, expected DYLD_CHAINED_IMPORT[_ADDEND](1/2)')
        require(bool(fmts) and all(f in (1,9,12) for f in fmts),
                f'{self.path}: segment pointer formats {fmts}, expected ARM64E userland (1/9/12)')

def main():
    args = argparse.ArgumentParser().parse_args()
    require(platform.system()=='Darwin','macOS + full Xcode required; Linux/LLD cannot build arm64e')
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
    require('PROJECT:ld-' in ldv and 'LLD' not in ldv,'Real Apple ld required (not LLD)')
    signer='/usr/bin/codesign'
    dpkg=shutil.which('dpkg-deb')
    require(dpkg,'Missing dpkg-deb')

    # Headers: vendored RootHide + Preferences stubs (no private framework in SDK).
    inc=[ROOT/'vendor/libroothide', ROOT/'vendor/include', ROOT/'Sources', ROOT/'Preferences', ROOT/'Preferences/vendor/include']
    # logos preprocessor for Tweak.x
    logos=ROOT/'vendor/logos/bin/logos.pl'
    require(logos.is_file(),f'Missing logos.pl at {logos}')

    common=['-arch','arm64e',f'-miphoneos-version-min={DEPLOYMENT}','-isysroot',str(sdk),
            '-fobjc-arc','-fblocks','-fno-modules','-fPIC','-O2','-g0',
            '-Wno-deprecated-declarations','-Wno-unused-variable','-Wno-nullability-completeness',
            '-fvisibility=hidden']
    for i in inc: common.extend(['-I',str(i)])

    with tempfile.TemporaryDirectory(prefix='ipp-apple-') as td:
        work=Path(td)
        objs=[]
        # 1) expand Tweak.x -> Tweak.mm via logos
        tweak_mm=work/'Tweak.mm'
        with tweak_mm.open('w') as f:
            subprocess.run(['perl',str(logos),'-c','generator=MobileSubstrate',str(ROOT/'Sources/Tweak.x')],
                           stdout=f,check=True)
        # 2) compile all Sources .m + Tweak.mm
        for src in sorted((ROOT/'Sources').glob('*.m')):
            o=work/(src.stem+'.o')
            run([*xcrun,'clang',*common,'-c',str(src),'-o',str(o)]);objs.append(o)
        o=work/'Tweak.o'
        run([*xcrun,'clang',*common,'-x','objective-c++','-c',str(tweak_mm),'-o',str(o)]);objs.append(o)
        for o in objs: MachO(o,1)

        dylib=work/'InteractivePiP.dylib'
        link=[tools['ld'],'-dylib','-arch','arm64e','-platform_version','ios',DEPLOYMENT,sdkversion,
              '-syslibroot',str(sdk),'-fixup_chains','-install_name',INSTALL,
              '-o',str(dylib),*objs,'-L',str(ROOT/'vendor'),'-lsubstrate','-lroothide','-lSystem','-lobjc']
        for fw in FRAMEWORKS: link.extend(['-framework',fw])
        run(link)
        MachO(dylib,6).validate()
        print('main dylib: arm64e + ARM64E chained fixups OK')

        # 3) PreferenceBundle (same true arm64e; Settings dlopen requires it)
        prefs=[]
        for src in sorted((ROOT/'Preferences').glob('*.m')):
            o=work/('Prefs_'+src.stem+'.o')
            run([*xcrun,'clang',*common,'-c',str(src),'-o',str(o)]);prefs.append(o)
            MachO(o,1)
        prefs_bin=work/'InteractivePiPPrefs'
        # bundle: MH_BUNDLE(8), undefined dynamic_lookup for Preferences superclass
        link=[tools['ld'],'-bundle','-arch','arm64e','-platform_version','ios',DEPLOYMENT,sdkversion,
              '-syslibroot',str(sdk),'-fixup_chains','-undefined','dynamic_lookup',
              '-install_name',PREFS_INSTALL,'-o',str(prefs_bin),*prefs,
              '-L',str(ROOT/'vendor'),'-lroothide','-lSystem','-lobjc']
        for fw in FRAMEWORKS: link.extend(['-framework',fw])
        run(link)
        MachO(prefs_bin,8).validate()
        print('prefs bundle: arm64e + ARM64E chained fixups OK')

        # 4) codesign all
        for f in (dylib,prefs_bin):
            run([signer,'--force','--sign','-','--timestamp=none',str(f)])
            run([signer,'--verify','--strict','--verbose=2',str(f)])

        # 5) stage deb
        stage=work/'stage'
        dl=stage/'Library/MobileSubstrate/DynamicLibraries';dl.mkdir(parents=True)
        pb=stage/'Library/PreferenceBundles/InteractivePiPPrefs.bundle';pb.mkdir(parents=True)
        pl=stage/'Library/PreferenceLoader/Preferences';pl.mkdir(parents=True)
        (stage/'DEBIAN').mkdir()
        shutil.copyfile(dylib,dl/dylib.name)
        (dl/'InteractivePiP.plist').write_bytes(plistlib.dumps(
            {'Filter':{'Bundles':['com.apple.springboard'],'Executables':['SpringBoard']}},fmt=plistlib.FMT_XML))
        shutil.copyfile(prefs_bin,pb/prefs_bin.name)
        (pb/'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleDevelopmentRegion':'zh_CN','CFBundleExecutable':'InteractivePiPPrefs',
            'CFBundleIdentifier':'com.seagull.interactivepip.prefs','CFBundleInfoDictionaryVersion':'6.0',
            'CFBundlePackageType':'BNDL','CFBundleShortVersionString':'0.5.1','CFBundleVersion':'9',
            'NSPrincipalClass':'DPRootListController'},fmt=plistlib.FMT_XML))
        shutil.copyfile(ROOT/'Preferences/Resources/Root.plist',pb/'Root.plist')
        (pl/'InteractivePiP.plist').write_bytes(plistlib.dumps({
            'entry':{'bundle':'InteractivePiPPrefs','cell':'PSLinkCell','detail':'DPRootListController',
                     'isController':True,'label':'交互分屏 PiP'}},fmt=plistlib.FMT_XML))
        shutil.copyfile(ROOT/'control',stage/'DEBIAN/control')
        doc=stage/'usr/share/doc/com.seagull.interactivepip';doc.mkdir(parents=True)
        for name in ('LICENSE','THIRD_PARTY_NOTICES.md','README.md'):
            shutil.copyfile(ROOT/name,doc/name)
        shutil.copytree(ROOT/'LICENSES',doc/'LICENSES')
        for cur,_,files in os.walk(stage):
            os.chmod(cur,0o755)
            for n in files:
                p=Path(cur)/n
                os.chmod(p,0o755 if p.name in ('InteractivePiP.dylib','InteractivePiPPrefs') else 0o644)
        out=ROOT/'dist-apple';out.mkdir(exist_ok=True)
        deb=out/'InteractivePiP_Duo_0.5.1_iphoneos-arm64e.deb'
        run([dpkg,'--root-owner-group','-Zgzip','--build',str(stage),str(deb)])
        print(f'Built {deb} ({deb.stat().st_size} bytes); NOT device-validated.')

if __name__=='__main__':
    try: main()
    except subprocess.CalledProcessError as e:
        if e.stdout: print(e.stdout)
        raise
