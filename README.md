# Closeup

Screen recordings that look edited: automatic zooms where you click, a smooth enlarged cursor, and your screen framed on a backdrop with rounded corners and a shadow.

```
./build.sh              # builds, signs, installs to /Applications
NO_INSTALL=1 ./build.sh
```

Needs macOS 15+ and the Xcode command-line tools.

## How it works

- **Recording** (`Recorder.swift`): ScreenCaptureKit captures one display at 60 fps with the **system cursor hidden** and writes HEVC to `screen.mov`. Separately, the cursor position and button state are polled at 120 Hz on the same host clock and saved to `cursor.json`. Polling `NSEvent.mouseLocation` and `pressedMouseButtons` needs no Accessibility permission.
- **Motion** (`Motion.swift`): from the cursor log, it builds per-frame cursor smoothing, the click "press", and the camera (zoom and focus), all through critically damped springs. Auto-zooms group clicks less than 2.5s apart and start 0.7s before the first click.
- **Compositing** (`Compositor.swift`): one Core Image function turns a source frame into a finished frame: backdrop → shadow → rounded screen → cursor → camera. The same function drives the live preview (an `AVVideoComposition` on `AVPlayer`) and the export (`AVAssetExportSession`), so what you see is what you get.
- **Projects** live in `~/Movies/Closeup/<name>.closeup/` as `screen.mov`, `cursor.json` and `edits.json`. The original recording is never modified.

## URL scheme

- `closeup://record`: start recording (3-second countdown)
- `closeup://stop`: stop
- `closeup://open?path=/path/to/Recording.closeup`: open in the editor

## Gotchas

- ScreenCaptureKit only sends frames when the screen changes. The video composition sets `sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid` so output stays at 60 fps and zooms don't stutter over still moments. On stop, the last frame is re-stamped at the stop time so a still ending isn't cut off.
- The hardened runtime needs `com.apple.security.device.audio-input` for the microphone, otherwise capture fails silently.
- While paused, AVPlayer shows a cached frame. Handing it a copy of the composition forces a redraw after style changes.

## License

MIT
