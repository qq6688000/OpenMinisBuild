#!/usr/bin/env python3
"""Run the SAME C extraction core as iOS; optionally verify real archive payloads."""
import io, os, pathlib, subprocess, sys, tarfile, tempfile, hashlib
repo = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    c = root/'probe.c'
    c.write_text('#include "NativeBuildExtract.h"\nint main(int c,char **v){if(c!=4)return 2; NBExtractResult r=NBExtractCore(v[1],v[2],v[3]); printf("ok=%d entries=%llu bytes=%llu dirs=%llu links=%llu stage=%s errno=%d path=%s detail=%s\\n",r.ok,r.entries,r.bytes,r.directories,r.symlinks,r.stage,r.error_number,r.path,r.detail); return !r.ok;}\n')
    exe=root/'probe'
    subprocess.run(['cc','-Wall','-Wextra','-Werror','-I'+str(repo/'src/ios/NativeOffloads'),str(c),'-larchive','-o',str(exe)],check=True)
    def run(archive,dest,strip='Toolchain',ok=True):
        dest.mkdir(exist_ok=True)
        p=subprocess.run([str(exe),str(archive),str(dest),strip],capture_output=True,text=True)
        assert (p.returncode==0)==ok,p.stdout+p.stderr
        print(p.stdout.strip()); return p.stdout
    def fixture(name,items,ok,setup=None):
        arc=root/(name+'.tar'); dest=root/name
        with tarfile.open(arc,'w') as t:
            for path,kind,value in items:
                x=tarfile.TarInfo(path); x.type=kind; x.mode=0o755
                if kind==tarfile.REGTYPE:
                    data=value.encode(); x.size=len(data); t.addfile(x,io.BytesIO(data))
                else: x.linkname=value; t.addfile(x)
        dest.mkdir()
        if setup: setup(dest)
        run(arc,dest,ok=ok)
        return dest
    D=tarfile.DIRTYPE; F=tarfile.REGTYPE; L=tarfile.SYMTYPE
    fixture('trailing',[('Toolchain/',D,''),('Toolchain//./bin/',D,''),('Toolchain/bin/clang',F,'hello')],True)
    for i,path in enumerate(['/','/Toolchain/','/Toolchain/bin/a','Toolchain/../a','../a','Toolchain/a/../../x']):
        fixture('unsafe'+str(i),[(path,D,'')],False)
    fixture('rootfile',[('Toolchain',F,'x')],False)
    fixture('hardlink',[('Toolchain/x',tarfile.LNKTYPE,'Toolchain/y')],False)
    fixture('fifo',[('Toolchain/x',tarfile.FIFOTYPE,'')],False)
    for i,target in enumerate(['/tmp/escape','../../escape']):
        fixture('badlink'+str(i),[('Toolchain/a/link',L,target)],False)
    fixture('pivot',[('Toolchain/dir',D,''),('Toolchain/link',L,'dir'),('Toolchain/link/x',F,'x')],False)
    outside=root/'outside'; outside.mkdir(); sentinel=outside/'x'; sentinel.write_text('untouched')
    fixture('existingpivot',[('Toolchain/link/x',F,'bad')],False,lambda d: os.symlink(outside,d/'link'))
    fixture('existinghard',[('Toolchain/x',F,'new')],True,lambda d: os.link(sentinel,d/'x'))
    assert sentinel.read_text()=='untouched'
    fixture('goodlink',[('Toolchain/a',D,''),('Toolchain/x',F,'ok'),('Toolchain/a/l',L,'../x')],True)
    bad=root/'bad.tgz'; bad.write_bytes(b'not an archive'); run(bad,root/'bad',ok=False)
    for arg in sys.argv[1:]:
        arc=pathlib.Path(arg)
        with tarfile.open(arc) as t:
            members=t.getmembers(); strip=members[0].name.rstrip('/')
            # Match production: tools in bundle; SDK in an independent cache.
            # Destination must depend on archive layout, not archive filename.
            dest=(root/'Minis.app'/'Toolchain' if strip == 'Toolchain'
                  else root/'Library'/'Caches'/'native-toolchain'/strip)
            dest.parent.mkdir(parents=True, exist_ok=True)
            run(arc,dest,strip); run(arc,dest,strip)
            if strip == 'iPhoneOS16.5.sdk':
                assert not (root/'Minis.app'/strip).exists()
            files=links=0
            t.close()
            t = tarfile.open(arc, 'r|gz')
            for m in t:
                parts=m.name.split('/')[1:]
                p=dest.joinpath(*parts)
                if m.isfile():
                    with p.open('rb') as actual, t.extractfile(m) as expected:
                        assert hashlib.file_digest(actual,'sha256').digest()==hashlib.file_digest(expected,'sha256').digest(),m.name
                    assert p.stat().st_mode&0o777 == m.mode&0o777,m.name
                    files+=1
                elif m.issym(): assert p.is_symlink() and os.readlink(p)==m.linkname,m.name; links+=1
                elif m.isdir(): assert p.is_dir(),m.name
            print('PAYLOAD+MODE+LINK PASS',arc.name,files,links)
    print('ALL PASS')
