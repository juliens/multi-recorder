# MultiRecorder

macOS app to record several cameras and the channels of an audio interface at the same time.

All devices run in one `AVCaptureSession`, so every sample uses the same clock. Recording starts
and stops at one shared instant, and every file is cut there. Files are aligned and have the
same length.

## Output

One folder per recording in `~/Movies/MultiRecorder/<date>/`:

- `camN_<device>.mov`: one file per camera (H.264, HEVC or ProRes 422)
- `audio_chNN.wav`: one mono 24-bit file per selected channel
- `combined.mov`: all tracks in one movie, without re-encoding (optional)
- `phoneN_<phone>.mp4` and `.m4a`: the clip of each phone and its sound (see below)
- `sync.json`: where each phone clip sits on the timeline
- `session.json`: devices, files, start time, dropped frames

## Android phones over Wi-Fi

The `android` folder holds MultiRecorder Phone, an Android app (Android 8 or later).

1. Build it with `./scripts/build-apk.sh` and install `build/MultiRecorderPhone.apk` on the phone.
2. Open it on the same Wi-Fi as the Mac. The phone appears in the Phones list of the recorder,
   with a small preview.
3. Record as usual. Each phone records in full quality on its own storage. After the stop,
   the Mac downloads the clips and places them on the timeline: first with the phone clock,
   measured over the network, then exactly by matching their sound with the recorded audio
   channels. The status line says which method was used.

The phone sound becomes an audio track, muted by default. If a clip is not in sync, right-click
its track in the editor to move it. The video and the sound of a phone move together.

## Editor

Open a recording with "Open in Editor" after a recording, or File > Open Recording… (⌘O).

- One track per file, with thumbnails or a waveform. Click or drag on the timeline to move.
  Space plays and pauses, the arrow keys move by one second.
- Loop: L turns it on and off. Drag in the ruler to choose the looped part, double-click the
  ruler to loop everything. Effect chains, plug-in windows and picture settings open in
  panels that stay above the editor.
- Audio tracks: volume (up to +12 dB), pan, mute, solo, and a chain of insert effects
  (Audio Units and VST3) with their own windows. Plug-in settings are saved with the edit.
- Video tracks: full screen, in a corner (with a size), or hidden. Corner pictures are drawn
  above full screen tracks. Each track has picture settings rendered with Core Image:
  exposure, contrast, saturation, temperature, a look, zoom and position, rounded corners
  and a border.
- Export to MP4 or QuickTime, H.264 or HEVC. The audio is rendered offline through the
  effects and mixed to stereo.

Settings are saved in `edit.json` in the recording folder.

## Build and run

VST3 hosting uses the Steinberg VST3 SDK (MIT), in git submodules:

```bash
git submodule update --init
./scripts/build-app.sh
open build/MultiRecorder.app
```

The Android app needs the Android SDK and a JDK 17 (taken from nixpkgs when none is installed):

```bash
./scripts/build-apk.sh
```

To launch it from Spotlight, Raycast or Alfred, install it in `~/Applications`:

```bash
./scripts/install-app.sh
```

The `.app` bundle is needed for the camera and microphone permission prompts.
It is signed ad hoc, so macOS may ask again for permissions after each rebuild.

## Tests

```bash
swift test
swift format lint -r Sources Tests
```

## Known limits

- Audio files use the interface sample clock. On long recordings they can drift a little
  from the video (a few ms per minute at most, depending on the hardware).
- Many USB cameras on one USB controller can run out of bandwidth. Use lower formats or
  several controllers.
