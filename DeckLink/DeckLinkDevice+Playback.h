#import <DeckLink/DeckLinkDevice.h>

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

typedef NS_ENUM(NSInteger, DeckLinkScheduledFrameResult) {
    DeckLinkScheduledFrameCompleted,
    DeckLinkScheduledFrameDisplayedLate,
    DeckLinkScheduledFrameDropped,
    DeckLinkScheduledFrameFlushed,
};
typedef void (^DeckLinkPlaybackCompletion)(BOOL success, NSError *error);
typedef void (^DeckLinkScheduledFrameCompletion)(DeckLinkScheduledFrameResult result);

@interface DeckLinkDevice (Playback)

@property (nonatomic, copy, readonly) NSArray *playbackVideoFormatDescriptions;
@property (atomic, strong, readonly) __attribute__((NSObject)) CMVideoFormatDescriptionRef playbackActiveVideoFormatDescription;
- (void)setPlaybackActiveVideoFormatDescription:(CMVideoFormatDescriptionRef)formatDescription completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

@property (nonatomic, copy, readonly) NSArray *playbackAudioFormatDescriptions;
@property (atomic, strong, readonly) __attribute__((NSObject)) CMAudioFormatDescriptionRef playbackActiveAudioFormatDescription;
- (void)setPlaybackActiveAudioFormatDescription:(CMAudioFormatDescriptionRef)formatDescription completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

@property (atomic, assign, readonly) BOOL playbackSupported;
@property (atomic, assign, readonly) BOOL playbackActive;

@property (nonatomic, copy, readonly) NSArray *playbackKeyingModes;
@property (atomic, strong, readonly) NSString *playbackActiveKeyingMode;
- (void)setPlaybackActiveKeyingMode:(NSString *)keyingMode alpha:(float)alpha completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

- (CVPixelBufferRef)createCVPixelBufferWithWidth:(uint32_t)pixelsWide height:(uint32_t)pixelsHigh colorspace:(CFStringRef)colorspaceName;

/// Starts scheduled output at the specified position in the output timeline.
///
/// Waits for previously submitted video frames to finish preparation and ends audio
/// preroll before starting the device. Configure formats and submit initial media first.
/// Serialize calls when their relative order matters. Stop and await completion before
/// changing formats or returning to immediate playback.
/// @param startTime Start position, in units of timeScale.
/// @param timeScale Number of time units per second; must be positive.
/// @param completedHandler Called on the device's serial callback queue with the start result.
- (void)startScheduledPlaybackWithStartTime:(NSUInteger)startTime timeScale:(NSUInteger)timeScale completedHandler:(DeckLinkPlaybackCompletion)completedHandler;

/// Prepares a pixel buffer asynchronously and schedules it for the specified time.
///
/// Retains the buffer until the device finishes with the frame, or rejects the submission.
/// At most eight frames may be outstanding, including frames being prepared or prerolled.
/// Both handlers run on the device's serial callback queue, never on a driver thread.
/// @param pixelBuffer Buffer to output. Do not modify its contents while it is retained.
/// @param displayTime Presentation time in the output timeline, in units of timeScale.
/// @param frameDuration Duration of the frame, in units of timeScale.
/// @param timeScale Number of time units per second; must be positive.
/// @param acceptedHandler Reports whether the device accepted the frame for scheduling.
/// @param completedHandler Reports display, drop, or flush of an accepted frame. Not called for rejected frames.
- (void)schedulePlaybackOfPixelBuffer:(CVPixelBufferRef)pixelBuffer displayTime:(NSUInteger)displayTime frameDuration:(NSUInteger)frameDuration timeScale:(NSUInteger)timeScale acceptedHandler:(DeckLinkPlaybackCompletion)acceptedHandler completedHandler:(DeckLinkScheduledFrameCompletion)completedHandler;

/// Configures audio output for continuous or timestamped playback.
///
/// Stop and await completion before changing this setting. Configure timestamped audio
/// before submitting audio preroll. The overload without timestamped uses continuous output.
/// @param formatDescription Audio format to enable, or NULL to disable audio output.
/// @param timestamped YES to schedule audio at explicit positions in the output timeline.
/// @param completedHandler Called on the device's serial callback queue with the configuration result.
- (void)setPlaybackActiveAudioFormatDescription:(CMAudioFormatDescriptionRef)formatDescription timestamped:(BOOL)timestamped completedHandler:(DeckLinkPlaybackCompletion)completedHandler;

/// Copies interleaved PCM data and submits it to scheduled audio output.
///
/// The driver may accept only a prefix, including zero sample frames. Resubmit any
/// unwritten suffix with its timestamp advanced by the number of accepted sample frames.
/// At most eight requests may await processing; each is limited to 8 MiB.
/// Audio can be submitted before playback starts without installing an audio callback.
/// The first packet begins audio preroll, which ends when playback starts or stops.
/// @param data Interleaved PCM matching the configured audio format.
/// @param sampleFrameCount Number of sample frames, each containing one sample per channel.
/// @param streamTime Position of the first sample frame, using the same time origin as video.
/// @param timeScale Number of streamTime units per second; must be positive.
/// @param completedHandler Called on the device's serial callback queue with the accepted
/// sample-frame count and any error. Accepted samples have been copied by the driver.
- (void)scheduleAudioData:(NSData *)data sampleFrameCount:(UInt32)sampleFrameCount streamTime:(int64_t)streamTime timeScale:(int64_t)timeScale completedHandler:(void (^)(UInt32 sampleFramesWritten, NSError *error))completedHandler;

/// Queries the device's scheduled playback state and buffered media counts.
///
/// The query follows previously submitted frame preparation and playback operations.
/// Counts describe media buffered by the driver, excluding frames still being prepared.
/// @param timeScale Number of units per second for the returned streamTime; must be positive.
/// @param completedHandler Called on the device's serial callback queue. streamTime is
/// valid only while running is YES. audioSampleFrames counts sample frames, not individual
/// channel samples. Check error before using the returned state.
- (void)getScheduledPlaybackStatusWithTimeScale:(NSUInteger)timeScale completedHandler:(void (^)(BOOL running, int64_t streamTime, NSUInteger videoFrames, NSUInteger audioSampleFrames, NSError *error))completedHandler;

- (void)startScheduledPlaybackWithStartTime:(NSUInteger)startTime timeScale:(NSUInteger)timeScale;
- (void)schedulePlaybackOfPixelBuffer:(CVPixelBufferRef)pixelBuffer displayTime:(NSUInteger)displayTime frameDuration:(NSUInteger)frameDuration timeScale:(NSUInteger)timeScale;
- (void)stopScheduledPlaybackWithCompletionHandler:(DeckLinkDeviceStopPlaybackCompletionHandler)completionHandler;
- (void)playbackPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)playbackPixelBuffer:(CVPixelBufferRef)pixelBuffer isFlipped:(BOOL)flipped;

- (void)playbackMetalBuffer:(id<MTLBuffer>)metalBuffer ofSize:(NSSize)size rowBytes:(NSUInteger)rowBytes pixelFormat:(uint32_t)pixelformat isFlipped:(BOOL)flipped;

- (void)playbackContinuousAudioBufferList:(AudioBufferList *)audioBufferList numberOfSamples:(UInt32)numberOfSamples completionHandler:(void(^)(void))completionHandler;
- (void)playback16bitAudioBuffer:(short *)audiobuffer numberOfSamples:(UInt32)numberOfSamples completionHandler:(void(^)(void))completionHandler;

#if 0

@property (nonatomic, copy, readonly) NSArray *playbackVideoConnections;
@property (atomic, strong, readonly) NSString *playbackActiveVideoConnection;
- (void)setPlaybackActiveVideoConnection:(NSString *)connection completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

@property (nonatomic, copy, readonly) NSArray *playbackAudioConnections;
@property (atomic, strong, readonly) NSString *playbackActiveAudioConnection;
- (void)setPlaybackActiveAudioConnection:(NSString *)connection completedHandler:(void (^)(BOOL status, NSError *outError))callbackBlock;

- (BOOL)startPlaybackWithError:(NSError **)error;
- (void)stopPlayback;

#endif

#if 0
- (CMVideoFormatDescriptionRef)recordVideoFormatDescriptionWithDisplayMode:(int32_t)displayMode;
- (CMVideoFormatDescriptionRef)recordVideoFormatDescriptionWithName:(NSString *)name;

- (CMAudioFormatDescriptionRef)recordAudioFormatDescriptionWithName:(NSString *)name;

- (BOOL)startRecordWithError:(NSError **)error;
- (void)stopRecord;

- (void)recordPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)recordAudioBufferList:(const AudioBufferList *)audioBufferList numberOfSamples:(UInt32)numberOfSamples;

- (void)recordVideoData:(const void *)data presentationTimeStamp:(CMTime)presentationTimeStamp duration:(CMTime)duration;
- (void)recordVideoDataPresentationTimeStamp:(CMTime)presentationTimeStamp duration:(CMTime)duration frameCallbackHandler:(void(^)(void *data, int32_t width, int32_t height, int32_t bytesPerRow, CMPixelFormatType pixelFormat))callback;
#endif

@end
