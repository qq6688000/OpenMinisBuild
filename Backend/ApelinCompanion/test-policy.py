#!/usr/bin/env python3
"""Compile the real pure C policy on host; never claim device API validation."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile

BASE = Path(__file__).resolve().parent
HARNESS = r'''
#include "PeerPolicy.h"
#include <stdio.h>
int main(void) {
    unsigned char actual[20], expected[20];
    for (int i=0; i<20; i++) actual[i]=expected[i]=(unsigned char)(i+1);
    int cases=0;
#define CHECK(label, want, uid, id, act, exp, len, client, sandbox, valid) do { \
    int got=minis_peer_allowed(uid,id,act,exp,len,client,sandbox,valid); \
    if(got != want) {fprintf(stderr,"FAIL: %s\n",label); return 1;} cases++; \
} while(0)
    CHECK("mobile",1,501,"com.openminis.app",actual,expected,20,1,1,1);
    CHECK("root",1,0,"com.openminis.app",actual,expected,20,1,1,1);
    CHECK("other uid",0,502,"com.openminis.app",actual,expected,20,1,1,1);
    CHECK("no identity",0,501,NULL,actual,expected,20,1,1,1);
    CHECK("wrong identity",0,501,"com.openminis.app.evil",actual,expected,20,1,1,1);
    CHECK("null actual",0,501,"com.openminis.app",NULL,expected,20,1,1,1);
    CHECK("null pin",0,501,"com.openminis.app",actual,NULL,20,1,1,1);
    CHECK("short hash",0,501,"com.openminis.app",actual,expected,19,1,1,1);
    CHECK("long hash",0,501,"com.openminis.app",actual,expected,21,1,1,1);
    CHECK("missing client",0,501,"com.openminis.app",actual,expected,20,0,1,1);
    CHECK("missing sandbox",0,501,"com.openminis.app",actual,expected,20,1,0,1);
    CHECK("invalid signature",0,501,"com.openminis.app",actual,expected,20,1,1,0);
    CHECK("nonboolean",0,501,"com.openminis.app",actual,expected,20,2,1,1);
    for(int i=0; i<20; i++) {
        actual[i]^=1;
        CHECK("each hash byte",0,501,"com.openminis.app",actual,expected,20,1,1,1);
        actual[i]^=1;
    }
    memset(actual,0,20); memset(expected,0,20);
    CHECK("zero pin",0,501,"com.openminis.app",actual,expected,20,1,1,1);
    printf("PASS: %d C policy allow/deny cases; inputs are test observations only.\n",cases);
    return 0;
}
'''

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--cc', default='cc')
    a = p.parse_args(argv)
    with tempfile.TemporaryDirectory(prefix='minis-policy-') as tmp:
        root=Path(tmp)
        source=root/'policy.c'
        source.write_text(HARNESS)
        subprocess.run([a.cc,'-std=c11','-Wall','-Wextra','-Werror','-pedantic','-I',str(BASE),str(source),'-o',str(root/'policy')],check=True)
        subprocess.run([str(root/'policy')],check=True)
    for name in ['prepare.py','package.py']:
        spec=importlib.util.spec_from_file_location('prototype_'+name, BASE/name)
        module=importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        assert callable(module.main)
    result=subprocess.run(['python3',str(BASE/'package.py'),'unused','unused','unused'],capture_output=True,text=True)
    assert result.returncode != 0 and 'NON-DEPLOYABLE' in result.stderr
    print('PASS: import-safe main() entry points; prototype packaging rejects by default.')
    print('UNVERIFIED: kernel APIs, trust root, signatures, audit token, device authentication.')

if __name__ == '__main__':
    main()
