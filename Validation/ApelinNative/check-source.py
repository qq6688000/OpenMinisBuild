#!/usr/bin/env python3
"""Static evidence only; does not substitute for run-apple.sh or device tests."""
from pathlib import Path
import hashlib,json,re,sys
r=Path(__file__).resolve().parents[2]
d=r/'src/ios/Views/Settings/ApelinNative'
pbx=(r/'src/ios/Minis.xcodeproj/project.pbxproj').read_text()
m=(d/'MinisApelinHelloTransport.m').read_text()
s=(d/'ApelinHelloInspection.swift').read_text()
v=(r/'src/ios/Views/Settings/DevelopmentProjectsView.swift').read_text()
assert re.findall(r'xpc_dictionary_set_string\(request, "op", "([^"]+)"\)',m)==['hello']
for text in ['"wiki.qaq.apelin.service"','"protocolVersion", 2','"requestID"','"payload", "{}", 2','xpc_connection_send_message_with_reply','xpc_connection_cancel','XPC_TYPE_BOOL','262144','"unsupportedVersion"','"denied"','5 * NSEC_PER_SEC']:
 assert text in m,text
assert 'import XPC' not in s
assert 'systemUptime' in s and '< 10' in s
assert 'ApelinHelloInspection()' in v and 'nativeService.cancel()' in v
assert '#import "Views/Settings/ApelinNative/MinisApelinHelloTransport.h"' in (r/'src/ios/MinisApp-Bridging-Header.h').read_text()
for name in ['MinisApelinHelloTransport.m','ApelinHelloInspection.swift']:
 assert name+' in Sources' in pbx
for i in ['001','002','003','011','012','013','014']:
 identifier='D3A500000000000000000'+i
 assert len(re.findall(r'\b'+identifier+r'\s*=',pbx))==1,identifier
assert 'Apelin native notices in Resources' in pbx
assert (d/'LICENSE').read_bytes()==(d/'Notices/Apelin-LICENSE').read_bytes()
assert 'Permission is hereby granted' in (d/'LICENSE').read_text()
if len(sys.argv)>1:
 upstream=Path(sys.argv[1])
 for path,digest in json.loads((d/'Notices/PROVENANCE.json').read_text())['references'].items():
  assert hashlib.sha256((upstream/path).read_bytes()).hexdigest()==digest,path
print('PASS: hello-only wire constants, bounded lifecycle source, Xcode/bridge/license registration and optional upstream hashes (STATIC ONLY)')
