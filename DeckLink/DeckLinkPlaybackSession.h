#import <DeckLink/DeckLinkDevice+Playback.h>

/// Supplies audio to a playback session on the device's serial scheduling queue.
///
/// Return interleaved PCM in the configured format, with exactly the requested number
/// of sample frames. nil or an incorrectly sized buffer produces silence. Do not mutate
/// returned data while the session uses it. Never wait for decoding, video, or UI work.
/// During recovery, the session may read and discard audio whose output time has passed.
/// @param samples Number of sample frames to consume, each containing one sample per channel.
/// @param channels Number of channels in the session's audio format.
/// @param presentationTime Position in the output timeline, with a timescale of 48000.
/// @param discontinuity YES when replacing an existing source or recovering from missed output time.
/// @return The requested PCM data, or nil for silence.
typedef NSData * (^DeckLinkPlaybackAudioSource)(NSUInteger samples, NSUInteger channels, CMTime presentationTime, BOOL discontinuity);

/// Coordinates scheduled video and audio output for one device.
///
/// An open session exclusively owns the device's scheduled output until close succeeds.
/// Do not use the device's other playback APIs during that time. Settings are fixed at
/// initialization; close the session before opening a replacement with different settings.
/// Handle pause and seek in the audio source while keeping the output session running.
/// Completions and errorHandler run on the device's serial callback queue.
@interface DeckLinkPlaybackSession : NSObject

/// Creates a session without configuring or starting the device.
/// @param device Device whose output this session will own after opening.
/// @param videoFormat Video format to enable.
/// @param audioFormat Interleaved, signed 16-bit or 32-bit PCM at 48 kHz, or NULL for video only.
/// @param frameDuration Positive duration of one output video frame.
/// @param keyingMode Keying mode to use, or nil to disable keying.
- (instancetype)initWithDevice:(DeckLinkDevice *)device
                   videoFormat:(CMVideoFormatDescriptionRef)videoFormat
                   audioFormat:(CMAudioFormatDescriptionRef)audioFormat
                 frameDuration:(CMTime)frameDuration
                    keyingMode:(NSString *)keyingMode;

@property (nonatomic, strong, readonly) DeckLinkDevice *device;

/// Receives runtime failures on the device's serial callback queue. Set before opening.
/// A failure suspends new submissions. Close successfully before creating a replacement session.
@property (atomic, copy) void (^errorHandler)(NSError *error);

/// Claims and configures the device asynchronously. Call once per session.
/// Successful opening permits submissions; playback starts after the first accepted
/// video frame and, when audio is enabled, one video frame's worth of audio preroll.
/// @param completion Called on the device's serial callback queue with the configuration result.
- (void)openWithCompletion:(DeckLinkPlaybackCompletion)completion;

/// Replaces the audio source without restarting output. nil supplies silence.
/// Waits for any current source read to finish before returning. Discards pending audio
/// not yet accepted by the driver; audio already buffered by the driver is unaffected.
- (void)setAudioSource:(DeckLinkPlaybackAudioSource)source;

/// Submits a rendered frame for asynchronous preparation and scheduled output.
/// The first accepted frame starts playback after preroll. Subsequent frames target the
/// next video frame boundary on the device's clock. Duplicate times and excess frames
/// are discarded. At most three buffers are retained, including preparation; this limit
/// does not require three frames of preroll. Do not modify a submitted buffer's contents.
- (void)submitPixelBuffer:(CVPixelBufferRef)buffer;

/// Stops source reads before returning and closes output asynchronously.
/// Successful completion means frame preparation has finished, playback has stopped,
/// retained frames have been released, and audio and video output have been disabled.
/// Repeated calls during closing join the same operation. If closing fails, retry close
/// before opening another session. A successfully closed session cannot be reopened.
/// @param completion Called on the device's serial callback queue with the close result.
- (void)closeWithCompletion:(DeckLinkPlaybackCompletion)completion;
@end
