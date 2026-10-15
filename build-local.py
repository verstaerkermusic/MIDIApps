#!/usr/bin/env python3
"""Build a local preview without downloading Sparkle, SwiftLint or HexFiend.

The regular Xcode project is left intact. Only a disposable staging copy is
changed: updater UI is omitted and the SysEx detail viewer uses native text.
CoreMIDI, SnoizeMIDI, SnoizeMIDISpy and the MIDI driver are built from source.
"""
import json
import plistlib
import shutil
import subprocess
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
build = root.parent / 'work' / 'local-build'
stage = build / 'source'
if stage.exists():
    shutil.rmtree(stage)
shutil.copytree(root, stage)


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


for project in stage.rglob('project.pbxproj'):
    payload = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(project)]))
    objects = payload['objects']
    removed = {k for k, v in objects.items() if v['isa'] in ('XCRemoteSwiftPackageReference', 'XCSwiftPackageProductDependency')}
    removed.update(k for k, v in objects.items() if v.get('isa') == 'PBXFileReference' and 'HexFiend' in v.get('path', ''))
    removed.update(k for k, v in objects.items() if v.get('isa') == 'PBXShellScriptBuildPhase' and 'Remove excess HexFiend' in v.get('name', ''))
    while True:
        new = {k for k, v in objects.items() if k not in removed and any(v.get(f) in removed for f in ('productRef', 'fileRef', 'containerPortal', 'remoteRef', 'targetProxy'))}
        if not new:
            break
        removed.update(new)
    def clean(value):
        if isinstance(value, list):
            return [clean(v) for v in value if not (isinstance(v, str) and v in removed) and not (isinstance(v, dict) and v.get('ProjectRef') in removed)]
        if isinstance(value, dict):
            return {k: clean(v) for k, v in value.items() if k not in removed and k not in ('packageReferences', 'packageProductDependencies')}
        return value
    payload = clean(payload)
    project.write_bytes(plistlib.dumps(payload))

for scheme in stage.rglob('*.xcscheme'):
    tree = ET.parse(scheme)
    for node in tree.getroot().iter():
        for key in ('enableAddressSanitizer', 'enableASanStackUseAfterReturn', 'enableUBSanitizer'):
            if key in node.attrib:
                node.set(key, 'NO')
    tree.write(scheme, encoding='utf-8', xml_declaration=True)

app = stage / 'Applications' / 'MIDIMonitor'
p = app / 'AppController.swift'
s = p.read_text().replace('import Sparkle.SPUStandardUpdaterController', '')
s = s.replace('    @IBOutlet var updaterController: SPUStandardUpdaterController?', '')
s = s[:s.index('extension AppController: SPUUpdaterDelegate')]
p.write_text(s)
p = app / 'PreferencesWindowController.swift'
s = p.read_text().replace('import Sparkle.SPUUpdater', '')
a = s.index('    // Allow bindings')
b = s.index('    //\n    // Internal', a)
s = s[:a] + s[b:]
p.write_text(s)
p = app / 'MIDIMonitor-Bridging-Header.h'
p.write_text(p.read_text().replace('#import <HexFiend/HexFiend.h>', ''))

# Reuse the existing detail window, description fields and save/copy actions.
p = app / 'DetailsWindowController.swift'
s = p.read_text()
s = s.replace('    private let dataController = HFController()\n    private let dataLayoutRep = HFLayoutRepresenter()', '')
a = s.index('        dataController.editable = false')
b = s.index('\n    override func windowTitle', a)
s = s[:a] + '''        let scrollView = NSScrollView(frame: dataContainerView.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        let bytes = Array(dataForDisplay)
        textView.string = stride(from: 0, to: bytes.count, by: 16).map { offset in
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            let hex = row.map { String(format: "%02X", $0) }.joined(separator: " ")
            return String(format: "%08X  ", offset) + hex
        }.joined(separator: "\\n")
        scrollView.documentView = textView
        dataContainerView.addSubview(scrollView)
    }
''' + s[b:]
a = s.index('    private func minimumWindowSize(')
b = s.index('    private func autosaveCurrentWindowFrame', a)
s = s[:a] + '''    private func minimumWindowSize(_ proposedWindowFrameSize: NSSize) -> NSSize {
        NSSize(width: max(proposedWindowFrameSize.width, 640), height: max(proposedWindowFrameSize.height, 300))
    }

''' + s[b:]
p.write_text(s)

for name in ('MainMenu', 'Preferences'):
    p = app / 'Base.lproj' / (name + '.xib')
    tree = ET.parse(p)
    doc = tree.getroot()
    parents = {child: parent for parent in doc.iter() for child in parent}
    if name == 'MainMenu':
        for element in list(doc.iter()):
            if element.get('id') in ('236', '237', 'W3e-kE-KNg'):
                parents[element].remove(element)
    else:
        for binding in list(doc.iter('binding')):
            if binding.get('keyPath', '').startswith('updater.'):
                control = parents[parents[binding]]
                # A connected control is a button or popup; hide it in the preview.
                control.set('hidden', 'YES')
                parents[binding].remove(binding)
    tree.write(p, encoding='utf-8', xml_declaration=True)

info = app / 'Info-MIDIMonitor.plist'
payload = plistlib.loads(info.read_bytes())
payload['CFBundleName'] = 'MIDI Monitor Modern'
payload['CFBundleDisplayName'] = 'MIDI Monitor Modern'
payload['CFBundleIdentifier'] = 'de.verstaerker.MIDIMonitor.Sidebar'
for key in list(payload):
    if key.startswith('SU'):
        del payload[key]
info.write_bytes(plistlib.dumps(payload))

run('xcodebuild', '-project', app / 'MIDIMonitor.xcodeproj', '-scheme', 'MIDIMonitor',
    '-configuration', 'Release', '-derivedDataPath', build / 'DerivedData',
    '-enableAddressSanitizer', 'NO', '-enableUndefinedBehaviorSanitizer', 'NO',
    'CODE_SIGNING_ALLOWED=NO', 'ENABLE_DEBUG_DYLIB=NO', 'ENABLE_ADDRESS_SANITIZER=NO', 'ENABLE_UNDEFINED_BEHAVIOR_SANITIZER=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES',
    'CLANG_MODULE_CACHE_PATH=' + str(build / 'ModuleCache'),
    'SWIFT_MODULE_CACHE_PATH=' + str(build / 'SwiftModuleCache'),
    'ENABLE_USER_SCRIPT_SANDBOXING=NO', 'build')
product = build / 'DerivedData' / 'Build' / 'Products' / 'Release' / 'MIDI Monitor.app'
output = root.parent / 'outputs' / 'MIDI-Monitor-Modern.app'
if output.exists():
    shutil.rmtree(output)
shutil.copytree(product, output, symlinks=True)
run('codesign', '--force', '--deep', '--sign', '-', output)
print(output)
