# Closeup

Screen recordings that look edited: automatic zooms where you click, a smooth enlarged cursor, and your screen framed on a backdrop with rounded corners and a shadow.

```
./build.sh              # builds, signs, installs to /Applications
NO_INSTALL=1 ./build.sh
```

Needs macOS 15+ and the Xcode command-line tools.

## How it works

- **Recording** (`Recorder.swift`, `CameraRecorder.swift`, `DeviceRecorder.swift`): ScreenCaptureKit captures a display, window or area at 60 fps with the system cursor hidden. The cursor (120 Hz), clicks, flags and, with Accessibility, key timings and ⌘/⌃/⌥ shortcuts are logged on the same host clock to `cursor.json`. Microphone and Mac sound (all apps or chosen ones, via a second audio-only stream) go into `screen.mov`; the webcam goes to `camera.mov`. iPhone/iPad recording uses the CoreMediaIO screen-capture device. A shared `PauseClock` removes paused time from every stream. Fragmented MOV and a 2-second cursor autosave make interrupted takes recoverable.
- **Edit timeline** (`EditTimeline.swift`): trims, cuts and speed changes become pieces of the recording played back to back. The editor shows recording time; playback and export use output time; the compositor maps each output frame back to recording time.
- **Motion** (`Motion.swift`): per-frame springs for cursor smoothing, click press, classic and loupe zooms (cursor-following or fixed point, instant or eased), hidden-cursor sections, cursor looping, and the velocities motion blur uses.
- **Compositing** (`Compositor.swift`): one Core Image function draws the whole frame: backdrop (gradient with dithering, wallpaper or image) → shadow and inset → cropped, masked screen → highlights → ripples and cursor → loupe → camera move with motion blur and smart framing → webcam in its layout (animated transitions, cutout via Vision person segmentation, face tracking, crop, look) → captions and shortcut keys. A custom `AVVideoCompositing` feeds it both video tracks for the live preview and for export.
- **Audio**: voice cleanup renders the mic through Apple's voice-isolation audio unit (Podcast adds EQ, compression and a limiter). Music loops and ducks under speech. Click sounds and Kokoro voiceovers are separate tracks, mixed on export.
- **Analysis** (`Analyzer.swift`, on device): silences from audio levels, faces from Vision, transcript from on-device speech recognition, then captions, SRT, transcript cuts, filler-word removal and pause shortening.
- **Export** (`Exporter.swift`): AVAssetReader/Writer with chosen bitrate, frame rate and size; GIF via ImageIO; optional variable frame rate.
- **Projects** live in the save folder (default `~/Movies/Closeup/<name>.closeup/`). `edits.json` keeps the last 40 versions in `versions/`.

See `FEATURES.md` for the full feature checklist against Screen Studio.

## URL scheme

- `closeup://record?camera=1&mic=1`: start recording (3-second countdown); the flags are optional
- `closeup://stop`: stop
- `closeup://open?path=/path/to/Recording.closeup`: open in the editor

## Gotchas

- ScreenCaptureKit only sends frames when the screen changes. The video composition sets `sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid` so output stays at 60 fps and zooms don't stutter over still moments. On stop, the last frame is re-stamped at the stop time so a still ending isn't cut off.
- The hardened runtime needs `com.apple.security.device.audio-input` and `com.apple.security.device.camera`, otherwise mic or camera capture fails silently.
- While paused, AVPlayer shows a cached frame. Handing it a copy of the composition forces a redraw after style changes.

## License

MIT
