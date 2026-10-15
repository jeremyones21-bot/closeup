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
- [x] Per-app audio (choose which apps' sound is recorded)
- [x] Pause and resume
- [x] Countdown (3 s, in the menu bar)
- [x] Global start/stop shortcut
- [x] Resize the recorded window to an exact size
- [x] Speaker notes (floating, never recorded)
- [x] Hide desktop icons (left out of the capture, Finder untouched)
- [x] Hide the Dock icon while recording
- [x] Autosave every 2 s and crash recovery
- [x] Recording flags (mark a moment while recording)
- [x] New-recording defaults (style applied to new projects)
- [x] iPhone / iPad over USB with device frame
- [x] Create a project from an existing video

### Seen in Screen Studio's own screens
- [x] Recording bar: Display / Window / Area / Device, camera, microphone, Mac sound, options
- [x] Device mode in the bar
- [x] Folder button (open the recordings window)
- [x] Pick a display or window by hovering it on screen, with "Start recording ▾"
- [x] After-recording action: open project / export and copy / export and save to file
- [x] "Automatically create zooms" switch
- [x] Recording widget during capture (finish, pause, restart, cancel)
- [x] Restart recording
- [x] Dim everything outside the recorded area while recording
- [x] Prompter (auto-scrolling speaker notes)
- [x] Welcome screen that asks for permissions
- [x] Settings window: General, Recording, Editing, Quick export, Shortcuts, Advanced
- [x] Start at login
- [x] Choose where projects are saved
- [x] Maximum camera resolution (720p / 1080p / 4K)
- [x] Use last project's settings for new recordings
- [x] Quick export: format, frame rate, resolution, compression (Studio / Social / Web / Web Low)
- [x] Quick-export widget after recording
- [x] Editable shortcuts (their defaults: ⌃⌘↩ start/finish, ⌥⌘P pause, ⌥⌘⌫ restart, ⌃⌥⌘F flag, ⌥⌘3/4/5 display/window/area, ⌥⌘/ notes, ⌥⌘. prompter, ⌥⌘' controls)
- [~] Super resolution setting (Off / Fast / Quality): Fast = Lanczos resampling, Quality = Lanczos + sharpening. Not a trained model
- [x] Variable frame rate export (smaller files for static screens)
- [-] Usage data: Closeup collects none, so there's no switch
- [-] Licensing, network certificate and diagnostics upload options: Closeup has no server

## 2. Zoom and focus
- [x] Automatic zoom from clicks
- [x] Manual zoom (add on the timeline)
- [x] Manual zoom target (pin a zoom to a spot instead of following the cursor)
- [x] Instant zoom (zoom with no ease-in)
- [x] Classic zoom
- [x] Loupe zoom
- [x] Automatic zoom animation (springs)
- [x] Timeline zoom editing (move, resize, delete, amount)
- [x] Smart framing (keep the cursor clear of the webcam)
- [x] Zoom re-aiming when the aspect ratio changes (camera is computed per canvas)
- [~] Upscaling: Lanczos resampling plus sharpening when zoomed (Settings › Advanced › Super resolution). Screen Studio uses its own trained model; this is not ML super-resolution

## 3. Cursor
- [x] Smooth cursor
- [x] Turn smoothing off (Smoothing 0)
- [x] Motion blur
- [x] Cursor size after recording
- [x] Cursor style (pointer shapes and colours)
- [x] Sharp system cursor at any size
- [x] Click effects: circle / ripple (shrink is done)
- [x] Click sounds
- [x] Hide when idle
- [x] Hide cursor in chosen sections
- [x] Loop cursor back to its start

## 4. Camera and layouts
- [x] Camera overlay (corner, size, shape, mirror)
- [x] Fullscreen camera layout
- [x] Split-screen layout
- [x] Screen-only layout (per section)
- [x] Camera cutout (background removal with Vision, on device)
- [x] Layouts that change over time, with animated transitions
- [x] Face tracking (Vision)
- [x] Hide camera during silence
- [x] Camera crop
- [x] Camera colour (looks / LUT)
- [x] Camera sharpening
- [~] Camera reactions: macOS's own Video Effects reactions (hearts, fireworks) are captured with the camera; Closeup doesn't add its own

## 5. Aspect ratio and social
- [x] 16:9, 1:1, 9:16 (plus 4:3 and the screen's own shape)
- [x] Switch aspect ratio after recording
- [x] Layout rearrangement per aspect (camera placement)
- [x] Zoom re-aiming per aspect
- [x] Caption and shortcut repositioning per aspect
- [x] Instagram Reels / TikTok safe-area preview

## 6. Editing
- [x] Timeline editor, scrubber
- [x] Trim start and end
- [x] Cut sections out
- [x] Speed up sections
- [x] Automatic typing speed-up
- [x] Edit by transcript
- [x] Remove filler words
- [x] Shorten silences
- [x] Crop the recording
- [x] Volume controls
- [x] Masks (blur / pixelate / solid)
- [x] Highlights (dim everything else)
- [x] Command menu (⌘K)
- [x] Copy frame as image
- [x] Project backups and version restore

## 7. Audio and captions
- [x] Voice cleanup / noise reduction (on device)
- [x] Podcast voice mode
- [x] Background music, auto-looped and ducked
- [x] Automatic captions (on-device speech recognition)
- [x] Caption styles and animations
- [x] Local transcription (Apple's on-device speech recognition; nothing leaves the Mac)
- [-] Cloud transcription: on-device transcription covers it; no cloud account needed
- [x] Export captions as .srt (aligned to the edit)
- [x] AI voiceover: generated locally with the Kokoro TTS model (expects it in ~/.hyperframes-venv and ~/.cache/hyperframes/tts), instead of a cloud service

## 8. Backgrounds and style
- [x] Your own image as background
- [x] macOS wallpapers
- [x] Gradients (more to come)
- [~] Unsplash: not built yet; needs an Unsplash API key
- [x] Padding
- [x] Shadow angle, distance and softness (strength is done)
- [x] Inset (frame around the recording)
- [x] Presets (save / apply)
- [x] Preset sharing (export / import a file)
- [x] Debanding (dither gradients)

## 9. Privacy
- [x] Masks for sensitive data
- [x] Context-matched masks (fill from surrounding colour)
- [x] Highlights
- [x] Local processing, offline-first
- [x] No analytics at all (so nothing to turn off)
- [x] No uploads (so no upload consent needed until sharing exists)

## 10. Export
- [x] MP4 (H.264 / HEVC), hardware encoded
- [x] GIF export (up to 1080p)
- [x] 720p option (1080p, 1440p, 4K are done)
- [x] 60 fps
- [x] Frame rate choice (30 / 60)
- [x] Quality / compression control
- [x] Export to a file
- [x] Copy exported video to the clipboard

## 11. Sharing
- [-] Share links, private links, timestamped comments, view counts: not built; they need a hosting server, and Closeup is local-only.
- [x] Project sharing / download: export the .closeup folder as one file and open it on another Mac
- [x] Copy to clipboard

## 12. Mac
- [x] Native, Apple Silicon, ScreenCaptureKit, hardware encoding
- [x] Settings window and shortcut list
