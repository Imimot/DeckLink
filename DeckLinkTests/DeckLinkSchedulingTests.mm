#include <vector>
#include <algorithm>
#include <string>
#import "../DeckLink/DeckLinkPlaybackSession.h"
#import <XCTest/XCTest.h>
#import <objc/runtime.h>
#import "../DeckLink/DeckLinkDevice+Internal.h"
#import "../DeckLink/DeckLinkDevice+Playback.h"
#import "../DeckLink/CMFormatDescription+DeckLink.h"


static atomic_int liveFrames = 0;
class TestFrame : public IDeckLinkMutableVideoFrame {
    atomic_uint refs;
public:
    TestFrame() { atomic_init(&refs, 1); ++liveFrames; }
    ~TestFrame() { --liveFrames; }
    HRESULT QueryInterface(REFIID iid, LPVOID *value) override { *value = nullptr; return E_NOINTERFACE; }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { auto n = --refs; if (!n) delete this; return n; }
long GetWidth (void) override { return 16; }
long GetHeight (void) override { return 16; }
long GetRowBytes (void) override { return 64; }
BMDPixelFormat GetPixelFormat (void) override { return bmdFormat8BitBGRA; }
BMDFrameFlags GetFlags (void) override { return bmdFrameFlagDefault; }
HRESULT GetTimecode ( BMDTimecodeFormat format,  IDeckLinkTimecode** timecode) override { return E_NOTIMPL; }
HRESULT GetAncillaryData ( IDeckLinkVideoFrameAncillary** ancillary) override { return E_NOTIMPL; }
HRESULT SetFlags ( BMDFrameFlags newFlags) override { return E_NOTIMPL; }
HRESULT SetTimecode ( BMDTimecodeFormat format,  IDeckLinkTimecode* timecode) override { return E_NOTIMPL; }
HRESULT SetTimecodeFromComponents ( BMDTimecodeFormat format,  uint8_t hours,  uint8_t minutes,  uint8_t seconds,  uint8_t frames,  BMDTimecodeFlags flags) override { return E_NOTIMPL; }
HRESULT SetAncillaryData ( IDeckLinkVideoFrameAncillary* ancillary) override { return E_NOTIMPL; }
HRESULT SetTimecodeUserBits ( BMDTimecodeFormat format,  BMDTimecodeUserBits userBits) override { return E_NOTIMPL; }
HRESULT SetInterfaceProvider ( REFIID iid,  IUnknown* iface) override { return E_NOTIMPL; }
};
class TestOutput : public IDeckLinkOutput, public IDeckLinkMacOutput {
    atomic_uint refs;
public:
    TestOutput() { atomic_init(&refs, 1); }
    IDeckLinkVideoOutputCallback *callback = nullptr;
    bool running = false;
    bool preroll = false;
    HRESULT beginPrerollStatus = S_OK, endPrerollStatus = S_OK;
    bool videoEnabled = false, audioEnabled = false;
    HRESULT disableVideoStatus = S_OK, disableAudioStatus = S_OK;
    NSUInteger videoDisableCalls = 0, audioDisableCalls = 0, displayedFrames = 0, writtenAudioFrames = 0;
    HRESULT callbackStatus = S_OK;
    HRESULT scheduleStatus = S_OK, startStatus = S_OK, stopStatus = S_OK, createStatus = S_OK;
    BMDAudioOutputStreamType audioType = bmdAudioOutputStreamContinuous;
    uint32_t audioLimit = 32;
    uint32_t bufferedAudio = 0;
    int64_t streamTime = 1001;
    HRESULT audioStatus = S_OK, enableAudioStatus = S_OK;
    dispatch_semaphore_t preparationEntered = nullptr, preparationRelease = nullptr;
    std::vector<int64_t> videoTimes, videoScales, audioTimes;
    std::vector<uint32_t> audioCounts;
    BMDTimeValue audioTime = 0;
    NSData *lastAudio;
    std::vector<IDeckLinkVideoFrame *> frames;
    std::vector<std::string> events;
    ~TestOutput() { flush(); if (callback) callback->Release(); }
    void complete(BMDOutputFrameCompletionResult result) {
        auto frame = frames.front(); frames.erase(frames.begin());
        callback->ScheduledFrameCompleted(frame, result); frame->Release();
    }
    void flush() { while (!frames.empty()) complete(bmdOutputFrameFlushed); }
    void stopped() { running = false; callback->ScheduledPlaybackHasStopped(); }
    HRESULT QueryInterface(REFIID iid, LPVOID *value) override {
        *value = nullptr;
        if (memcmp(&iid, &IID_IDeckLinkMacOutput, sizeof(iid))) return E_NOINTERFACE;
        *value = static_cast<IDeckLinkMacOutput *>(this); AddRef(); return S_OK;
    }
    ULONG AddRef() override { return ++refs; }
    ULONG Release() override { auto n = --refs; if (!n) delete this; return n; }
    HRESULT CreateVideoFrameFromCVPixelBufferRef(void *buffer, IDeckLinkMutableVideoFrame **frame) override {
        if (preparationEntered) dispatch_semaphore_signal(preparationEntered);
        if (preparationRelease) dispatch_semaphore_wait(preparationRelease, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (createStatus != S_OK) return createStatus;
        *frame = new TestFrame(); return S_OK;
    }
HRESULT DoesSupportVideoMode ( BMDVideoConnection connection ,  BMDDisplayMode requestedMode,  BMDPixelFormat requestedPixelFormat,  BMDVideoOutputConversionMode conversionMode,  BMDSupportedVideoModeFlags flags,  BMDDisplayMode* actualMode,  bool* supported) override { return E_NOTIMPL; }
HRESULT GetDisplayMode ( BMDDisplayMode displayMode,  IDeckLinkDisplayMode** resultDisplayMode) override { return E_NOTIMPL; }
HRESULT GetDisplayModeIterator ( IDeckLinkDisplayModeIterator** iterator) override { return E_NOTIMPL; }
HRESULT SetScreenPreviewCallback ( IDeckLinkScreenPreviewCallback* previewCallback) override { return E_NOTIMPL; }
HRESULT EnableVideoOutput ( BMDDisplayMode displayMode,  BMDVideoOutputFlags flags) override { videoEnabled = true; return S_OK; }
HRESULT DisableVideoOutput (void) override { ++videoDisableCalls; if (disableVideoStatus != S_OK) return disableVideoStatus; flush(); videoEnabled = false; return S_OK; }
HRESULT CreateVideoFrame ( int32_t width,  int32_t height,  int32_t rowBytes,  BMDPixelFormat pixelFormat,  BMDFrameFlags flags,  IDeckLinkMutableVideoFrame** outFrame) override { return E_NOTIMPL; }
HRESULT CreateVideoFrameWithBuffer ( int32_t width,  int32_t height,  int32_t rowBytes,  BMDPixelFormat pixelFormat,  BMDFrameFlags flags,  IDeckLinkVideoBuffer* buffer,  IDeckLinkMutableVideoFrame** outFrame) override { return E_NOTIMPL; }
HRESULT RowBytesForPixelFormat ( BMDPixelFormat pixelFormat,  int32_t width,  int32_t* rowBytes) override { return E_NOTIMPL; }
HRESULT CreateAncillaryData ( BMDPixelFormat pixelFormat,  IDeckLinkVideoFrameAncillary** outBuffer) override { return E_NOTIMPL; }
HRESULT DisplayVideoFrameSync ( IDeckLinkVideoFrame* theFrame) override { if (!videoEnabled) return E_ACCESSDENIED; ++displayedFrames; return S_OK; }
HRESULT ScheduleVideoFrame ( IDeckLinkVideoFrame* theFrame,  BMDTimeValue displayTime,  BMDTimeValue displayDuration,  BMDTimeScale timeScale) override { events.push_back("schedule"); videoTimes.push_back(displayTime); videoScales.push_back(timeScale); if (scheduleStatus != S_OK) return scheduleStatus; theFrame->AddRef(); frames.push_back(theFrame); return S_OK; }
HRESULT SetScheduledFrameCompletionCallback ( IDeckLinkVideoOutputCallback* theCallback) override { if (theCallback && callbackStatus != S_OK) return callbackStatus; if (theCallback) theCallback->AddRef(); if (callback) callback->Release(); callback = theCallback; return S_OK; }
HRESULT GetBufferedVideoFrameCount ( uint32_t* bufferedFrameCount) override { *bufferedFrameCount = (uint32_t)frames.size(); return S_OK; }
HRESULT EnableAudioOutput ( BMDAudioSampleRate sampleRate,  BMDAudioSampleType sampleType,  uint32_t channelCount,  BMDAudioOutputStreamType streamType) override { audioType = streamType; if (enableAudioStatus == S_OK) audioEnabled = true; return enableAudioStatus; }
HRESULT DisableAudioOutput (void) override { ++audioDisableCalls; if (disableAudioStatus != S_OK) return disableAudioStatus; audioEnabled = false; return S_OK; }
HRESULT WriteAudioSamplesSync ( void* buffer,  uint32_t sampleFrameCount,  uint32_t* sampleFramesWritten) override { *sampleFramesWritten = 0; if (!audioEnabled) return E_ACCESSDENIED; *sampleFramesWritten = sampleFrameCount; writtenAudioFrames += sampleFrameCount; return S_OK; }
HRESULT BeginAudioPreroll (void) override { events.push_back("beginAudio"); if (beginPrerollStatus == S_OK) preroll = true; return beginPrerollStatus; }
HRESULT EndAudioPreroll (void) override { events.push_back("endAudio"); if (endPrerollStatus == S_OK) preroll = false; return endPrerollStatus; }
HRESULT ScheduleAudioSamples ( void* buffer,  uint32_t sampleFrameCount,  BMDTimeValue streamTime,  BMDTimeScale timeScale,  uint32_t* sampleFramesWritten) override { *sampleFramesWritten = 0; if (!running && !preroll) return E_UNEXPECTED; events.push_back("audio"); if (audioStatus != S_OK) return audioStatus; audioTimes.push_back(streamTime); audioCounts.push_back(sampleFrameCount); *sampleFramesWritten = MIN(sampleFrameCount, audioLimit); audioTime = streamTime; lastAudio = [NSData dataWithBytes:buffer length:*sampleFramesWritten * 4]; return S_OK; }
HRESULT GetBufferedAudioSampleFrameCount ( uint32_t* bufferedSampleFrameCount) override { *bufferedSampleFrameCount = bufferedAudio; return S_OK; }
HRESULT FlushBufferedAudioSamples (void) override { return S_OK; }
HRESULT SetAudioCallback ( IDeckLinkAudioOutputCallback* theCallback) override { return S_OK; }
HRESULT StartScheduledPlayback ( BMDTimeValue playbackStartTime,  BMDTimeScale timeScale,  double playbackSpeed) override { events.push_back("start"); if (!callback) return E_FAIL; if (startStatus == S_OK) running = true; return startStatus; }
HRESULT StopScheduledPlayback ( BMDTimeValue stopPlaybackAtTime,  BMDTimeValue* actualStopTime,  BMDTimeScale timeScale) override { events.push_back("stop"); return stopStatus; }
HRESULT IsScheduledPlaybackRunning ( bool* active) override { *active = running; return S_OK; }
HRESULT GetScheduledStreamTime ( BMDTimeScale desiredTimeScale,  BMDTimeValue* streamTime,  double* playbackSpeed) override { *streamTime = this->streamTime; *playbackSpeed = 1; return S_OK; }
HRESULT GetReferenceStatus ( BMDReferenceStatus* referenceStatus) override { return E_NOTIMPL; }
HRESULT GetHardwareReferenceClock ( BMDTimeScale desiredTimeScale,  BMDTimeValue* hardwareTime,  BMDTimeValue* timeInFrame,  BMDTimeValue* ticksPerFrame) override { return E_NOTIMPL; }
HRESULT GetFrameCompletionReferenceTimestamp ( IDeckLinkVideoFrame* theFrame,  BMDTimeScale desiredTimeScale,  BMDTimeValue* frameCompletionTimestamp) override { return E_NOTIMPL; }
};

@interface DeckLinkDevice (SchedulingTests)
- (instancetype)initWithTestOutput:(IDeckLinkOutput *)output;
- (void)drainTestQueues;
@end
@implementation DeckLinkDevice (SchedulingTests)
- (instancetype)initWithTestOutput:(IDeckLinkOutput *)output {
    self = [self init];
    if (self) { Ivar slot = class_getInstanceVariable(DeckLinkDevice.class, "deckLinkOutput");
        *(IDeckLinkOutput **)((uint8_t *)(__bridge void *)self + ivar_getOffset(slot)) = output;
        output->AddRef(); [self initializePlaybackScheduling]; }
    return self;
}
- (void)drainTestQueues {
    dispatch_sync(self.frameDownloadQueue, ^{});
    dispatch_sync(self.playbackQueue, ^{});
    dispatch_sync((dispatch_queue_t)[self valueForKey:@"playbackCallbackQueue"], ^{});
    dispatch_sync(self.playbackQueue, ^{});
    dispatch_sync((dispatch_queue_t)[self valueForKey:@"playbackCallbackQueue"], ^{});
}
@end

@interface DeckLinkSchedulingTests : XCTestCase {
    TestOutput *driver;
    DeckLinkDevice *device;
    CVPixelBufferRef buffer;
}
@end
@implementation DeckLinkSchedulingTests
- (void)setUp {
    driver = new TestOutput();
    device = [[DeckLinkDevice alloc] initWithTestOutput:driver];
    XCTAssertEqual(CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &buffer), kCVReturnSuccess);
}
- (void)tearDown {
    [device stopScheduledPlaybackWithCompletionHandler:nil];
    [device drainTestQueues];
    if (driver->running) { driver->stopped(); driver->flush(); [device drainTestQueues]; }
    device = nil;
    driver->Release();
    CVPixelBufferRelease(buffer);
    XCTAssertEqual(atomic_load(&liveFrames), 0);
}
- (void)submit:(DeckLinkPlaybackCompletion)accepted completed:(DeckLinkScheduledFrameCompletion)completed {
    [device schedulePlaybackOfPixelBuffer:buffer displayTime:0 frameDuration:1001 timeScale:60000 acceptedHandler:accepted completedHandler:completed];
}
- (void)testPrerollPrecedesStartAndCountSurvivesStart {
    [self submit:nil completed:nil];
    __block BOOL started = NO;
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:^(BOOL success, NSError *error) { started = success; }];
    [device drainTestQueues];
    XCTAssertTrue(started);
    XCTAssertEqual(driver->events.size(), 2u);
    XCTAssertTrue(driver->events[0] == "schedule" && driver->events[1] == "start");
    XCTAssertEqual(device.frameBufferCount, 1u);
    driver->complete(bmdOutputFrameCompleted);
    [device drainTestQueues];
    XCTAssertEqual(device.frameBufferCount, 0u);
}
- (void)testFailedSubmissionBalancesOwnershipAndReportsError {
    driver->scheduleStatus = E_FAIL;
    __block NSError *failure;
    [self submit:^(BOOL success, NSError *error) { XCTAssertFalse(success); failure = error; } completed:^(DeckLinkScheduledFrameResult result) { XCTFail(@"Rejected frame must not complete"); }];
    [device drainTestQueues];
    XCTAssertNotNil(failure);
    XCTAssertEqual(device.frameBufferCount, 0u);
    XCTAssertEqual(atomic_load(&liveFrames), 0);
}
- (void)testConversionFailureBalancesCount {
    driver->createStatus = E_FAIL;
    __block BOOL failed = NO;
    [self submit:^(BOOL success, NSError *error) { failed = !success && error != nil; } completed:nil];
    [device drainTestQueues];
    XCTAssertTrue(failed);
    XCTAssertEqual(device.frameBufferCount, 0u);
}
- (void)testAdmissionIsBoundedAndRecoversAfterCompletion {
    __block NSUInteger accepted = 0, rejected = 0;
    for (int i = 0; i < 10; ++i) [self submit:^(BOOL success, NSError *error) { if (success) ++accepted; else ++rejected; } completed:nil];
    [device drainTestQueues];
    XCTAssertEqual(accepted, 8u); XCTAssertEqual(rejected, 2u);
    XCTAssertEqual(device.frameBufferCount, 8u);
    driver->complete(bmdOutputFrameCompleted);
    [device drainTestQueues];
    [self submit:^(BOOL success, NSError *error) { XCTAssertTrue(success); } completed:nil];
    [device drainTestQueues];
    XCTAssertEqual(device.frameBufferCount, 8u);
}
- (void)testStopWaitsForDriverAndAllFrames {
    __block BOOL completed = NO;
    __block DeckLinkScheduledFrameResult result = DeckLinkScheduledFrameCompleted;
    [self submit:nil completed:^(DeckLinkScheduledFrameResult value) { result = value; }];
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:nil];
    [device drainTestQueues];
    [device stopScheduledPlaybackWithCompletionHandler:^(BOOL success, NSError *error) { completed = success; }];
    [device drainTestQueues]; XCTAssertFalse(completed);
    driver->stopped(); [device drainTestQueues]; XCTAssertFalse(completed);
    driver->flush(); [device drainTestQueues];
    XCTAssertTrue(completed); XCTAssertEqual(result, DeckLinkScheduledFrameFlushed);
    XCTAssertFalse(device.playbackActive); XCTAssertEqual(device.frameBufferCount, 0u);
}
- (void)testStopWaitsForDriverWhenFramesAreFlushedFirst {
    [self submit:nil completed:nil];
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:nil];
    [device drainTestQueues];
    __block NSUInteger completions = 0;
    [device stopScheduledPlaybackWithCompletionHandler:^(BOOL success, NSError *error) {
        XCTAssertTrue(success); XCTAssertNil(error); ++completions;
    }];
    [device drainTestQueues];
    driver->flush(); [device drainTestQueues];
    XCTAssertEqual(device.frameBufferCount, 0u); XCTAssertEqual(completions, 0u);
    driver->stopped(); [device drainTestQueues];
    XCTAssertEqual(completions, 1u); XCTAssertFalse(device.playbackActive);
}
- (void)testStopCancelsQueuedPreparationAndStart {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(device.playbackQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    __block NSUInteger failures = 0;
    DeckLinkPlaybackCompletion completion = ^(BOOL success, NSError *error) { if (!success && error) ++failures; };
    [self submit:completion completed:nil];
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:completion];
    [device stopScheduledPlaybackWithCompletionHandler:nil];
    dispatch_semaphore_signal(gate);
    [device drainTestQueues];
    XCTAssertEqual(failures, 2u); XCTAssertTrue(driver->events.empty());
    XCTAssertEqual(device.frameBufferCount, 0u);
}
- (void)testPrerollCanBeStoppedAndRestarted {
    [self submit:nil completed:nil]; [device drainTestQueues];
    __block BOOL stopped = NO;
    [device stopScheduledPlaybackWithCompletionHandler:^(BOOL success, NSError *error) { stopped = success; }];
    [device drainTestQueues];
    XCTAssertTrue(stopped); XCTAssertEqual(device.frameBufferCount, 0u);
    [self submit:nil completed:nil];
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:nil];
    [device drainTestQueues]; XCTAssertTrue(device.playbackActive);
}
- (void)testCompletionResultIsForwarded {
    __block DeckLinkScheduledFrameResult result = DeckLinkScheduledFrameCompleted;
    [self submit:nil completed:^(DeckLinkScheduledFrameResult value) { result = value; }];
    [device drainTestQueues]; driver->complete(bmdOutputFrameDisplayedLate); [device drainTestQueues];
    XCTAssertEqual(result, DeckLinkScheduledFrameDisplayedLate);
}
- (void)testStartAndStopFailuresReachCaller {
    driver->startStatus = E_FAIL;
    __block BOOL failed = NO;
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:^(BOOL success, NSError *error) { failed = !success && error != nil; }];
    [device drainTestQueues]; XCTAssertTrue(failed); XCTAssertFalse(device.playbackActive);
    driver->startStatus = S_OK;
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:nil]; [device drainTestQueues];
    driver->stopStatus = E_FAIL; failed = NO;
    [device stopScheduledPlaybackWithCompletionHandler:^(BOOL success, NSError *error) { failed = !success && error != nil; }];
    [device drainTestQueues]; XCTAssertTrue(failed); XCTAssertTrue(device.playbackActive);
    driver->stopStatus = S_OK;
}
- (void)testConfigurationFailureAlwaysCompletes {
    __block BOOL failed = NO;
    CMVideoFormatDescriptionRef format = NULL;
    CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_422YpCbCr8, 16, 16, NULL, &format);
    [device setPlaybackActiveVideoFormatDescription:format completedHandler:^(BOOL success, NSError *error) { failed = !success && error != nil; }];
    [device drainTestQueues]; CFRelease(format);
    XCTAssertTrue(failed);
}
- (void)testScheduledAudioCopiesDataAndReportsPartialWrites {
    AudioStreamBasicDescription asbd = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CMAudioFormatDescriptionRef format = NULL;
    XCTAssertEqual(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &format), noErr);
    device.playbackAudioFormatDescriptions = @[(__bridge id)format];
    [device setPlaybackActiveAudioFormatDescription:format timestamped:YES completedHandler:^(BOOL success, NSError *error) { XCTAssertTrue(success); }];
    [device drainTestQueues]; CFRelease(format);
    XCTAssertEqual(driver->audioType, bmdAudioOutputStreamTimestamped);
    NSMutableData *audio = [NSMutableData dataWithLength:64 * 4];
    memset(audio.mutableBytes, 7, audio.length);
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(device.playbackQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    __block UInt32 written = 0;
    [device scheduleAudioData:audio sampleFrameCount:64 streamTime:4800 timeScale:48000 completedHandler:^(UInt32 count, NSError *error) { XCTAssertNil(error); written = count; }];
    memset(audio.mutableBytes, 0, audio.length);
    dispatch_semaphore_signal(gate); [device drainTestQueues];
    XCTAssertEqual(written, 32u); XCTAssertEqual(driver->audioTime, 4800);
    XCTAssertEqual(((const uint8_t *)driver->lastAudio.bytes)[0], 7);
    XCTAssertTrue(driver->preroll);
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:^(BOOL success, NSError *error) {
        XCTAssertTrue(success); XCTAssertNil(error);
    }];
    [device drainTestQueues];
    XCTAssertFalse(driver->preroll);
    XCTAssertTrue(driver->events == (std::vector<std::string>{"beginAudio", "audio", "endAudio", "start"}));
}
- (void)testStatusUsesDriverCountsAndTime {
    [self submit:nil completed:nil];
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:nil];
    __block BOOL queried = NO;
    [device getScheduledPlaybackStatusWithTimeScale:60000 completedHandler:^(BOOL running, int64_t time, NSUInteger video, NSUInteger audio, NSError *error) {
        XCTAssertTrue(running); XCTAssertEqual(time, 1001); XCTAssertEqual(video, 1u); XCTAssertNil(error); queried = YES;
    }];
    [device drainTestQueues]; XCTAssertTrue(queried);
}
- (void)testCallbackRegistrationFailureRejectsFrameWithoutLeaking {
    driver->callbackStatus = E_FAIL;
    __block BOOL failed = NO;
    [self submit:^(BOOL success, NSError *error) { failed = !success && error != nil; } completed:nil];
    [device drainTestQueues]; XCTAssertTrue(failed);
    XCTAssertEqual(device.frameBufferCount, 0u); XCTAssertEqual(driver->callback, nullptr);
}
- (void)testRepeatedStopsCompleteOnceEach {
    [device startScheduledPlaybackWithStartTime:0 timeScale:60000 completedHandler:nil]; [device drainTestQueues];
    __block NSUInteger stops = 0;
    DeckLinkPlaybackCompletion handler = ^(BOOL success, NSError *error) { XCTAssertTrue(success); ++stops; };
    [device stopScheduledPlaybackWithCompletionHandler:handler];
    [device stopScheduledPlaybackWithCompletionHandler:handler];
    [device drainTestQueues]; XCTAssertEqual(stops, 0u);
    driver->stopped(); [device drainTestQueues]; XCTAssertEqual(stops, 2u);
}
- (void)testLegacySchedulingPreserves64BitTimeScale {
    __block BOOL accepted = NO;
    [device schedulePlaybackOfPixelBuffer:buffer displayTime:6000000000ULL frameDuration:100000000ULL timeScale:6000000000ULL acceptedHandler:^(BOOL ok, NSError *error) { accepted = ok; } completedHandler:nil];
    [device drainTestQueues]; XCTAssertTrue(accepted);
    XCTAssertEqual(driver->videoTimes.back(), 6000000000LL); XCTAssertEqual(driver->videoScales.back(), 6000000000LL);
}
- (void)testInvalidTimingDoesNotConsumeCapacity {
    __block BOOL failed = NO;
    [device schedulePlaybackOfPixelBuffer:buffer displayTime:0 frameDuration:0 timeScale:60000 acceptedHandler:^(BOOL success, NSError *error) { failed = !success && error != nil; } completedHandler:nil];
    [device drainTestQueues]; XCTAssertTrue(failed); XCTAssertEqual(device.frameBufferCount, 0u);
}
- (void)testDeviceCanBeReleasedWithPrerolledFrames {
    [self submit:nil completed:nil]; [device drainTestQueues];
    XCTAssertEqual(atomic_load(&liveFrames), 1);
    __weak DeckLinkDevice *weakDevice = device;
    device = nil;
    XCTAssertNil(weakDevice); XCTAssertEqual(atomic_load(&liveFrames), 0);
}
- (void)testFramesAreReleasedEvenWhileClientCallbackQueueIsBusy {
    dispatch_queue_t callbackQueue = (dispatch_queue_t)[device valueForKey:@"playbackCallbackQueue"];
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    dispatch_async(callbackQueue, ^{ dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    [self submit:nil completed:^(DeckLinkScheduledFrameResult result) {}];
    dispatch_sync(device.frameDownloadQueue, ^{});
    dispatch_sync(device.playbackQueue, ^{});
    driver->complete(bmdOutputFrameCompleted);
    dispatch_sync(device.playbackQueue, ^{});
    XCTAssertEqual(atomic_load(&liveFrames), 0);
    dispatch_semaphore_signal(gate); [device drainTestQueues];
}
- (void)configureImmediatePlayback {
    NSDictionary *extensions = @{(__bridge NSString *)DeckLinkFormatDescriptionDisplayModeKey: @((uint32_t)'Hp60')};
    CMVideoFormatDescriptionRef video = NULL;
    XCTAssertEqual(CMVideoFormatDescriptionCreate(NULL, kCMVideoCodecType_422YpCbCr8, 16, 16, (__bridge CFDictionaryRef)extensions, &video), noErr);
    AudioStreamBasicDescription asbd = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CMAudioFormatDescriptionRef audio = NULL;
    XCTAssertEqual(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &audio), noErr);
    device.playbackVideoFormatDescriptions = @[(__bridge id)video];
    device.playbackAudioFormatDescriptions = @[(__bridge id)audio];
    [device setPlaybackActiveVideoFormatDescription:video completedHandler:^(BOOL success, NSError *error) {
        XCTAssertTrue(success); XCTAssertNil(error);
        if (success) [device setPlaybackActiveAudioFormatDescription:audio completedHandler:^(BOOL audioSuccess, NSError *audioError) {
            XCTAssertTrue(audioSuccess); XCTAssertNil(audioError);
        }];
    }];
    [device drainTestQueues];
    CFRelease(video); CFRelease(audio);
}
- (void)testInitialImmediateOutputDoesNotRequireSuccessfulDisable {
    driver->disableVideoStatus = E_FAIL; driver->disableAudioStatus = E_FAIL;
    [self configureImmediatePlayback];
    XCTAssertTrue(driver->videoEnabled); XCTAssertTrue(driver->audioEnabled);
    XCTAssertEqual(driver->videoDisableCalls, 0u); XCTAssertEqual(driver->audioDisableCalls, 0u);
    XCTAssertEqual(driver->audioType, bmdAudioOutputStreamContinuous);
    [device playbackPixelBuffer:buffer];
    [device playback16bitAudioBuffer:(short *)calloc(800 * 2, sizeof(short)) numberOfSamples:800 completionHandler:nil];
    dispatch_sync(device.frameDownloadQueue, ^{}); [device drainTestQueues];
    XCTAssertEqual(driver->displayedFrames, 1u); XCTAssertEqual(driver->writtenAudioFrames, 800u);
    driver->disableVideoStatus = S_OK; driver->disableAudioStatus = S_OK;
}
- (void)testDisablingAlreadyInactiveOutputsIsIdempotent {
    driver->disableVideoStatus = E_FAIL; driver->disableAudioStatus = E_FAIL;
    __block NSUInteger successes = 0;
    DeckLinkPlaybackCompletion done = ^(BOOL success, NSError *error) { XCTAssertNil(error); if (success) ++successes; };
    [device setPlaybackActiveVideoFormatDescription:NULL completedHandler:done];
    [device setPlaybackActiveAudioFormatDescription:NULL completedHandler:done];
    [device drainTestQueues];
    XCTAssertEqual(successes, 2u);
    XCTAssertEqual(driver->videoDisableCalls, 0u); XCTAssertEqual(driver->audioDisableCalls, 0u);
    driver->disableVideoStatus = S_OK; driver->disableAudioStatus = S_OK;
}
- (void)testDisableFailureForEnabledOutputStillReachesCaller {
    [self configureImmediatePlayback];
    driver->disableVideoStatus = E_FAIL; driver->disableAudioStatus = E_FAIL;
    __block NSUInteger failures = 0;
    DeckLinkPlaybackCompletion done = ^(BOOL success, NSError *error) { XCTAssertFalse(success); if (error) ++failures; };
    [device setPlaybackActiveVideoFormatDescription:NULL completedHandler:done];
    [device setPlaybackActiveAudioFormatDescription:NULL completedHandler:done];
    [device drainTestQueues];
    XCTAssertEqual(failures, 2u);
    XCTAssertTrue(device.playbackActiveVideoFormatDescription != NULL);
    XCTAssertTrue(device.playbackActiveAudioFormatDescription != NULL);
    driver->disableVideoStatus = S_OK; driver->disableAudioStatus = S_OK;
}
- (void)configureTimestampedTestAudio {
    AudioStreamBasicDescription asbd = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CMAudioFormatDescriptionRef format = NULL;
    XCTAssertEqual(CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &format), noErr);
    device.playbackAudioFormatDescriptions = @[(__bridge id)format];
    [device setPlaybackActiveAudioFormatDescription:format timestamped:YES completedHandler:nil];
    [device drainTestQueues]; CFRelease(format);
}
- (void)testAudioPrerollBeginFailureDoesNotSubmitSamples {
    [self configureTimestampedTestAudio];
    driver->beginPrerollStatus = E_FAIL;
    __block BOOL reported = NO;
    [device scheduleAudioData:[NSData dataWithBytes:"1234" length:4] sampleFrameCount:1 streamTime:0 timeScale:48000 completedHandler:^(UInt32 count, NSError *error) {
        reported = YES; XCTAssertEqual(count, 0u); XCTAssertNotNil(error);
    }];
    [device drainTestQueues];
    XCTAssertTrue(reported); XCTAssertFalse(driver->preroll);
    XCTAssertTrue(driver->events == (std::vector<std::string>{"beginAudio"}));
}
- (void)testStopEndsPrerollWithoutStartingPlayback {
    [self configureTimestampedTestAudio];
    [device scheduleAudioData:[NSData dataWithBytes:"1234" length:4] sampleFrameCount:1 streamTime:0 timeScale:48000 completedHandler:nil];
    [device drainTestQueues]; XCTAssertTrue(driver->preroll);
    __block BOOL stopped = NO;
    [device stopScheduledPlaybackWithCompletionHandler:^(BOOL success, NSError *error) { stopped = success; XCTAssertNil(error); }];
    [device drainTestQueues];
    XCTAssertTrue(stopped); XCTAssertFalse(driver->preroll); XCTAssertFalse(driver->running);
    XCTAssertTrue(driver->events == (std::vector<std::string>{"beginAudio", "audio", "endAudio"}));
}
- (void)testAudioPrerollEndFailurePreventsStart {
    [self configureTimestampedTestAudio];
    [device scheduleAudioData:[NSData dataWithBytes:"1234" length:4] sampleFrameCount:1 streamTime:0 timeScale:48000 completedHandler:nil];
    [device drainTestQueues]; driver->endPrerollStatus = E_FAIL;
    __block BOOL reported = NO;
    [device startScheduledPlaybackWithStartTime:0 timeScale:25 completedHandler:^(BOOL success, NSError *error) {
        reported = YES; XCTAssertFalse(success); XCTAssertNotNil(error);
    }];
    [device drainTestQueues]; XCTAssertTrue(reported); XCTAssertFalse(driver->running);
    XCTAssertTrue(driver->preroll); driver->endPrerollStatus = S_OK;
}
@end

@interface DeckLinkPlaybackSession (SessionTests)
- (void)startAudioWorker;
- (void)serviceAudio;
@end
@interface ManualPlaybackSession : DeckLinkPlaybackSession
@end
@implementation ManualPlaybackSession
- (void)startAudioWorker {} // Drive worker ticks deterministically in driver tests.
@end

@interface DeckLinkPlaybackSessionTests : XCTestCase {
    TestOutput *driver;
    DeckLinkDevice *device;
    ManualPlaybackSession *session;
    CVPixelBufferRef buffer;
    id videoFormat, audioFormat;
    NSUInteger reads, consumed, failures;
}
@end
@implementation DeckLinkPlaybackSessionTests
- (void)setUp {
    [super setUp];
    driver = new TestOutput(); driver->audioLimit = UINT32_MAX; driver->streamTime = 0;
    device = [[DeckLinkDevice alloc] initWithTestOutput:driver];
    CVPixelBufferCreate(NULL, 16, 16, kCVPixelFormatType_32BGRA, NULL, &buffer);
    CMVideoFormatDescriptionRef video = NULL;
    CMVideoFormatDescriptionCreate(NULL, kCVPixelFormatType_32BGRA, 16, 16,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)DeckLinkFormatDescriptionDisplayModeKey: @((uint32_t)'Hp60')}, &video);
    videoFormat = CFBridgingRelease(video);
    AudioStreamBasicDescription asbd = {48000, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, 4, 1, 4, 2, 16, 0};
    CMAudioFormatDescriptionRef audio = NULL;
    CMAudioFormatDescriptionCreate(NULL, &asbd, 0, NULL, 0, NULL, NULL, &audio);
    audioFormat = CFBridgingRelease(audio);
    device.playbackVideoFormatDescriptions = @[videoFormat]; device.playbackAudioFormatDescriptions = @[audioFormat];
    session = [self newSessionWithAudio:YES keyer:@"None"];
    __weak typeof(self) weakSelf = self;
    session.errorHandler = ^(NSError *error) { typeof(self) test = weakSelf; if (test) ++test->failures; };
    [session setAudioSource:^NSData *(NSUInteger samples, NSUInteger channels, CMTime time, BOOL discontinuity) {
        typeof(self) test = weakSelf;
        if (test) { ++test->reads; test->consumed += samples; }
        return nil;
    }];
}
- (ManualPlaybackSession *)newSessionWithAudio:(BOOL)audio keyer:(NSString *)keyer {
    return [[ManualPlaybackSession alloc] initWithDevice:device videoFormat:(__bridge CMVideoFormatDescriptionRef)videoFormat
        audioFormat:audio ? (__bridge CMAudioFormatDescriptionRef)audioFormat : NULL frameDuration:CMTimeMake(1001, 60000) keyingMode:keyer];
}
- (void)tearDown {
    driver->disableAudioStatus = S_OK; driver->disableVideoStatus = S_OK; driver->stopStatus = S_OK;
    if (driver->preparationRelease) dispatch_semaphore_signal(driver->preparationRelease);
    [session closeWithCompletion:nil]; [device drainTestQueues];
    if (driver->running) { driver->stopped(); driver->flush(); [device drainTestQueues]; }
    session = nil; [device drainTestQueues]; device = nil;
    driver->Release(); CVPixelBufferRelease(buffer);
    XCTAssertEqual(atomic_load(&liveFrames), 0);
    [super tearDown];
}
- (void)open {
    __block BOOL opened = NO;
    [session openWithCompletion:^(BOOL success, NSError *error) { opened = success; XCTAssertNil(error); }];
    [device drainTestQueues]; XCTAssertTrue(opened);
}
- (void)start {
    [self open]; [session submitPixelBuffer:buffer]; [device drainTestQueues]; XCTAssertTrue(driver->running);
}
- (void)tick:(int64_t)time {
    [device performPlaybackSync:^{ driver->streamTime = time; [session serviceAudio]; }];
    [device drainTestQueues];
}
- (void)testFirstVideoAndOneAudioFrameStartPlaybackWithoutAQueueTarget {
    [self start];
    XCTAssertTrue(driver->events == (std::vector<std::string>{"schedule", "beginAudio", "audio", "endAudio", "start"}));
    XCTAssertEqual(device.frameBufferCount, 1u); XCTAssertEqual(driver->audioCounts.front(), 801u);
    XCTAssertEqual(driver->audioType, bmdAudioOutputStreamTimestamped);
}
- (void)testAudioRunsIndependentlyOfVideoAndKeepsFractionalFrameBudget {
    [self start];
    for (NSUInteger i = 1; i <= 120; ++i) [self tick:i * 96];
    XCTAssertEqual(consumed, 801u + 120 * 96); XCTAssertEqual(driver->videoTimes.size(), 1u);
    XCTAssertEqual(driver->audioTimes.back(), 801 + 119 * 96); XCTAssertEqual(failures, 0u);
}
- (void)testFullBufferPreventsOverfill {
    [self start]; driver->bufferedAudio = 801; [self tick:192]; XCTAssertEqual(reads, 1u);
    driver->bufferedAudio = 750; [self tick:288]; XCTAssertEqual(driver->audioCounts.back(), 51u);
}
- (void)testMissingOrMalformedSourceProducesCorrectlySizedSilence {
    [session setAudioSource:^NSData *(NSUInteger n, NSUInteger ch, CMTime time, BOOL gap) { return [NSData dataWithBytes:"x" length:1]; }];
    [self start]; XCTAssertEqualObjects(driver->lastAudio, [NSMutableData dataWithLength:801 * 4]);
    [session setAudioSource:nil]; [self tick:96]; XCTAssertEqualObjects(driver->lastAudio, [NSMutableData dataWithLength:96 * 4]);
}
- (void)testVideoOnlySessionStartsAndUsesTheSameClock {
    session = [self newSessionWithAudio:NO keyer:@"None"];
    [self start]; [self tick:400]; [session submitPixelBuffer:buffer]; [device drainTestQueues];
    XCTAssertTrue(driver->audioTimes.empty()); XCTAssertTrue(driver->videoTimes == (std::vector<int64_t>{0,1001}));
}
- (void)testZeroAcceptanceWaitsForWorkerAndDoesNotRepullOrRestart {
    driver->audioLimit = 0; [self open]; [session submitPixelBuffer:buffer]; [device drainTestQueues];
    XCTAssertFalse(driver->running); XCTAssertEqual(reads, 1u);
    [self tick:0]; [self tick:0]; XCTAssertEqual(reads, 1u); XCTAssertEqual(failures, 0u);
    driver->audioLimit = UINT32_MAX; [self tick:0];
    XCTAssertTrue(driver->running); XCTAssertEqual(reads, 1u);
    XCTAssertEqual(std::count(driver->events.begin(), driver->events.end(), "stop"), 0);
}
- (void)testPersistentZeroAcceptanceReportsFailureInsteadOfSpinning {
    driver->audioLimit = 0; [self open]; [session submitPixelBuffer:buffer]; [device drainTestQueues];
    XCTestExpectation *expired = [self expectationWithDescription:@"bounded no-progress recovery"];
    session.errorHandler = ^(NSError *error) { XCTAssertNotNil(error); [expired fulfill]; };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), device.playbackQueue, ^{ [session serviceAudio]; });
    [self waitForExpectationsWithTimeout:1 handler:nil];
    XCTAssertEqual(reads, 1u); XCTAssertFalse(driver->running);
}
- (void)testPartialPrerollRetainsOriginalPCMAndUsesSuffixTimestamp {
    __block NSUInteger sourceReads = 0;
    [session setAudioSource:^NSData *(NSUInteger n, NSUInteger ch, CMTime time, BOOL gap) {
        ++sourceReads; NSMutableData *data = [NSMutableData dataWithLength:n * ch * 2];
        for (NSUInteger i = 0; i < n; ++i) ((int16_t *)data.mutableBytes)[i * ch] = (int16_t)i;
        return data;
    }];
    driver->audioLimit = 400; [self open]; [session submitPixelBuffer:buffer]; [device drainTestQueues];
    XCTAssertFalse(driver->running); [self tick:0];
    XCTAssertEqual(driver->audioTime, 400); XCTAssertEqual(((const int16_t *)driver->lastAudio.bytes)[0], 400);
    XCTAssertFalse(driver->running); [self tick:0];
    XCTAssertTrue(driver->running); XCTAssertEqual(sourceReads, 1u);
    XCTAssertEqual(driver->audioTime, 800); XCTAssertEqual(((const int16_t *)driver->lastAudio.bytes)[0], 800);
}
- (void)testExpiredPartialPacketNeverRetriesInThePast {
    [self start]; driver->audioLimit = 96; [self tick:192];
    driver->audioLimit = UINT32_MAX; [self tick:24000];
    XCTAssertEqual(driver->audioTime, 24096); XCTAssertEqual(failures, 0u); XCTAssertTrue(driver->running);
    XCTAssertEqual(std::count(driver->events.begin(), driver->events.end(), "stop"), 0);
}
- (void)testReplacingSourceDropsOnlyUnwrittenAudioAndPreservesPlayback {
    [self start]; driver->audioLimit = 96; [self tick:192];
    NSUInteger previousReads = reads;
    __block BOOL discontinuity = NO;
    [session setAudioSource:^NSData *(NSUInteger n, NSUInteger ch, CMTime time, BOOL gap) {
        discontinuity = gap; return nil;
    }];
    driver->audioLimit = UINT32_MAX; [self tick:288];
    XCTAssertEqual(reads, previousReads); XCTAssertTrue(discontinuity); XCTAssertEqual(driver->audioTime, 897);
    XCTAssertEqual(std::count(driver->events.begin(), driver->events.end(), "start"), 1);
}
- (void)testLateAndDroppedVideoNeverRestartAudio {
    [self start]; driver->complete(bmdOutputFrameDisplayedLate); [device drainTestQueues];
    [self tick:400]; [session submitPixelBuffer:buffer]; [device drainTestQueues];
    driver->complete(bmdOutputFrameDropped); [device drainTestQueues]; [self tick:1200];
    [session submitPixelBuffer:buffer]; [device drainTestQueues];
    XCTAssertEqual(failures, 0u); XCTAssertTrue(driver->videoTimes == (std::vector<int64_t>{0,1001,2002}));
}
- (void)testRetentionCapDropsVideoWhileAudioContinues {
    [self start];
    for (int time : {400,1200,2000,2800}) { [self tick:time]; [session submitPixelBuffer:buffer]; [device drainTestQueues]; }
    XCTAssertEqual(device.frameBufferCount, 3u); XCTAssertEqual(failures, 0u); XCTAssertEqual(consumed, 3601u);
    driver->complete(bmdOutputFrameCompleted); [device drainTestQueues];
    [self tick:3600]; [session submitPixelBuffer:buffer]; [device drainTestQueues]; XCTAssertEqual(device.frameBufferCount, 3u);
}
- (void)testDuplicateHardwareSlotDoesNotQueueAnotherFrame {
    [self start]; [self tick:400];
    [session submitPixelBuffer:buffer]; [session submitPixelBuffer:buffer]; [device drainTestQueues];
    XCTAssertTrue(driver->videoTimes == (std::vector<int64_t>{0,1001})); XCTAssertEqual(failures, 0u);
}
- (void)testClientCallbackDelayCannotDelayAudioOrSkewVideoClock {
    [self start];
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    [device deliverPlaybackCallback:^{ dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)); }];
    [device performPlaybackSync:^{ driver->streamTime = 400; [session serviceAudio]; }];
    [session submitPixelBuffer:buffer]; dispatch_sync(device.frameDownloadQueue, ^{}); dispatch_sync(device.playbackQueue, ^{});
    XCTAssertEqual(driver->audioTime, 801); XCTAssertEqual(driver->audioCounts.back(), 400u);
    XCTAssertEqual(driver->videoTimes.back(), 1001);
    dispatch_semaphore_signal(gate); [device drainTestQueues];
}
- (void)testNativeVideoPreparationCannotBlockAudio {
    [self start];
    driver->preparationEntered = dispatch_semaphore_create(0); driver->preparationRelease = dispatch_semaphore_create(0);
    [session submitPixelBuffer:buffer];
    XCTAssertEqual(dispatch_semaphore_wait(driver->preparationEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    [device performPlaybackSync:^{ driver->streamTime = 192; [session serviceAudio]; }];
    XCTAssertEqual(driver->audioCounts.back(), 192u);
    dispatch_semaphore_signal(driver->preparationRelease); [device drainTestQueues];
}
- (void)testCloseWaitsForBothDriverFlushAndPendingPreparation {
    [self start];
    driver->preparationEntered = dispatch_semaphore_create(0); driver->preparationRelease = dispatch_semaphore_create(0);
    [session submitPixelBuffer:buffer];
    XCTAssertEqual(dispatch_semaphore_wait(driver->preparationEntered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    __block BOOL closed = NO; [session closeWithCompletion:^(BOOL ok, NSError *error) { closed = ok; }];
    dispatch_sync(device.playbackQueue, ^{}); driver->stopped(); driver->flush(); dispatch_sync(device.playbackQueue, ^{});
    XCTAssertFalse(closed); XCTAssertTrue(driver->videoEnabled);
    dispatch_semaphore_signal(driver->preparationRelease); [device drainTestQueues];
    XCTAssertTrue(closed); XCTAssertFalse(driver->audioEnabled); XCTAssertFalse(driver->videoEnabled);
}
- (void)testCloseDisablesOutputWhileClientCallbackQueueIsBlocked {
    [self start];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t release = dispatch_semaphore_create(0);
    [device deliverPlaybackCallback:^{
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    }];
    XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    __block NSUInteger completions = 0;
    @try {
        [session closeWithCompletion:^(BOOL success, NSError *error) {
            XCTAssertTrue(success); XCTAssertNil(error); ++completions;
        }];
        dispatch_sync(device.frameDownloadQueue, ^{});
        dispatch_sync(device.playbackQueue, ^{});
        driver->stopped(); driver->flush();
        dispatch_sync(device.playbackQueue, ^{});
        // Internal stop completion is queued after the frame callbacks above.
        dispatch_sync(device.playbackQueue, ^{
            XCTAssertFalse(driver->videoEnabled); XCTAssertFalse(driver->audioEnabled);
            XCTAssertNil(device.scheduledPlaybackSession);
            XCTAssertEqual(atomic_load(&liveFrames), 0);
        });
        XCTAssertEqual(completions, 0u);
    } @finally {
        dispatch_semaphore_signal(release);
        [device drainTestQueues];
    }
    XCTAssertEqual(completions, 1u);
}
- (void)testCloseStopsSourceReadsImmediatelyAndCoalescesCompletions {
    [self start]; __block NSUInteger completions = 0;
    [session closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); ++completions; }];
    [session closeWithCompletion:^(BOOL ok, NSError *error) { XCTAssertTrue(ok); ++completions; }];
    [self tick:400]; XCTAssertEqual(reads, 1u); XCTAssertEqual(completions, 0u);
    driver->stopped(); driver->flush(); [device drainTestQueues]; XCTAssertEqual(completions, 2u);
    [session submitPixelBuffer:buffer]; [self tick:800]; XCTAssertEqual(reads, 1u);
}
- (void)testConfigurationFailureRollsBackOutputs {
    driver->enableAudioStatus = E_FAIL;
    __block BOOL rejected = NO;
    [session openWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    XCTAssertTrue(rejected); XCTAssertFalse(driver->audioEnabled); XCTAssertFalse(driver->videoEnabled);
    XCTAssertNil(device.scheduledPlaybackSession);
}
- (void)testNoKeyerAcceptsNoneButRejectsExternalAndRollsBack {
    session = [self newSessionWithAudio:YES keyer:@"External"];
    __block BOOL rejected = NO;
    [session openWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    XCTAssertTrue(rejected); XCTAssertFalse(driver->videoEnabled);
    session = [self newSessionWithAudio:YES keyer:@"None"]; [self start];
}
- (void)testSecondSessionCannotReconfigureAnOwnedDevice {
    [self open]; ManualPlaybackSession *second = [self newSessionWithAudio:YES keyer:@"None"];
    __block BOOL rejected = NO;
    [second openWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    XCTAssertTrue(rejected); [second closeWithCompletion:nil]; [device drainTestQueues];
    XCTAssertEqual(device.scheduledPlaybackSession, session); XCTAssertTrue(driver->videoEnabled);
}
- (void)testCloseBeforeOpenPreventsConfigurationAndSourceReads {
    [session closeWithCompletion:nil];
    __block BOOL rejected = NO;
    [session openWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    [session submitPixelBuffer:buffer]; [self tick:800];
    XCTAssertTrue(rejected); XCTAssertFalse(driver->videoEnabled); XCTAssertEqual(reads, 0u);
}
- (void)testFailedCloseRetainsOwnershipUntilSuccessfulRetry {
    [self open]; driver->disableAudioStatus = E_FAIL;
    __block BOOL rejected = NO;
    [session closeWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    XCTAssertTrue(rejected); XCTAssertEqual(device.scheduledPlaybackSession, session);
    driver->disableAudioStatus = S_OK;
    __block BOOL closed = NO;
    [session closeWithCompletion:^(BOOL ok, NSError *error) { closed = ok; }]; [device drainTestQueues];
    XCTAssertTrue(closed); XCTAssertNil(device.scheduledPlaybackSession);
}
- (void)testFailedConfigurationCleanupRetainsOwnershipForRetry {
    driver->enableAudioStatus = E_FAIL; driver->disableVideoStatus = E_FAIL;
    __block BOOL rejected = NO;
    [session openWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    XCTAssertTrue(rejected); XCTAssertTrue(driver->videoEnabled); XCTAssertEqual(device.scheduledPlaybackSession, session);
    driver->disableVideoStatus = S_OK;
    __block BOOL closed = NO;
    [session closeWithCompletion:^(BOOL ok, NSError *error) { closed = ok; }]; [device drainTestQueues];
    XCTAssertTrue(closed); XCTAssertFalse(driver->videoEnabled); XCTAssertNil(device.scheduledPlaybackSession);
}
- (void)testSlowSourceCannotSubmitExpiredAudio {
    [self start];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    [session setAudioSource:^NSData *(NSUInteger n, NSUInteger ch, CMTime time, BOOL gap) {
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
        driver->streamTime = 24000;
        return nil;
    }];
    size_t count = driver->audioTimes.size();
    dispatch_async(device.playbackQueue, ^{ driver->streamTime = 192; [session serviceAudio]; });
    XCTAssertEqual(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)), 0);
    // Model a source lock held beyond the one-frame audio budget.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ dispatch_semaphore_signal(release); });
    dispatch_sync(device.playbackQueue, ^{});
    XCTAssertEqual(driver->audioTimes.size(), count);
    [session setAudioSource:nil]; [self tick:24000];
    XCTAssertGreaterThanOrEqual(driver->audioTime, 24000); XCTAssertEqual(failures, 0u);
}
- (void)testSessionCannotClaimLegacyAudioPreroll {
    [device setPlaybackActiveAudioFormatDescription:(__bridge CMAudioFormatDescriptionRef)audioFormat timestamped:YES completedHandler:nil];
    [device drainTestQueues];
    [device scheduleAudioData:[NSData dataWithBytes:"1234" length:4] sampleFrameCount:1 streamTime:0 timeScale:48000 completedHandler:nil];
    [device drainTestQueues]; XCTAssertTrue(driver->preroll);
    __block BOOL rejected = NO;
    [session openWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    XCTAssertTrue(rejected); XCTAssertTrue(driver->preroll); XCTAssertNil(device.scheduledPlaybackSession);
    [session closeWithCompletion:nil]; [device drainTestQueues]; XCTAssertTrue(driver->preroll);
    [device stopScheduledPlaybackWithCompletionHandler:nil]; [device drainTestQueues];
}
- (void)testUnboundedAudioCapacityIsRejectedBeforeEnablingHardware {
    session = [[ManualPlaybackSession alloc] initWithDevice:device videoFormat:(__bridge CMVideoFormatDescriptionRef)videoFormat
        audioFormat:(__bridge CMAudioFormatDescriptionRef)audioFormat frameDuration:CMTimeMake(INT64_MAX,1) keyingMode:@"None"];
    __block BOOL rejected = NO;
    [session openWithCompletion:^(BOOL ok, NSError *error) { rejected = !ok && error != nil; }]; [device drainTestQueues];
    XCTAssertTrue(rejected); XCTAssertFalse(driver->videoEnabled); XCTAssertFalse(driver->audioEnabled);
}
@end
