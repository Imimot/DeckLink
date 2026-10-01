# DeckLink

A macOS Objective-C framework for Blackmagic Design DeckLink and UltraStudio devices, maintained by Imimot.

This project is a fork of [Boinx Software's DeckLink framework](https://github.com/boinx/DeckLink). It retains the original device-discovery and capture APIs, with substantial changes to playback, pixel-buffer handling, format support, and output lifecycle management. The wrapper and this fork's additions are MIT licensed; see [LICENSE.txt](LICENSE.txt).

## Features

- Device discovery, connection notifications, and supported video/audio format enumeration.
- Video and audio capture through Core Media sample-buffer delegates.
- Immediate video/audio playback APIs for existing integrations.
- Scheduled playback through `DeckLinkPlaybackSession`, with video and audio on the device's output timeline.
- Asynchronous native video-frame preparation, bounded buffer retention, and completion-based release.
- Timestamped audio, partial-write handling, silence generation, and recovery from missed output time.
- Keying controls and helpers for pixel formats, bit depth, alpha, and color metadata.

The session API is the preferred entry point for applications that want the framework to manage scheduled output. Lower-level scheduling methods remain available on `DeckLinkDevice (Playback)` for applications that manage their own timestamps and buffering.

## Responsibilities

The framework owns communication with the device. The application owns the media being played.

| Framework | Application |
| --- | --- |
| Discover devices and expose supported formats | Select a device and format; persist settings |
| Configure and start hardware output | Decide when output should be enabled |
| Prepare native frames and schedule presentation | Decode, render, apply effects, and supply pixel buffers |
| Request and schedule PCM audio | Decode, mix, map channels, apply gain and fades |
| Maintain the hardware output timeline | Maintain the playhead and implement pause, resume, and seek |
| Retain buffers, handle driver backpressure, and close output safely | Present errors and choose whether to retry or disable output |

There are two timelines: the application's media position and the device's continuously advancing output position. A seek changes the media supplied by the application; it does not require restarting the device's output timeline.

## Requirements and build

- macOS 14.0 or later.
- Xcode with the macOS SDK and command-line tools selected.
- A compatible Blackmagic Desktop Video installation and device for actual capture or playback. The dispatch code loads the driver from `/Library/Frameworks/DeckLinkAPI.framework`.

Build a Release framework for Intel and Apple Silicon from the repository root:

```sh
xcodebuild \
  -project DeckLink.xcodeproj \
  -scheme 'DeckLink Debug' \
  -configuration Release \
  build \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  SYMROOT="$PWD/Build"
```

The result is `Build/Release/DeckLink.framework`. Link and embed it in the application, sign it as part of the application's normal distribution process, and import:

```objc
#import <DeckLink/DeckLink.h>
```

## Scheduled playback

A session exclusively owns one device's scheduled output until it closes successfully. Its video format, audio format, frame duration, and keying mode are fixed at initialization. Do not mix an open session with the device's immediate playback or lower-level configuration/scheduling APIs.

The lifecycle is:

1. Select formats from the device's supported-format arrays and create a session.
2. Set the audio source and error handler, then open the session.
3. After opening succeeds, submit rendered pixel buffers. The first accepted frame triggers audio preroll, then starts playback.
4. Continue supplying video and audio while the output timeline advances.
5. Close the session before changing formats, changing devices, or replacing it after an error.

### Creating a session

The following example is a method on an application object with a strong `DeckLinkPlaybackSession *outputSession` property. The caller supplies a device and formats selected from `playbackVideoFormatDescriptions` and `playbackAudioFormatDescriptions`; use `NULL` for video-only output.

Despite its name, `CMVideoFormatDescriptionGetDeckLinkFrameRate` returns the duration of one frame as a `CMTime`, such as `1001/60000` for approximately 59.94 fps.

```objc
- (void)openOutputWithDevice:(DeckLinkDevice *)device
                videoFormat:(CMVideoFormatDescriptionRef)videoFormat
                audioFormat:(CMAudioFormatDescriptionRef)audioFormat {
    CMTime frameDuration = kCMTimeInvalid;
    if (CMVideoFormatDescriptionGetDeckLinkFrameRate(videoFormat, &frameDuration) != noErr) {
        return;
    }

    DeckLinkPlaybackSession *session = [[DeckLinkPlaybackSession alloc]
        initWithDevice:device
        videoFormat:videoFormat
        audioFormat:audioFormat
        frameDuration:frameDuration
        keyingMode:DeckLinkKeyingModeNone];
    self.outputSession = session;

    session.errorHandler = ^(NSError *error) {
        NSLog(@"DeckLink output failed: %@", error);
        // Arrange close/recovery on the application's output-control queue.
    };

    [session setAudioSource:^NSData *(NSUInteger samples, NSUInteger channels,
                                     CMTime presentationTime, BOOL discontinuity) {
        // Replace with prepared interleaved PCM from the application's audio engine.
        return nil; // Silence.
    }];

    [session openWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            NSLog(@"Could not open DeckLink output: %@", error);
            return;
        }
        // Notify the renderer on its owning queue that it may submit video.
    }];
}
```

Keep the session alive in the application until closing completes. Opening alone does not start playback. Once the open completion reports success, send each rendered frame using:

```objc
[self.outputSession submitPixelBuffer:renderedPixelBuffer];
```

The pixel buffer must match the selected output dimensions and pixel format and contain the color metadata required by the driver. The application handles rendering and pixel-format conversion; the framework prepares the native DeckLink frame. Do not modify a buffer while the framework is using it. For integrations that reuse storage, use the lower-level API's explicit frame-completion callback.

### Video timing and buffering

After native frame preparation, the session queries the device clock and schedules the frame at the next video-frame boundary. At 60 fps, a frame ready at output time 20 ms targets approximately 33.3 ms. Submissions targeting a timestamp already used by the session are discarded.

The current session retains at most three video buffers, including preparation and frames awaiting completion. This is a resource limit, not a requirement to preroll three video frames. Excess submissions are discarded without restarting healthy audio. The lower-level scheduled-video API allows up to eight outstanding frames.

### Audio contract

- Audio is 48 kHz interleaved signed 16-bit or 32-bit PCM in the selected format.
- `samples` counts sample frames: each contains one sample per channel. Return exactly `samples * channels * bytesPerSample` bytes of immutable data.
- The audio source runs serially on the device's scheduling queue. Supply prepared audio promptly; do not wait for decoding, rendering, or UI work.
- `presentationTime` uses the device's output timeline with a timescale of 48000. It is not the application's clip/playhead position.
- Returning `nil`, or data with the wrong length, supplies silence.
- `discontinuity` indicates replacement of an existing source or recovery after missed output time. The application can use it to reset audio-processing state or apply a transition.
- During recovery, the framework may request and discard missed audio to advance the source.

The audio worker requests service every 2 ms and maintains roughly one video frame's worth of audio ahead of the output clock. If the driver accepts only part of a packet, the session retains and retries the unwritten portion at its adjusted timestamp.

Implement pause and seek in the media source while keeping the output session running. `setAudioSource:` waits for an ongoing source read, replaces the source, and discards unwritten pending PCM. Samples already accepted by the driver remain buffered.

### Threading, errors, and closing

The framework uses separate serial queues for native frame preparation, playback scheduling/audio service, and application callbacks. Preparation and client callbacks therefore do not occupy the scheduling queue. Open/close completions and the session's error handler are delivered on a private callback queue; dispatch UI work to the main queue and application state changes to their owning queue.

A runtime failure suspends new session work and reports an error. Close the session before creating a replacement. `closeWithCompletion:` stops source reads before returning, then waits for frame preparation, driver stop, retained-frame release, and disabling audio/video output. Repeated close calls during closing join the same operation. Retry a failed close before opening another session; a successfully closed session cannot be reopened.

Low buffering requires timely media production and scheduling. A matching nominal render rate does not align the renderer's clock phase with the device. The current session does not provide a hard real-time guarantee or automatically synchronize multiple devices; late frames and audio underruns can still occur under load.

## Immediate playback

The existing `playbackPixelBuffer:`, `playbackMetalBuffer:`, and continuous-audio methods remain available. They use the driver's synchronous display/write APIs without assigning media presentation timestamps. The pixel-buffer wrapper still performs preparation and display through asynchronous queues, so "synchronous" describes the native driver call.

Use these APIs with output configured through `DeckLinkDevice (Playback)`. Complete scheduled stop/close before switching to immediate playback.

## Tests

The scheduling tests use a mock driver and require no connected device:

```sh
xcodebuild test \
  -project DeckLink.xcodeproj \
  -scheme 'DeckLink Debug' \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:DeckLinkTests/DeckLinkSchedulingTests \
  -only-testing:DeckLinkTests/DeckLinkPlaybackSessionTests \
  CODE_SIGNING_ALLOWED=NO
```

They cover buffer limits and ownership, frame preparation, callback ordering, preroll, partial audio writes, missed timestamps, source replacement, and cleanup failures. Other tests in `DeckLinkTests` include device-dependent capture and playback checks and require suitable Blackmagic hardware and drivers.

Public header comments use `///` documentation for Xcode Quick Help. See [DeckLinkPlaybackSession.h](DeckLink/DeckLinkPlaybackSession.h) and [DeckLinkDevice+Playback.h](DeckLink/DeckLinkDevice+Playback.h) for the API contracts.

## License and attribution

The Objective-C wrapper and Imimot's additions are distributed under the MIT license in [LICENSE.txt](LICENSE.txt). The upstream Boinx copyright notice is preserved alongside attribution for this fork. The extent of the changes does not remove that attribution.

The bundled files in [DeckLink/DeckLinkAPI](DeckLink/DeckLinkAPI) are Blackmagic Design SDK components with their own copyright and license notices. Those file-level notices remain in place and are separate from the wrapper's MIT license. They reference the [Blackmagic DeckLink SDK EULA](https://www.blackmagicdesign.com/EULA/DeckLinkSDK) where applicable.

Include `LICENSE.txt` when redistributing the wrapper or substantial portions of it, and preserve the applicable notices for bundled SDK components.
