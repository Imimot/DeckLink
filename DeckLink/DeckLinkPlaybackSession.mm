#import "DeckLinkPlaybackSession.h"
#import "DeckLinkDevice+Internal.h"
#import "DeckLinkKeying.h"
#include <cmath>

typedef NS_ENUM(NSUInteger, DeckLinkSessionState) {
    DeckLinkSessionNew, DeckLinkSessionReady, DeckLinkSessionPrerolling,
    DeckLinkSessionRunning, DeckLinkSessionClosing, DeckLinkSessionClosed, DeckLinkSessionFailed,
};

@interface DeckLinkSessionAudioPacket : NSObject
@property (copy) NSData *data;
@property UInt32 samples, offset;
@property int64_t time;
@end
@implementation DeckLinkSessionAudioPacket
@end

static NSError *SessionError(HRESULT status) {
    return status == S_OK ? nil : [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

@interface DeckLinkPlaybackSession () {
    id _videoFormat, _audioFormat;
    CMTime _frameDuration;
    NSString *_keyingMode;
    DeckLinkSessionState _state;
    dispatch_source_t _audioTimer;
    DeckLinkPlaybackAudioSource _audioSource;
    DeckLinkSessionAudioPacket *_pendingAudio;
    NSMutableArray<DeckLinkPlaybackCompletion> *_closeHandlers;
    NSUInteger _channels, _bytesPerFrame, _audioCapacity;
    int64_t _audioCursor, _lastVideoTime;
    double _lastAudioProgressHostTime;
    BOOL _sourceDiscontinuity;
}
@end

@implementation DeckLinkPlaybackSession
- (instancetype)initWithDevice:(DeckLinkDevice *)device videoFormat:(CMVideoFormatDescriptionRef)video
                   audioFormat:(CMAudioFormatDescriptionRef)audio frameDuration:(CMTime)duration keyingMode:(NSString *)keyer {
    if ((self = [super init])) {
        _device = device; _videoFormat = (__bridge id)video; _audioFormat = (__bridge id)audio;
        _frameDuration = duration; _keyingMode = [keyer copy] ?: DeckLinkKeyingModeNone;
        _lastVideoTime = -1;
        _closeHandlers = [NSMutableArray new];
    }
    return self;
}

- (void)dealloc {
    if (_audioTimer) dispatch_source_cancel(_audioTimer);
    // Explicit close is the normal path. Keep the device alive for fallback drain.
    if (_state != DeckLinkSessionNew && _state != DeckLinkSessionClosed) {
        DeckLinkDevice *device = _device;
        [device stopScheduledPlaybackWithInternalCompletion:^(HRESULT status) {
            if (status == S_OK) {
                [device setAudioFormatOnPlaybackQueue:NULL timestamped:YES];
                [device setVideoFormatOnPlaybackQueue:NULL];
            }
        }];
    }
}

- (void)openWithCompletion:(DeckLinkPlaybackCompletion)completion {
    dispatch_async(_device.playbackQueue, ^{
        HRESULT status = S_OK;
        if (self->_state != DeckLinkSessionNew) status = E_ABORT;
        else if (![self->_device canOpenPlaybackSessionOnQueue]) status = E_ACCESSDENIED;
        else if (!self->_videoFormat || !CMTIME_IS_NUMERIC(self->_frameDuration) || self->_frameDuration.value <= 0) status = E_INVALIDARG;
        const AudioStreamBasicDescription *asbd = self->_audioFormat ? CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)self->_audioFormat) : NULL;
        if (status == S_OK && self->_audioFormat && (!asbd || asbd->mSampleRate != 48000 ||
            asbd->mFormatID != kAudioFormatLinearPCM || !asbd->mChannelsPerFrame ||
            (asbd->mBitsPerChannel != 16 && asbd->mBitsPerChannel != 32) ||
            !(asbd->mFormatFlags & kAudioFormatFlagIsSignedInteger) || (asbd->mFormatFlags & kAudioFormatFlagIsNonInterleaved))) status = E_INVALIDARG;
        CMTime capacity = kCMTimeInvalid;
        NSUInteger bytesPerFrame = 0;
        if (status == S_OK) {
            capacity = CMTimeConvertScale(self->_frameDuration, 48000, kCMTimeRoundingMethod_RoundAwayFromZero);
            bytesPerFrame = asbd ? (NSUInteger)asbd->mChannelsPerFrame * (asbd->mBitsPerChannel / 8) : 0;
            if (!CMTIME_IS_NUMERIC(capacity) || capacity.value <= 0 || capacity.value > UINT32_MAX ||
                (bytesPerFrame && (uint64_t)capacity.value > (8 * 1024 * 1024) / bytesPerFrame)) status = E_INVALIDARG;
        }
        if (status == S_OK) {
            self->_device.scheduledPlaybackSession = self;
            self->_channels = asbd ? asbd->mChannelsPerFrame : 0;
            self->_bytesPerFrame = bytesPerFrame;
            self->_audioCapacity = (NSUInteger)capacity.value;
            status = [self->_device setVideoFormatOnPlaybackQueue:(__bridge CMVideoFormatDescriptionRef)self->_videoFormat];
            if (status == S_OK) status = [self->_device setAudioFormatOnPlaybackQueue:(__bridge CMAudioFormatDescriptionRef)self->_audioFormat timestamped:YES];
            if (status == S_OK) status = [self->_device setKeyingOnPlaybackQueue:self->_keyingMode alpha:1.0];
            if (status != S_OK) {
                // A partially configured output is not a usable session.
                HRESULT audioCleanup = [self->_device setAudioFormatOnPlaybackQueue:NULL timestamped:YES];
                HRESULT videoCleanup = [self->_device setVideoFormatOnPlaybackQueue:NULL];
                if (audioCleanup == S_OK && videoCleanup == S_OK) self->_device.scheduledPlaybackSession = nil;
            }
        }
        if (self->_state == DeckLinkSessionNew) self->_state = status == S_OK ? DeckLinkSessionReady :
            (self->_device.scheduledPlaybackSession == self ? DeckLinkSessionFailed : DeckLinkSessionClosed);
        if (completion) [self->_device deliverPlaybackCallback:^{ completion(status == S_OK, SessionError(status)); }];
    });
}

- (void)setAudioSource:(DeckLinkPlaybackAudioSource)source {
    [_device performPlaybackSync:^{
        if (self->_state == DeckLinkSessionClosing || self->_state == DeckLinkSessionClosed) return;
        if (self->_pendingAudio) self->_audioCursor = self->_pendingAudio.time + self->_pendingAudio.offset;
        self->_pendingAudio = nil;
        self->_sourceDiscontinuity = self->_audioSource != nil;
        self->_audioSource = [source copy];
    }];
}

- (void)startAudioWorker {
    if (!_channels || _audioTimer) return;
    __weak typeof(self) weakSelf = self;
    _audioTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, _device.playbackQueue);
    dispatch_source_set_event_handler(_audioTimer, ^{ [weakSelf serviceAudio]; });
    // DeckLink's 50 Hz callback is too slow for one frame at 60 fps. Strict
    // delivery requests the 100 us leeway even when the application is backgrounded.
    dispatch_source_set_timer(_audioTimer, DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC, 100 * NSEC_PER_USEC);
    dispatch_resume(_audioTimer);
}

- (void)fail:(HRESULT)status {
    if (_state == DeckLinkSessionFailed || _state == DeckLinkSessionClosing || _state == DeckLinkSessionClosed) return;
    _state = DeckLinkSessionFailed;
    if (_audioTimer) { dispatch_source_cancel(_audioTimer); _audioTimer = nil; }
    void (^handler)(NSError *) = self.errorHandler;
    if (handler) [_device deliverPlaybackCallback:^{ handler(SessionError(status)); }];
}

- (BOOL)readClock:(DeckLinkPlaybackClock *)clock {
    HRESULT status = [_device readPlaybackClockOnQueue:clock];
    if (status == S_OK && (!clock->running || clock->streamTime < 0 || !std::isfinite(clock->speed) || clock->speed <= 0)) status = E_FAIL;
    if (status != S_OK) { [self fail:status]; return NO; }
    return YES;
}

- (int64_t)nextVideoTime {
    if (_state == DeckLinkSessionReady && _lastVideoTime < 0) return 0;
    if (_state != DeckLinkSessionRunning) return -1;
    DeckLinkPlaybackClock clock;
    if (![self readClock:&clock]) return -1;
    double now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    int64_t samples = clock.streamTime + (int64_t)(MAX(0, now - clock.hostTime) * 48000 * clock.speed);
    int64_t time = CMTimeConvertScale(CMTimeMake(samples, 48000), _frameDuration.timescale, kCMTimeRoundingMethod_RoundTowardZero).value;
    int64_t next = (time / _frameDuration.value + 1) * _frameDuration.value;
    return next > _lastVideoTime ? next : -1;
}

- (void)submitPixelBuffer:(CVPixelBufferRef)buffer {
    if (!buffer) return;
    [_device performPlaybackSync:^{
        if (self->_state != DeckLinkSessionReady && self->_state != DeckLinkSessionRunning) return;
        __weak typeof(self) weakSelf = self;
        __block int64_t time = -1;
        [self->_device enqueuePlaybackPixelBuffer:buffer frameDuration:self->_frameDuration.value timeScale:self->_frameDuration.timescale maximumFrames:3 displayTime:^int64_t {
            typeof(self) session = weakSelf;
            time = session ? [session nextVideoTime] : -1; return time;
        } accepted:^(HRESULT status) {
            typeof(self) session = weakSelf;
            if (!session || session->_state == DeckLinkSessionClosing || session->_state == DeckLinkSessionClosed) return;
            // A busy device or duplicate slot drops video only, never healthy audio.
            if (status == S_FALSE || status == E_OUTOFMEMORY) return;
            if (status != S_OK) { [session fail:status]; return; }
            session->_lastVideoTime = time;
            if (session->_state == DeckLinkSessionReady) {
                session->_state = DeckLinkSessionPrerolling;
                [session startAudioWorker];
                session->_lastAudioProgressHostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
                [session serviceAudio];
            }
        } completed:^(DeckLinkScheduledFrameResult result) {
            typeof(self) session = weakSelf;
            if (session && result == DeckLinkScheduledFrameFlushed && (session->_state == DeckLinkSessionRunning || session->_state == DeckLinkSessionPrerolling)) [session fail:E_FAIL];
        }];
    }];
}

- (void)startIfPrerolled {
    if (_state != DeckLinkSessionPrerolling || _pendingAudio || (_channels && !_audioCursor)) return;
    HRESULT status = [_device startPlaybackOnQueue:0 timeScale:_frameDuration.timescale];
    if (status != S_OK) [self fail:status];
    else _state = DeckLinkSessionRunning;
}

- (void)serviceAudio {
    if (_state != DeckLinkSessionPrerolling && _state != DeckLinkSessionRunning) return;
    DeckLinkPlaybackClock clock = {};
    clock.hostTime = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    if (_state == DeckLinkSessionRunning && ![self readClock:&clock]) return;
    if (!_channels) { [self startIfPrerolled]; return; }
    if (_state == DeckLinkSessionRunning) {
        if (_pendingAudio && _pendingAudio.time + _pendingAudio.offset < clock.streamTime) {
            // Never retry a stale timestamp. Its PCM has already been consumed;
            // keep the reserved cursor and resume with fresh source data.
            _pendingAudio = nil;
            _sourceDiscontinuity = YES;
        }
        if (_audioCursor < clock.streamTime) {
            NSUInteger missed = (NSUInteger)MIN(clock.streamTime - _audioCursor, 48000);
            if (_audioSource) _audioSource(missed, _channels, CMTimeMake(_audioCursor, 48000), YES);
            _audioCursor = clock.streamTime + 96;
            _sourceDiscontinuity = YES;
        }
    }
    if (!_pendingAudio) {
        int64_t needed = clock.streamTime + _audioCapacity - _audioCursor;
        if (needed <= 0 || clock.audioSamples >= _audioCapacity) return;
        UInt32 count = (UInt32)MIN((NSUInteger)needed, _audioCapacity - clock.audioSamples);
        NSData *data = _audioSource ? _audioSource(count, _channels, CMTimeMake(_audioCursor, 48000), _sourceDiscontinuity) : nil;
        _sourceDiscontinuity = NO;
        if (data.length != count * _bytesPerFrame) data = [NSMutableData dataWithLength:count * _bytesPerFrame];
        DeckLinkSessionAudioPacket *packet = [DeckLinkSessionAudioPacket new];
        packet.data = data; packet.samples = count; packet.time = _audioCursor;
        _pendingAudio = packet; _audioCursor += count;
    }
    // A source is required to be nonblocking, but a contended source lock can
    // still overrun its deadline. Refresh after a slow read before submitting PCM.
    if (_state == DeckLinkSessionRunning && CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - clock.hostTime > 0.002) {
        if (![self readClock:&clock]) return;
        if (_pendingAudio.time + _pendingAudio.offset < clock.streamTime) {
            _pendingAudio = nil; _sourceDiscontinuity = YES; return;
        }
    }
    DeckLinkSessionAudioPacket *packet = _pendingAudio;
    if (clock.audioSamples >= _audioCapacity) return;
    UInt32 requested = (UInt32)MIN(packet.samples - packet.offset, _audioCapacity - clock.audioSamples);
    UInt32 written = 0;
    const uint8_t *bytes = (const uint8_t *)packet.data.bytes + packet.offset * _bytesPerFrame;
    HRESULT status = [_device writeAudioOnPlaybackQueue:bytes sampleFrameCount:requested
        streamTime:packet.time + packet.offset timeScale:48000 written:&written];
    if (status != S_OK || written > requested) { [self fail:status == S_OK ? E_FAIL : status]; return; }
    if (written) {
        packet.offset += written;
        _lastAudioProgressHostTime = clock.hostTime;
        if (packet.offset == packet.samples) _pendingAudio = nil;
        [self startIfPrerolled];
    } else if (clock.hostTime - _lastAudioProgressHostTime >= 0.25) {
        [self fail:E_FAIL];
    }
    // Zero/partial acceptance is backpressure. Retry on the next 2 ms tick;
    // retain the original PCM and offset, without allocating/copying its suffix.
}

- (void)closeWithCompletion:(DeckLinkPlaybackCompletion)completion {
    [_device performPlaybackSync:^{
        self->_audioSource = nil;
        self->_pendingAudio = nil;
        if (completion) [self->_closeHandlers addObject:[completion copy]];
        if (self->_state == DeckLinkSessionClosing) return;
        if (self->_state == DeckLinkSessionNew || self->_state == DeckLinkSessionClosed || self->_device.scheduledPlaybackSession != self) {
            self->_state = DeckLinkSessionClosed;
            [self finishClose:S_OK]; return;
        }
        self->_state = DeckLinkSessionClosing;
        if (self->_audioTimer) { dispatch_source_cancel(self->_audioTimer); self->_audioTimer = nil; }
        [self->_device stopScheduledPlaybackWithInternalCompletion:^(HRESULT status) {
            if (status == S_OK) {
                // Both disables run even if one fails, so partial cleanup is retryable.
                HRESULT audio = [self->_device setAudioFormatOnPlaybackQueue:NULL timestamped:YES];
                HRESULT video = [self->_device setVideoFormatOnPlaybackQueue:NULL];
                status = audio != S_OK ? audio : video;
            }
            [self finishClose:status];
        }];
    }];
}

- (void)finishClose:(HRESULT)status {
    _state = status == S_OK ? DeckLinkSessionClosed : DeckLinkSessionFailed;
    if (status == S_OK && _device.scheduledPlaybackSession == self) _device.scheduledPlaybackSession = nil;
    NSArray<DeckLinkPlaybackCompletion> *handlers = [_closeHandlers copy];
    [_closeHandlers removeAllObjects];
    [_device deliverPlaybackCallback:^{ for (DeckLinkPlaybackCompletion handler in handlers) handler(status == S_OK, SessionError(status)); }];
}
@end
