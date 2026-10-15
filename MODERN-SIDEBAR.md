# MIDI Monitor Modern

An unofficial experimental version of [MIDI Monitor](https://www.snoize.com/MIDIMonitor/), based on [MIDIApps by Kurt Revis](https://github.com/krevis/MIDIApps).

This version focuses on making source selection more useful in setups with many MIDI ports. It moves the source list into a resizable sidebar while retaining the original MIDI monitoring engine.

This project is independently maintained and is not affiliated with or endorsed by Kurt Revis or Snoize.

## What's changed

- Full-height source sidebar with an adjustable width of 240–650 points.
- Search MIDI port names without changing which sources are being monitored.
- Group checkboxes apply to the visible matches while searching.
- Larger source rows, full-name tooltips, and selected-port and search-result counts.
- Larger event table with monospaced text and alternating row backgrounds.
- Separate controls to show or hide the sidebar and message filters.
- Sidebar width and visibility are stored in MIDI Monitor documents.

The repository also contains the original SysEx Librarian sources; this UI work targets MIDI Monitor.

## Run the preview

Extract the release archive and open `MIDI-Monitor-Modern.app`.

The supplied preview is a locally signed build for Apple Silicon. It is not a notarized public release.

## Build locally without downloads

Requirements: macOS, a full Xcode installation with its command-line tools configured, and Python 3. The preview was built with Xcode 27.0 and tested on macOS 27.0.1.

From this source directory, run:

```sh
python3 build-local.py
```

The script builds an ARM64 Release app at:

```text
../outputs/MIDI-Monitor-Modern.app
```

It prepares a disposable copy of the source at `../work/local-build/source`. The original Xcode project files are preserved.

This build path does not download external dependencies:

- SnoizeMIDI, SnoizeMIDISpy, and the MIDI monitoring driver are built from the included source.
- Sparkle and SwiftLint are omitted, and automatic updates are disabled.
- The message detail window uses a native, selectable hexadecimal text view instead of HexFiend. SysEx saving remains available.
- The app uses a separate bundle identifier: `de.verstaerker.MIDIMonitor.Sidebar`.

## Standard Xcode build

The original Xcode projects still use Sparkle, the HexFiend submodule, and SwiftLint. These dependencies are not fully included in a GitHub source ZIP.

For the upstream build instructions and repository layout, see [README.upstream.md](README.upstream.md). The local preview build above is the reproducible build path for this version; the standard upstream build has not been verified for this fork and retains upstream signing and updater settings.

## Current status

This is an early working preview, not a comprehensive rewrite.

The ARM64 build and local code signature were verified. Testing covered real incoming MIDI Clock and controller messages, source search (including no matches and clearing the search), showing and hiding filters and the sidebar, and changing sidebar width. Changes to the available MIDI ports are reflected in the source list.

A complete regression test of document handling, SysEx operations, and output monitoring has not yet been performed.

## Credits and license

Original MIDI Monitor and MIDIApps: Copyright (c) 2001–2023, Kurt Revis.

The original project is distributed under the BSD 3-Clause license. Its copyright notices, license conditions, and warranty disclaimer are retained in [LICENSE](LICENSE) and the source files. See that file for the complete terms.

Source redistribution must retain those notices and terms. Binary distributions must reproduce them in the accompanying documentation or other materials. The original copyright holder's or contributors' names may not be used to imply endorsement without prior written permission.

Any third-party components included in other build configurations remain subject to their respective licenses.
