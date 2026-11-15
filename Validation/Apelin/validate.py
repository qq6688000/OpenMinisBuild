#!/usr/bin/env python3
"""Offline reference validation. Does not execute or type-check the Swift adapter."""
import copy, hashlib, json, plistlib, re, subprocess, sys, tempfile, uuid
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
sys.dont_write_bytecode=True
sys.path.insert(0,str(HERE/'Schemas/Tools'))
import apelin_schema as schema
ASSETS=ROOT/'src/ios/Views/Settings/ApelinTemplates'
provenance=json.loads((ASSETS/'PROVENANCE.json').read_text())
for record in provenance['files']:
 assert hashlib.sha256((ROOT/record['vendored']).read_bytes()).hexdigest()==record['sha256'],record['vendored']
print('PASS: 121 upstream source/resource/schema/fixture files match provenance hashes')
selected={'app':'uikit-objc','cli':'objc','tweak':'objc-hook','preferences':'objc-bundle'}
count=0
with tempfile.TemporaryDirectory() as temp:
 for kind, tid in selected.items():
  ext=ASSETS/('wiki.qaq.apelin.dev.'+kind); manifest=schema.load_json(ext/'manifest.json')
  assert not schema.validate_manifest(manifest)
  for template in manifest['templates']:
   assert not schema.check_template(ext,template),template['id']
  template=next(t for t in manifest['templates'] if t['id']==tid)
  for name in ['Hello','hello-cli','hello_cli','A'+'x'*47]:
   values={'projectName':name,'projectID':str(uuid.uuid4()),'bundleID':'com.example.'+name.lower().replace('_','-'),'packageID':'com.example.'+name.lower().replace('_','-'),'deploymentTarget':'16.0','architectures':{'rootless':['arm64','arm64e'],'roothide':['arm64e']},'templateExtensionID':manifest['id'],'templateID':tid,'templateVersion':manifest['version'],'templateDigest':template['digest'],'toolchainID':'minis-unbound-toolchain','sdkID':'minis-unbound-sdk','toolchainDigest':'sha256:'+'0'*64,'sdkDigest':'sha256:'+'0'*64,'productName':name.replace('-','_'),'displayName':name,'summary':'Created from an Apelin template in Minis.','author':'Minis User'}
   destination=Path(temp)/f'{kind}-{name}'
   schema.instantiate(ext,manifest,template,values,destination)
   project=schema.load_json(destination/'apelin-project.json')
   assert not schema.validate_project(project)
   assert project['kind']==kind and project['template']['digest']==template['digest']
   for entry in template['files']:
    data=(destination/entry['path']).read_bytes()
    if entry['format']=='copy': assert data==(ext/template['directory']/entry['path']).read_bytes()
    else: assert b'{{' not in data
    if entry['format']=='plist-xml': plistlib.loads(data)
   invalid=copy.deepcopy(project); invalid['products'].append(copy.deepcopy(project['products'][0]))
   assert schema.validate_project(invalid),'duplicate product must fail'
   invalid=copy.deepcopy(project); invalid['environment']['sdk']['digest']='invalid'
   assert schema.validate_project(invalid),'bad digest must fail'
   count+=1
  print('PASS:',kind,manifest['version'],tid,template['digest'])
 # Exercise source escaping independently using upstream reference rules (not a UI-supported name).
 types=schema._parameter_types(template)
 escaped=schema.substitute('<string>{{displayName}}</string>','plist-xml',types,{'displayName':'A<&"'})
 assert escaped=='<string>A&lt;&amp;&quot;</string>'
 for data in [b'{"a":1,"a":2}',b'{"a":1.5}',b'\xef\xbb\xbf{}']:
  try: schema.parse_json(data)
  except ValueError: pass
  else: raise AssertionError('strict JSON accepted invalid input')
 # Extract exact existing Linux C and shell literals and execute success and failure paths.
 text=(ROOT/'src/ios/Views/Settings/DevelopmentProjectsView.swift').read_text()
 def literal(key):
  raw=re.search(r'static let '+key+r' = """\n(.*?)\n    """',text,re.S).group(1)
  return '\n'.join(line[4:] if line.startswith('    ') else line for line in raw.splitlines())+'\n'
 linux=Path(temp)/'linux'; (linux/'Sources').mkdir(parents=True)
 (linux/'Sources/main.c').write_text(literal('source')); (linux/'build.sh').write_text(literal('recipe'))
 subprocess.run(['sh','build.sh'],cwd=linux,check=True)
 assert subprocess.check_output([str(linux/'build/hello')],text=True)=='Hello from Minis!\n'
 (linux/'Sources/main.c').write_text('invalid syntax;')
 assert subprocess.run(['sh','build.sh'],cwd=linux,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode!=0
print(f'PASS: {count} generated native projects; JSON/plist/binary copy/negative checks; Linux build success and failure')
pbx=(ROOT/'src/ios/Minis.xcodeproj/project.pbxproj').read_text()
for path in (ROOT/'src/ios/Views/Settings/ApelinModel').glob('*.swift'):
 assert pbx.count(path.name)>=4,path.name
assert 'lastKnownFileType = folder; path = ApelinTemplates;' in pbx
print('PASS: Xcode source references and folder resource present (not Xcode type checking)')
