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
- `session.json`: devices, files, start time, dropped frames

## Build and run

```bash
./scripts/build-app.sh
open build/MultiRecorder.app
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
