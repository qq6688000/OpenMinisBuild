#!/usr/bin/env python3
"""Static integration checks only; the real store tests run in run-swift.sh on CI."""
from pathlib import Path
import re
root = Path(__file__).resolve().parents[2]
settings = root / 'src/ios/Views/Settings'
store = (settings / 'ApelinProjectAdapter.swift').read_text().split('enum DevelopmentProjectEditing {', 1)[1]
ui = (settings / 'DevelopmentProjectsView.swift').read_text()
harness = (root / 'Validation/Apelin/main.swift').read_text()
assert 'AIChatViewModel.minisAppGroupRoot.resolvingSymlinksInPath()' in ui
for token in ['O_NOFOLLOW', 'O_DIRECTORY', 'O_EXCL', 'O_NONBLOCK', 'openat(', 'renameat(', 'unlinkat(', 'fsync(output)', 'fchmod(output', 'NSFileCoordinator', '.forReplacing', 'st_nlink == 1', 'byteLimit = 262144', 'String(data: bytes, encoding: .utf8)', 'ApelinProjectAdapter.validate(data, choice: choice, id: id)', 'PropertyListSerialization.propertyList']:
    assert token in store, token
assert store.count('matches(original, readAt(fd, name))') == 2
assert store.index('try validate(data, file: file') < store.index('let temporary =')
assert store.index('fsync(output)') < store.index('renameat(fd, temporary')
assert 'template.files.filter { $0.format != "copy" }' in store
assert '["Sources/main.c", "build.sh", "README.md"]' in store
for token in ['TextEditor(text: $content)', 'Button("保存", action: save)', 'Button("取消")', 'navigationBarBackButtonHidden(dirty)', 'confirmationDialog(', 'content.utf8.count', 'self.original = try DevelopmentProjectEditing.save', 'DevelopmentProjectEditing.load(root: DevelopmentProjects.directory(project.name)']:
    assert token in ui, token
assert 'Section("文件 · 只读预览")' not in ui
for label in ['stale editor snapshot', 'external writer conflict', 'manifest schema/identity', 'symlink parent', 'leaf symlink', 'symlink save', 'unsupported edit', 'UTF-8 byte limit', 'oversize read', 'non UTF-8', 'atomic replacement/mode']:
    assert label in harness, label
assert 'ApelinProjectAdapter.swift' in (root / 'Validation/Apelin/run-swift.sh').read_text()
assert 'sh Validation/Apelin/run-swift.sh' in (root / '.github/workflows/ipa.yml').read_text()
assert not re.search(r'\b(Process|NSTask|system|popen|execve|posix_spawn)\s*\(', store)
print('PASS: editor allowlist, bounded no-follow descriptor I/O, coordinated optimistic conflict checks, atomic save, schema/plist validation, dirty UI and existing Swift CI harness wiring (STATIC ONLY)')
