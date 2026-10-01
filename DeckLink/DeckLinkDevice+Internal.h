#import <stdatomic.h>
#import "DeckLinkDevice.h"

#import "DeckLinkAPI.h"
#import "DeckLinkDevice.h"
#import "DeckLinkDevice+Capture.h"
#import "DeckLinkDeviceInternalInputCallback.h"
#import "DeckLinkDeviceInternalOutputCallback.h"
#import "DeckLinkDevice+Playback.h"

@class DeckLinkPlaybackSession;

/// Stop progress tracked exclusively on playbackQueue.
typedef NS_ENUM(NSUInteger, DeckLinkScheduledStopState) {
    DeckLinkScheduledStopIdle,
    DeckLinkScheduledStopWaitingForDriver,
    DeckLinkScheduledStopWaitingForFrames,
};
typedef void (^DeckLinkPlaybackStatusCompletion)(HRESULT status);

struct DeckLinkPlaybackClock {
    bool running;
    /// Output timeline position at 48000 units per second. Valid only while running.
    int64_t streamTime;
    /// Host-clock time in seconds, sampled around the native stream-time query.
    double hostTime;
    /// Playback rate reported with streamTime; 1.0 is normal speed.
    double speed;
    /// Audio sample frames buffered by the driver, each containing all channels.
    uint32_t audioSamples;
};


@interface DeckLinkDevice ()
{
	IDeckLink *deckLink;
	IDeckLinkProfileAttributes *deckLinkAttributes;
	IDeckLinkConfiguration *deckLinkConfiguration;
	IDeckLinkKeyer *deckLinkKeyer;
	IDeckLinkInput *deckLinkInput;
	IDeckLinkOutput *deckLinkOutput;
	
	DeckLinkDeviceInternalInputCallback *deckLinkInputCallback;
	DeckLinkDeviceInternalOutputCallback *deckLinkOutputCallback;
	
	atomic_uint_fast64_t _sampleBufferCount_BackingStore;
    atomic_uint_fast64_t _scheduledFrameCount;
    atomic_uint_fast64_t _scheduledAudioRequests;
    atomic_uint_fast64_t _playbackGeneration;
    atomic_bool _scheduledStopRequested;
    NSMutableDictionary<NSValue *, id> *_scheduledFrames;
    NSMutableArray *_scheduledStopHandlers;
    dispatch_queue_t _playbackCallbackQueue;
    BOOL _scheduledAudioPrerolled;
    BOOL _audioPrerollActive;
    DeckLinkScheduledStopState _scheduledStopState;
}

- (instancetype)initWithDeckLink:(IDeckLink *)deckLink;

@property (nonatomic, assign, readonly) IDeckLink *deckLink;

@property (nonatomic, copy) NSString *modelName;
@property (nonatomic, copy) NSString *displayName;

@property (nonatomic, assign) int32_t persistantID;
@property (nonatomic, assign) int32_t topologicalID;

// capture

@property (atomic, assign) BOOL captureSupported;
@property (atomic, assign) BOOL captureActive;
@property (atomic, assign) BOOL captureInputSourceConnected;

@property (nonatomic, strong) dispatch_queue_t captureQueue;

@property (nonatomic, copy) NSArray *captureVideoFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMVideoFormatDescriptionRef captureActiveVideoFormatDescription;

@property (nonatomic, copy) NSArray *captureAudioFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMAudioFormatDescriptionRef captureActiveAudioFormatDescription;

@property (nonatomic, copy) NSArray *captureVideoConnections;
@property (atomic, strong) NSString *captureActiveVideoConnection;

@property (nonatomic, copy) NSArray *captureAudioConnections;
@property (atomic, strong) NSString *captureActiveAudioConnection;

@property (nonatomic, weak) id<DeckLinkDeviceCaptureVideoDelegate> captureVideoDelegate;
@property (nonatomic, strong) dispatch_queue_t captureVideoDelegateQueue;

@property (nonatomic, weak) id<DeckLinkDeviceCaptureAudioDelegate> captureAudioDelegate;
@property (nonatomic, strong) dispatch_queue_t captureAudioDelegateQueue;

// playback

@property (atomic, assign) BOOL playbackSupported;
@property (atomic, assign) BOOL playbackActive;

@property (nonatomic, weak) DeckLinkPlaybackSession *scheduledPlaybackSession;
@property (nonatomic, strong) dispatch_queue_t playbackQueue;
@property (nonatomic, strong) dispatch_queue_t frameDownloadQueue;

@property (nonatomic, copy) NSArray *playbackVideoFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMVideoFormatDescriptionRef playbackActiveVideoFormatDescription;

@property (nonatomic, copy) NSArray *playbackAudioFormatDescriptions;
@property (atomic, strong) __attribute__((NSObject)) CMAudioFormatDescriptionRef playbackActiveAudioFormatDescription;

@property (nonatomic, copy) NSArray *playbackKeyingModes;
@property (atomic, copy) NSString *playbackActiveKeyingMode;
@property (atomic, assign) float playbackKeyingAlpha;

@end

@interface DeckLinkDevice (PlaybackInitialization)
- (void)initializePlaybackScheduling;
@end

/// Internal operations used by DeckLinkPlaybackSession. Each method documents its queue requirement.
@interface DeckLinkDevice (PlaybackSessionSupport)
/// Returns whether the device is idle and available for a session. Call on playbackQueue.
- (BOOL)canOpenPlaybackSessionOnQueue;
/// Runs block synchronously on playbackQueue, or inline if already on that queue.
- (void)performPlaybackSync:(dispatch_block_t)block;
/// Dispatches block asynchronously to the device's serial callback queue. Callable from any queue.
- (void)deliverPlaybackCallback:(dispatch_block_t)block;
/// Enables the video format, or disables video for NULL. Call on playbackQueue after stopping.
- (HRESULT)setVideoFormatOnPlaybackQueue:(CMVideoFormatDescriptionRef)format;
/// Enables the audio format, or disables audio for NULL. Call on playbackQueue after stopping.
- (HRESULT)setAudioFormatOnPlaybackQueue:(CMAudioFormatDescriptionRef)format timestamped:(BOOL)timestamped;
/// Applies the keying mode and alpha. Call on playbackQueue.
- (HRESULT)setKeyingOnPlaybackQueue:(NSString *)mode alpha:(float)alpha;
/// Ends audio preroll and starts output at startTime in timeScale units per second. Call on playbackQueue.
- (HRESULT)startPlaybackOnQueue:(int64_t)startTime timeScale:(int64_t)timeScale;
/// Requests stop and cancels pending submissions. Callable from any queue after initialization.
/// Completion runs asynchronously on playbackQueue after driver stop and frame release,
/// or reports a failure. Public stop callbacks are forwarded to the client callback queue.
- (void)stopScheduledPlaybackWithInternalCompletion:(DeckLinkPlaybackStatusCompletion)completion;
/// Submits PCM without waiting for playback; written receives the accepted sample-frame count.
/// Begins audio preroll if output has not started. The driver copies the accepted prefix
/// during the call; this method does not retain bytes. Call on playbackQueue.
- (HRESULT)writeAudioOnPlaybackQueue:(const void *)bytes sampleFrameCount:(UInt32)count streamTime:(int64_t)time timeScale:(int64_t)scale written:(UInt32 *)written;
/// Queries playback state, stream time, paired host time, and buffered audio. Call on playbackQueue.
- (HRESULT)readPlaybackClockOnQueue:(DeckLinkPlaybackClock *)clock;
/// Retains and prepares a frame asynchronously, then schedules it on playbackQueue.
/// Callable from any queue. maximum bounds all outstanding frames, including preparation.
/// The time block runs on playbackQueue immediately before scheduling; return a negative
/// value to skip the frame. accepted always runs on playbackQueue. completed runs only
/// for accepted frames, also on playbackQueue.
- (void)enqueuePlaybackPixelBuffer:(CVPixelBufferRef)buffer frameDuration:(int64_t)duration timeScale:(int64_t)scale maximumFrames:(NSUInteger)maximum displayTime:(int64_t (^)(void))time accepted:(void (^)(HRESULT))accepted completed:(DeckLinkScheduledFrameCompletion)completed;
@end
