# Closeup vs Screen Studio: feature tracker

Every feature from Screen Studio's site and guide (as of 2026-10-15), and where Closeup is with it.

`[x]` done · `[ ]` planned · `[~]` substitute (works differently; reason given) · `[-]` not planned (reason given)

## 1. Recording
- [x] Full-screen (display) recording
- [x] Window recording (follows the window if it moves)
- [x] Area recording (drag to select, Return to use)
- [x] Webcam recording (separate track, lined up by host clock)
- [x] Microphone recording (choose which mic)
- [x] System audio ("Mac sound")
- [ ] Per-app audio (choose which apps' sound is recorded)
- [ ] Pause and resume
- [x] Countdown (3 s, in the menu bar)
- [ ] Global start/stop shortcut
- [ ] Resize the recorded window to an exact size
- [ ] Speaker notes (floating, never recorded)
- [ ] Hide desktop icons (left out of the capture, Finder untouched)
- [ ] Hide the Dock icon while recording
- [ ] Autosave every 2 s and crash recovery
- [ ] Recording flags (mark a moment while recording)
- [ ] New-recording defaults (style applied to new projects)
- [ ] iPhone / iPad over USB with device frame
- [ ] Create a project from an existing video

## 2. Zoom and focus
- [x] Automatic zoom from clicks
- [x] Manual zoom (add on the timeline)
- [ ] Manual zoom target (pin a zoom to a spot instead of following the cursor)
- [ ] Instant zoom (zoom with no ease-in)
- [x] Classic zoom
- [ ] Loupe zoom
- [x] Automatic zoom animation (springs)
- [x] Timeline zoom editing (move, resize, delete, amount)
- [ ] Smart framing (keep the cursor clear of the webcam)
- [x] Zoom re-aiming when the aspect ratio changes (camera is computed per canvas)
- [~] Upscaling: MetalFX spatial upscaling instead of Screen Studio's own trained model

## 3. Cursor
- [x] Smooth cursor
- [x] Turn smoothing off (Smoothing 0)
- [ ] Motion blur
- [x] Cursor size after recording
- [ ] Cursor style (pointer shapes and colours)
- [x] Sharp system cursor at any size
- [ ] Click effects: circle / ripple (shrink is done)
- [ ] Click sounds
- [x] Hide when idle
- [ ] Hide cursor in chosen sections
- [ ] Loop cursor back to its start

## 4. Camera and layouts
- [x] Camera overlay (corner, size, shape, mirror)
- [ ] Fullscreen camera layout
- [ ] Split-screen layout
- [ ] Screen-only layout (per section)
- [ ] Camera cutout (background removal with Vision, on device)
- [ ] Layouts that change over time, with animated transitions
- [ ] Face tracking (Vision)
- [ ] Hide camera during silence
- [ ] Camera crop
- [ ] Camera colour (looks / LUT)
- [ ] Camera sharpening
- [ ] Camera reactions

## 5. Aspect ratio and social
- [x] 16:9, 1:1, 9:16 (plus 4:3 and the screen's own shape)
- [x] Switch aspect ratio after recording
- [ ] Layout rearrangement per aspect (camera placement)
- [x] Zoom re-aiming per aspect
- [ ] Caption and shortcut repositioning per aspect
- [ ] Instagram Reels / TikTok safe-area preview

## 6. Editing
- [x] Timeline editor, scrubber
- [x] Trim start and end
- [ ] Cut sections out
- [ ] Speed up sections
- [ ] Automatic typing speed-up
- [ ] Edit by transcript
- [ ] Remove filler words
- [ ] Shorten silences
- [ ] Crop the recording
- [ ] Volume controls
- [ ] Masks (blur / pixelate / solid)
- [ ] Highlights (dim everything else)
- [ ] Command menu (⌘K)
- [ ] Copy frame as image
- [ ] Project backups and version restore

## 7. Audio and captions
- [ ] Voice cleanup / noise reduction (on device)
- [ ] Podcast voice mode
- [ ] Background music, auto-looped and ducked
- [ ] Automatic captions (on-device speech recognition)
- [ ] Caption styles and animations
- [x] Local transcription (planned via on-device speech; nothing leaves the Mac)
- [-] Cloud transcription: on-device transcription covers it; no cloud account needed
- [ ] Export captions as .srt (aligned to the edit)
- [~] AI voiceover: generated locally with the Kokoro voice already installed, instead of a cloud service

## 8. Backgrounds and style
- [ ] Your own image as background
- [ ] macOS wallpapers
- [x] Gradients (more to come)
- [~] Unsplash: needs an Unsplash API key from you
- [x] Padding
- [ ] Shadow angle, distance and softness (strength is done)
- [ ] Inset (frame around the recording)
- [ ] Presets (save / apply)
- [ ] Preset sharing (export / import a file)
- [ ] Debanding (dither gradients)

## 9. Privacy
- [ ] Masks for sensitive data
- [ ] Context-matched masks (fill from surrounding colour)
- [ ] Highlights
- [x] Local processing, offline-first
- [x] No analytics at all (so nothing to turn off)
- [x] No uploads (so no upload consent needed until sharing exists)

## 10. Export
- [x] MP4 (H.264 / HEVC), hardware encoded
- [ ] GIF export (up to 1080p)
- [ ] 720p option (1080p, 1440p, 4K are done)
- [x] 60 fps
- [ ] Frame rate choice (30 / 60)
- [ ] Quality / compression control
- [x] Export to a file
- [ ] Copy exported video to the clipboard

## 11. Sharing
- [-] Share links, private links, timestamped comments, view counts: need a hosting server. Can be built on your Vercel account later, but only with your OK before anything is published.
- [ ] Project sharing / download: export the .closeup folder as one file and open it on another Mac
- [ ] Copy to clipboard

## 12. Mac
- [x] Native, Apple Silicon, ScreenCaptureKit, hardware encoding
- [ ] Settings window and shortcut list
