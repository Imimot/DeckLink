#import "DeckLinkDevice+Playback.h"

#import "CMFormatDescription+DeckLink.h"
#import "DeckLinkAPI.h"
#import "DeckLinkAudioConnection+Internal.h"
#import "DeckLinkDevice+Internal.h"
#import "DeckLinkKeying.h"
#import "DeckLinkVideoConnection+Internal.h"
#import "DecklinkMetalBufferFrame.h"


#include <limits.h>

static char DeckLinkPlaybackQueueKey;

static NSError *DeckLinkPlaybackError(HRESULT status) {
    return status == S_OK ? nil : [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
}

@interface DeckLinkScheduledFrame : NSObject {
@public
    IDeckLinkMutableVideoFrame *frame;
    CVPixelBufferRef pixelBuffer;
}
@property (copy) DeckLinkScheduledFrameCompletion completion;
@end
@implementation DeckLinkScheduledFrame
- (void)dealloc {
    if (frame) frame->Release();
    if (pixelBuffer) CFRelease(pixelBuffer);
}
@end

@implementation DeckLinkDevice (Playback)

- (void)initializePlaybackScheduling {
    self.playbackQueue = dispatch_queue_create("DeckLinkDevice.playbackQueue", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    dispatch_queue_set_specific(self.playbackQueue, &DeckLinkPlaybackQueueKey, (__bridge void *)self, NULL);
    self.frameDownloadQueue = dispatch_queue_create("DeckLinkDevice.frameDownloadQueue", DISPATCH_QUEUE_SERIAL);
    _playbackCallbackQueue = dispatch_queue_create("DeckLinkDevice.playbackCallbacks", DISPATCH_QUEUE_SERIAL);
    _scheduledFrames = [NSMutableDictionary new];
    _scheduledStopHandlers = [NSMutableArray new];
    atomic_init(&_sampleBufferCount_BackingStore, 0);
    atomic_init(&_scheduledFrameCount, 0);
    atomic_init(&_scheduledAudioRequests, 0);
    atomic_init(&_playbackGeneration, 0);
    atomic_init(&_scheduledStopRequested, false);
}

- (void)completePlaybackOperation:(DeckLinkPlaybackCompletion)completion status:(HRESULT)status {
    if (completion) dispatch_async(_playbackCallbackQueue ?: dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        completion(status == S_OK, DeckLinkPlaybackError(status));
    });
}

- (HRESULT)installScheduledPlaybackCallback {
    if (deckLinkOutputCallback) return S_OK;
    DeckLinkDeviceInternalOutputCallback *callback = new DeckLinkDeviceInternalOutputCallback((id<DeckLinkDeviceInternalOutputCallbackDelegate>)self);
    HRESULT status = deckLinkOutput->SetScheduledFrameCompletionCallback(callback);
    if (status != S_OK) callback->Release();
    else deckLinkOutputCallback = callback;
    return status;
}

- (void)finishScheduledStop:(HRESULT)status {
    _scheduledStopState = DeckLinkScheduledStopIdle;
    if (status == S_OK) {
        _scheduledAudioPrerolled = NO;
        self.playbackActive = NO;
    }
    atomic_store(&_scheduledStopRequested, false);
    NSArray *handlers = [_scheduledStopHandlers copy];
    [_scheduledStopHandlers removeAllObjects];
    // Finish the current frame/preparation callback before session cleanup can disable output.
    dispatch_async(self.playbackQueue, ^{
        for (DeckLinkPlaybackStatusCompletion handler in handlers) handler(status);
    });
}

- (void)finishScheduledStopIfReady {
    if (_scheduledStopState == DeckLinkScheduledStopWaitingForFrames && !atomic_load(&_scheduledFrameCount))
        [self finishScheduledStop:S_OK];
}

- (void)finishScheduledFrame:(NSValue *)key result:(BMDOutputFrameCompletionResult)result {
    DeckLinkScheduledFrame *entry = _scheduledFrames[key];
    if (!entry) return;
    [_scheduledFrames removeObjectForKey:key];
    atomic_fetch_sub(&_scheduledFrameCount, 1);
    atomic_fetch_sub(&_sampleBufferCount_BackingStore, 1);
    DeckLinkScheduledFrameResult publicResult = DeckLinkScheduledFrameFlushed;
    switch (result) {
        case bmdOutputFrameCompleted: publicResult = DeckLinkScheduledFrameCompleted; break;
        case bmdOutputFrameDisplayedLate: publicResult = DeckLinkScheduledFrameDisplayedLate; break;
        case bmdOutputFrameDropped: publicResult = DeckLinkScheduledFrameDropped; break;
        case bmdOutputFrameFlushed: break;
    }
    DeckLinkScheduledFrameCompletion completion = entry.completion;
    if (completion) completion(publicResult);
    [self finishScheduledStopIfReady];
}


- (void)setupPlayback
{
	if(deckLink->QueryInterface(IID_IDeckLinkOutput, (void **)&deckLinkOutput) != S_OK)
	{
		return;
	}
	
	HRESULT status = deckLinkConfiguration->SetFlag(bmdDeckLinkConfigFieldFlickerRemoval, false);
	if (status != S_OK)
	{
		NSLog(@"Decklink: error turning off bmdDeckLinkConfigFieldFlickerRemoval");
	} else {
		
		NSLog(@"Decklink: turned off bmdDeckLinkConfigFieldFlickerRemoval");

	}

	
	self.playbackSupported = YES;
	
	[self initializePlaybackScheduling];
	
	// Video
	IDeckLinkDisplayModeIterator *displayModeIterator = NULL;
	if (deckLinkOutput->GetDisplayModeIterator(&displayModeIterator) == S_OK)
	{
		BMDPixelFormat pixelFormats[] = {
			bmdFormat8BitYUV, // == kCVPixelFormatType_422YpCbCr8 == '2vuy'
			bmdFormat10BitYUVA, // 'Ay10'
			kDeckLinkPrimaryRGBPixelFormat,  
		};
		
		NSMutableArray *formatDescriptions = [NSMutableArray array];
		
		IDeckLinkDisplayMode *displayMode = NULL;
		while (displayModeIterator->Next(&displayMode) == S_OK)
		{
			BMDDisplayMode displayModeKey = displayMode->GetDisplayMode();
			
			for (size_t index = 0; index < sizeof(pixelFormats) / sizeof(*pixelFormats); ++index)
			{
				BMDPixelFormat pixelFormat = pixelFormats[index];
				
				bool supported = false;
				if (deckLinkOutput->DoesSupportVideoMode(bmdVideoConnectionUnspecified, displayModeKey, pixelFormat, bmdNoVideoOutputConversion, bmdVideoOutputFlagDefault, NULL, &supported) == S_OK && supported)
				{
					CMVideoFormatDescriptionRef formatDescription = NULL;
					if(CMVideoFormatDescriptionCreateWithDeckLinkDisplayMode(displayMode, pixelFormat, true, &formatDescription) == noErr)
					{
						[formatDescriptions addObject:(__bridge id)formatDescription];
						CFRelease(formatDescription);
					}
				}
			}
		}
		displayModeIterator->Release();
		
		self.playbackVideoFormatDescriptions = formatDescriptions;
		// TODO: get active format description from the device
	}
	
	// Audio
	{
		int64_t maxaudiochannels;
		deckLinkAttributes->GetInt(BMDDeckLinkMaximumAudioChannels, &maxaudiochannels);

		NSMutableArray *formatDescriptions = [NSMutableArray new];
		
		if (maxaudiochannels>=2) {
			
			//
			// for now, we only support 16bit audio
			//
			
			// bmdAudioSampleRate48kHz / bmdAudioSampleType16bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 4, 1, 4, 2, 16, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_Stereo, 0 };
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 16-bit, stereo"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			
			/*
			// bmdAudioSampleRate48kHz / bmdAudioSampleType32bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 8, 1, 8, 2, 32, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_Stereo, 0 };
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 32-bit, stereo"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			*/

		}
		
		if (maxaudiochannels>=8) {
			
			
			// bmdAudioSampleRate48kHz / bmdAudioSampleType16bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 4, 1, 4, 8, 16, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder| 8, 0 };
				
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 16-bit, 8 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			
			/*
			// bmdAudioSampleRate48kHz / bmdAudioSampleType32bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 8, 1, 8, 8, 32, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder | 8, 0 };

				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 32-bit, 8 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			*/
		}

		if (maxaudiochannels>=16) {
			
			
			// bmdAudioSampleRate48kHz / bmdAudioSampleType16bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 4, 1, 4, 16, 16, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder| 16, 0 };
				
				
				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 16-bit, 16 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			
			/*
			// bmdAudioSampleRate48kHz / bmdAudioSampleType32bitInteger
			{
				const AudioStreamBasicDescription streamBasicDescription = { 48000.0, kAudioFormatLinearPCM, kAudioFormatFlagIsSignedInteger, 8, 1, 8, 16, 32, 0 };
				const AudioChannelLayout channelLayout = { kAudioChannelLayoutTag_DiscreteInOrder | 16, 0 };

				NSDictionary *extensions = @{
					(__bridge id)kCMFormatDescriptionExtension_FormatName: @"48.000 Hz, 32-bit, 16 channels"
				};
				
				CMAudioFormatDescriptionRef formatDescription = NULL;
				CMAudioFormatDescriptionCreate(NULL, &streamBasicDescription, sizeof(channelLayout), &channelLayout, 0, NULL, (__bridge CFDictionaryRef)extensions, &formatDescription);
				
				if (formatDescription != NULL)
				{
					[formatDescriptions addObject:(__bridge id)formatDescription];
				}
			}
			 */

		}

		
		self.playbackAudioFormatDescriptions = formatDescriptions;
		// TODO: get active format description
	}
	
	if (deckLinkKeyer != NULL)
	{
		NSMutableArray *keyingModes = [NSMutableArray array];
		
		[keyingModes addObject:DeckLinkKeyingModeNone];
		
		bool supportsInternalKeying = false;
		deckLinkAttributes->GetFlag(BMDDeckLinkSupportsInternalKeying, &supportsInternalKeying);
		if (supportsInternalKeying)
		{
			[keyingModes addObject:DeckLinkKeyingModeInternal];
		}

		bool supportsExternalKeying = false;
		deckLinkAttributes->GetFlag(BMDDeckLinkSupportsExternalKeying, &supportsExternalKeying);
		if (supportsExternalKeying)
		{
			[keyingModes addObject:DeckLinkKeyingModeExternal];
		}

		self.playbackKeyingModes = keyingModes;
		self.playbackActiveKeyingMode = DeckLinkKeyingModeNone;
		self.playbackKeyingAlpha = 1.0;
		
		deckLinkKeyer->SetLevel(255);
		deckLinkKeyer->Disable();
	}
	else
	{
		self.playbackKeyingModes = @[ DeckLinkKeyingModeNone ];
	}
}

// Shared exclusion check for format changes and immediate playback. Call on playbackQueue.
- (BOOL)hasScheduledPlaybackOnQueue {
    return self.playbackActive || _scheduledAudioPrerolled ||
        atomic_load(&_scheduledFrameCount) || atomic_load(&_scheduledStopRequested);
}

- (BOOL)canOpenPlaybackSessionOnQueue {
    return deckLinkOutput && !self.scheduledPlaybackSession && !self.playbackActive &&
        !self.frameBufferCount && !atomic_load(&_scheduledAudioRequests) &&
        !_scheduledAudioPrerolled && !atomic_load(&_scheduledStopRequested);
}

- (void)performPlaybackSync:(dispatch_block_t)block {
    if (dispatch_get_specific(&DeckLinkPlaybackQueueKey) == (__bridge void *)self) block();
    else dispatch_sync(self.playbackQueue, block);
}

- (void)deliverPlaybackCallback:(dispatch_block_t)block {
    dispatch_async(_playbackCallbackQueue, block);
}

- (HRESULT)setVideoFormatOnPlaybackQueue:(CMVideoFormatDescriptionRef)format {
    if (!deckLinkOutput || [self hasScheduledPlaybackOnQueue]) return E_ACCESSDENIED;
    NSNumber *mode = nil;
    if (format) {
        if (![self.playbackVideoFormatDescriptions containsObject:(__bridge id)format]) return E_INVALIDARG;
        mode = (__bridge NSNumber *)CMFormatDescriptionGetExtension(format, DeckLinkFormatDescriptionDisplayModeKey);
        if (![mode isKindOfClass:NSNumber.class]) return E_INVALIDARG;
    }
    HRESULT status = self.playbackActiveVideoFormatDescription ? deckLinkOutput->DisableVideoOutput() : S_OK;
    if (status != S_OK) return status;
    self.playbackActiveVideoFormatDescription = NULL;
    if (format) status = deckLinkOutput->EnableVideoOutput(mode.intValue, bmdVideoOutputFlagDefault);
    if (status == S_OK) self.playbackActiveVideoFormatDescription = format;
    return status;
}

- (HRESULT)setAudioFormatOnPlaybackQueue:(CMAudioFormatDescriptionRef)format timestamped:(BOOL)timestamped {
    if (!deckLinkOutput || [self hasScheduledPlaybackOnQueue]) return E_ACCESSDENIED;
    const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    if (format && (![self.playbackAudioFormatDescriptions containsObject:(__bridge id)format] || !asbd)) return E_INVALIDARG;
    HRESULT status = self.playbackActiveAudioFormatDescription ? deckLinkOutput->DisableAudioOutput() : S_OK;
    if (status != S_OK) return status;
    self.playbackActiveAudioFormatDescription = NULL;
    if (format) status = deckLinkOutput->EnableAudioOutput((BMDAudioSampleRate)asbd->mSampleRate,
        (BMDAudioSampleType)asbd->mBitsPerChannel, asbd->mChannelsPerFrame,
        timestamped ? bmdAudioOutputStreamTimestamped : bmdAudioOutputStreamContinuous);
    if (status == S_OK) self.playbackActiveAudioFormatDescription = format;
    return status;
}

- (HRESULT)setKeyingOnPlaybackQueue:(NSString *)mode alpha:(float)alpha {
    if (!deckLinkOutput || self.playbackActive || atomic_load(&_scheduledFrameCount) || atomic_load(&_scheduledStopRequested)) return E_ACCESSDENIED;
    HRESULT status = S_OK;
    if (!mode || [mode isEqualToString:DeckLinkKeyingModeNone]) {
        if (deckLinkKeyer) status = deckLinkKeyer->Disable();
    } else if (deckLinkKeyer && ([mode isEqualToString:DeckLinkKeyingModeInternal] || [mode isEqualToString:DeckLinkKeyingModeExternal])) {
        status = deckLinkKeyer->Enable([mode isEqualToString:DeckLinkKeyingModeExternal]);
        if (status == S_OK) status = deckLinkKeyer->SetLevel((uint8_t)(MIN(1.0f, MAX(0.0f, alpha)) * 255.0f));
    } else status = E_INVALIDARG;
    if (status == S_OK) { self.playbackActiveKeyingMode = mode ?: DeckLinkKeyingModeNone; self.playbackKeyingAlpha = alpha; }
    return status;
}

- (void)setPlaybackActiveVideoFormatDescription:(CMVideoFormatDescriptionRef)format completedHandler:(DeckLinkPlaybackCompletion)completion {
    id retained = (__bridge id)format;
    dispatch_async(self.playbackQueue, ^{
        [self completePlaybackOperation:completion status:[self setVideoFormatOnPlaybackQueue:(__bridge CMVideoFormatDescriptionRef)retained]];
    });
}

- (void)setPlaybackActiveAudioFormatDescription:(CMAudioFormatDescriptionRef)format completedHandler:(DeckLinkPlaybackCompletion)completion {
    [self setPlaybackActiveAudioFormatDescription:format timestamped:NO completedHandler:completion];
}

- (void)setPlaybackActiveAudioFormatDescription:(CMAudioFormatDescriptionRef)format timestamped:(BOOL)timestamped completedHandler:(DeckLinkPlaybackCompletion)completion {
    id retained = (__bridge id)format;
    dispatch_async(self.playbackQueue, ^{
        [self completePlaybackOperation:completion status:[self setAudioFormatOnPlaybackQueue:(__bridge CMAudioFormatDescriptionRef)retained timestamped:timestamped]];
    });
}

- (void)setPlaybackActiveKeyingMode:(NSString *)mode alpha:(float)alpha completedHandler:(DeckLinkPlaybackCompletion)completion {
    dispatch_async(self.playbackQueue, ^{ [self completePlaybackOperation:completion status:[self setKeyingOnPlaybackQueue:mode alpha:alpha]]; });
}

/**
 * Allocates a CVPixelBufferRef which the caller can populate and play back.
 *
 * Based loosely on the Blackmagic MetalKeyer sample code's `[DeckLinkOutputDevice createVideoFrame:withPixelFormat:]` and `[MetalKeyer renderVideoFrame]` methods.
 */
- (CVPixelBufferRef)createCVPixelBufferWithWidth:(uint32_t)pixelsWide height:(uint32_t)pixelsHigh colorspace:(CFStringRef)colorspaceName
{
	// Wait for setPlaybackActiveVideoFormatDescription's block to complete.
	if (dispatch_get_specific(&DeckLinkPlaybackQueueKey) != (__bridge void *)self) dispatch_sync(self.playbackQueue, ^{});
    if (!deckLinkOutput || !self.playbackActiveVideoFormatDescription || !colorspaceName) return NULL;

	BMDPixelFormat pixelFormat = CMFormatDescriptionGetMediaSubType(self.playbackActiveVideoFormatDescription);
	int32_t rowBytes;
	HRESULT ret = deckLinkOutput->RowBytesForPixelFormat(pixelFormat, pixelsWide, &rowBytes);
	if (ret != S_OK)
	{
		NSLog(@"%s:%d: error: IDeckLinkOutput::RowBytesForPixelFormat(0x%x, %d) returned 0x%x; maybe this device doesn't support the specified pixelformat or size", __FUNCTION__, __LINE__, pixelFormat, pixelsWide, ret);
		return nil;
	}

	IDeckLinkMutableVideoFrame *videoFrame;
	ret = deckLinkOutput->CreateVideoFrame(pixelsWide, pixelsHigh, rowBytes, pixelFormat, bmdVideoOutputFlagDefault, &videoFrame);
	if (ret != S_OK)
	{
		NSLog(@"%s:%d: error: IDeckLinkOutput::CreateVideoFrame(%d, %d, %d, 0x%x) returned 0x%x; maybe this device doesn't support the specified pixelformat or size", __FUNCTION__, __LINE__, pixelsWide, pixelsHigh, rowBytes, pixelFormat, ret);
		return nil;
	}

	BMDColorspace blackmagicColorspace;
	if (CFEqual(colorspaceName, kCGColorSpaceITUR_709))
		blackmagicColorspace = bmdColorspaceRec709;
	else if (CFEqual(colorspaceName, kCGColorSpaceITUR_2020))
	{
		// For unknown reasons, the Blackmagic DeckLink SDK outputs nothing when Rec2020 colorspace is selected.
		// As a workaround, use Rec709.
		// blackmagicColorspace = bmdColorspaceRec2020;
		blackmagicColorspace = bmdColorspaceRec709;
	}
	else
	{
		NSLog(@"%s:%d: error: colorspace \"%@\" isn't implemented", __FUNCTION__, __LINE__, colorspaceName);
        videoFrame->Release();
		return nil;
	}

	IDeckLinkVideoFrameMutableMetadataExtensions *videoFrameMetadata = NULL;
	ret = videoFrame->QueryInterface(IID_IDeckLinkVideoFrameMutableMetadataExtensions, (void **)&videoFrameMetadata);
	if (ret != S_OK)
	{
		NSLog(@"%s:%d: error: IDeckLinkMutableVideoFrame::QueryInterface(IDeckLinkVideoFrameMutableMetadataExtensions) returned 0x%x; maybe you need to install newer Blackmagic Desktop Video drivers", __FUNCTION__, __LINE__, ret);
		videoFrame->Release();
		return nil;
	}
	ret = videoFrameMetadata->SetInt(bmdDeckLinkFrameMetadataColorspace, blackmagicColorspace);
    videoFrameMetadata->Release();
    if (ret != S_OK) { videoFrame->Release(); return NULL; }

	IDeckLinkMacVideoBuffer *macVideoBuffer = NULL;
	ret = videoFrame->QueryInterface(IID_IDeckLinkMacVideoBuffer, (void **)&macVideoBuffer);
	if (ret != S_OK)
	{
		NSLog(@"%s:%d: error: IDeckLinkMutableVideoFrame::QueryInterface(IDeckLinkMacVideoBuffer) returned 0x%x; maybe you need to install newer Blackmagic Desktop Video drivers", __FUNCTION__, __LINE__, ret);
		videoFrame->Release();
		return nil;
	}

	CVPixelBufferRef pixelBuffer = NULL;
	ret = macVideoBuffer->CreateCVPixelBufferRef((void **)&pixelBuffer);
    macVideoBuffer->Release();
	if (ret != S_OK)
	{
		NSLog(@"%s:%d: error: IDeckLinkMacVideoBuffer::CreateCVPixelBufferRef() returned 0x%x", __FUNCTION__, __LINE__, ret);
		videoFrame->Release();
		return nil;
	}

    videoFrame->Release();
	return pixelBuffer;
}

- (void)startScheduledPlaybackWithStartTime:(NSUInteger)startTime timeScale:(NSUInteger)timeScale {
    [self startScheduledPlaybackWithStartTime:startTime timeScale:timeScale completedHandler:^(BOOL success, NSError *error) {
        if (!success) NSLog(@"DeckLink scheduled start failed: %@", error);
    }];
}

- (HRESULT)startPlaybackOnQueue:(int64_t)startTime timeScale:(int64_t)timeScale {
    if (!deckLinkOutput || startTime < 0 || timeScale <= 0) return E_INVALIDARG;
    if (atomic_load(&_scheduledStopRequested) || self.playbackActive) return E_ACCESSDENIED;
    HRESULT status = [self installScheduledPlaybackCallback];
    if (status == S_OK && _audioPrerollActive) {
        status = deckLinkOutput->EndAudioPreroll();
        if (status == S_OK) _audioPrerollActive = NO;
    }
    if (status == S_OK) status = deckLinkOutput->StartScheduledPlayback(startTime, timeScale, 1.0);
    if (status == S_OK) self.playbackActive = YES;
    return status;
}

- (void)startScheduledPlaybackWithStartTime:(NSUInteger)startTime timeScale:(NSUInteger)timeScale completedHandler:(DeckLinkPlaybackCompletion)completion {
    if (!timeScale || timeScale > INT64_MAX || startTime > INT64_MAX) {
        [self completePlaybackOperation:completion status:E_INVALIDARG]; return;
    }
    uint64_t generation = atomic_load(&_playbackGeneration);
    // Preserve submission-before-start ordering for existing callers, while frame
    // preparation runs away from the queue responsible for audio deadlines.
    dispatch_async(self.frameDownloadQueue, ^{
        dispatch_async(self.playbackQueue, ^{
            HRESULT status = generation != atomic_load(&_playbackGeneration) ? E_ABORT :
                [self startPlaybackOnQueue:startTime timeScale:timeScale];
            [self completePlaybackOperation:completion status:status];
        });
    });
}

- (void)schedulePlaybackOfPixelBuffer:(CVPixelBufferRef)pixelBuffer displayTime:(NSUInteger)displayTime frameDuration:(NSUInteger)frameDuration timeScale:(NSUInteger)timeScale {
    [self schedulePlaybackOfPixelBuffer:pixelBuffer displayTime:displayTime frameDuration:frameDuration timeScale:timeScale acceptedHandler:^(BOOL success, NSError *error) {
        if (!success) NSLog(@"DeckLink frame scheduling failed: %@", error);
    } completedHandler:nil];
}

- (void)schedulePlaybackOfPixelBuffer:(CVPixelBufferRef)pixelBuffer displayTime:(NSUInteger)displayTime frameDuration:(NSUInteger)frameDuration timeScale:(NSUInteger)timeScale acceptedHandler:(DeckLinkPlaybackCompletion)acceptedHandler completedHandler:(DeckLinkScheduledFrameCompletion)completedHandler {
    if (!frameDuration || !timeScale || displayTime > INT64_MAX || frameDuration > INT64_MAX || timeScale > INT64_MAX || displayTime > INT64_MAX - frameDuration) {
        [self completePlaybackOperation:acceptedHandler status:E_INVALIDARG]; return;
    }
    dispatch_queue_t callbackQueue = _playbackCallbackQueue;
    DeckLinkScheduledFrameCompletion completion = completedHandler ? ^(DeckLinkScheduledFrameResult result) {
        dispatch_async(callbackQueue, ^{ completedHandler(result); });
    } : (DeckLinkScheduledFrameCompletion)nil;
    [self enqueuePlaybackPixelBuffer:pixelBuffer frameDuration:frameDuration timeScale:timeScale
        maximumFrames:8 displayTime:^int64_t { return displayTime; }
        accepted:^(HRESULT status) { [self completePlaybackOperation:acceptedHandler status:status]; }
        completed:completion];
}

// Admission includes frames still being prepared. The time provider executes on
// playbackQueue immediately before ScheduleVideoFrame, not before GPU/CPU work.
- (void)enqueuePlaybackPixelBuffer:(CVPixelBufferRef)pixelBuffer frameDuration:(int64_t)duration timeScale:(int64_t)scale
                    maximumFrames:(NSUInteger)maximum displayTime:(int64_t (^)(void))displayTime
                         accepted:(void (^)(HRESULT))accepted completed:(DeckLinkScheduledFrameCompletion)completed {
    void (^reject)(HRESULT) = ^(HRESULT status) { dispatch_async(self.playbackQueue, ^{ if (accepted) accepted(status); }); };
    if (!deckLinkOutput || !pixelBuffer || duration <= 0 || scale <= 0 || !maximum) { reject(E_INVALIDARG); return; }
    if (atomic_load(&_scheduledStopRequested)) { reject(E_ABORT); return; }
    uint64_t generation = atomic_load(&_playbackGeneration);
    uint_fast64_t count = atomic_load(&_scheduledFrameCount);
    do {
        if (count >= maximum) { reject(E_OUTOFMEMORY); return; }
    } while (!atomic_compare_exchange_weak(&_scheduledFrameCount, &count, count + 1));
    atomic_fetch_add(&_sampleBufferCount_BackingStore, 1);
    DeckLinkScheduledFrame *entry = [DeckLinkScheduledFrame new];
    entry->pixelBuffer = CVPixelBufferRetain(pixelBuffer);
    entry.completion = completed;
    dispatch_async(self.frameDownloadQueue, ^{
        HRESULT prepared = E_ABORT;
        if (generation == atomic_load(&_playbackGeneration) && !atomic_load(&_scheduledStopRequested)) {
            IDeckLinkMacOutput *macOutput = NULL;
            prepared = deckLinkOutput->QueryInterface(IID_IDeckLinkMacOutput, (void **)&macOutput);
            if (prepared == S_OK) prepared = macOutput->CreateVideoFrameFromCVPixelBufferRef(entry->pixelBuffer, &entry->frame);
            if (macOutput) macOutput->Release();
        }
        dispatch_async(self.playbackQueue, ^{
            HRESULT status = prepared;
            if (generation != atomic_load(&_playbackGeneration) || atomic_load(&_scheduledStopRequested)) status = E_ABORT;
            int64_t time = -1;
            if (status == S_OK) {
                time = displayTime();
                // A negative time means the session no longer needs this frame/slot.
                if (time < 0) status = S_FALSE;
                else if (time > INT64_MAX - duration) status = E_INVALIDARG;
            }
            if (status == S_OK) status = [self installScheduledPlaybackCallback];
            if (status == S_OK) {
                NSValue *key = [NSValue valueWithPointer:entry->frame];
                _scheduledFrames[key] = entry;
                status = deckLinkOutput->ScheduleVideoFrame(entry->frame, time, duration, scale);
                if (status != S_OK) [_scheduledFrames removeObjectForKey:key];
            }
            if (status != S_OK) {
                atomic_fetch_sub(&_scheduledFrameCount, 1);
                atomic_fetch_sub(&_sampleBufferCount_BackingStore, 1);
            }
            if (accepted) accepted(status);
            [self finishScheduledStopIfReady];
        });
    });
}

- (void)scheduledFrameCompleted:(IDeckLinkVideoFrame *)frame result:(BMDOutputFrameCompletionResult)result {
    NSValue *key = [NSValue valueWithPointer:frame];
    dispatch_async(self.playbackQueue, ^{ [self finishScheduledFrame:key result:result]; });
}

- (void)scheduledPlaybackHasStopped {
    dispatch_async(self.playbackQueue, ^{
        if (_scheduledStopState == DeckLinkScheduledStopWaitingForDriver)
            _scheduledStopState = DeckLinkScheduledStopWaitingForFrames;
        self.playbackActive = NO;
        [self finishScheduledStopIfReady];
    });
}

- (void)stopScheduledPlaybackWithCompletionHandler:(DeckLinkDeviceStopPlaybackCompletionHandler)completion {
    if (!deckLinkOutput) {
        [self completePlaybackOperation:completion status:E_ACCESSDENIED];
        return;
    }
    [self stopScheduledPlaybackWithInternalCompletion:^(HRESULT status) {
        [self completePlaybackOperation:completion status:status];
    }];
}

- (void)stopScheduledPlaybackWithInternalCompletion:(DeckLinkPlaybackStatusCompletion)completion {
    atomic_store(&_scheduledStopRequested, true);
    atomic_fetch_add(&_playbackGeneration, 1);
    // Drain preparation before disabling a prerolled output. Cancellation is
    // visible immediately, so prepared frames cannot enter the old scheduler.
    dispatch_async(self.frameDownloadQueue, ^{
      dispatch_async(self.playbackQueue, ^{
        if (completion) [_scheduledStopHandlers addObject:[completion copy]];
        if (_scheduledStopState != DeckLinkScheduledStopIdle) return;
        _scheduledStopState = DeckLinkScheduledStopWaitingForDriver;
        bool running = false;
        HRESULT status = S_OK;
        if (_audioPrerollActive) {
            status = deckLinkOutput->EndAudioPreroll();
            if (status == S_OK) _audioPrerollActive = NO;
        }
        if (status == S_OK) status = deckLinkOutput->IsScheduledPlaybackRunning(&running);
        if (status == S_OK && running) {
            status = deckLinkOutput->StopScheduledPlayback(0, NULL, 0);
        } else if (status == S_OK) {
            // Preroll has no running scheduler to emit a stopped callback.
            // Disable flushes retained frames; restore the configured mode afterward.
            if (_scheduledFrames.count) {
                status = deckLinkOutput->DisableVideoOutput();
                if (status == S_OK) {
                    for (NSValue *key in [_scheduledFrames.allKeys copy]) [self finishScheduledFrame:key result:bmdOutputFrameFlushed];
                    if (self.playbackActiveVideoFormatDescription) {
                        NSNumber *mode = (__bridge NSNumber *)CMFormatDescriptionGetExtension(self.playbackActiveVideoFormatDescription, DeckLinkFormatDescriptionDisplayModeKey);
                        status = mode ? deckLinkOutput->EnableVideoOutput(mode.intValue, bmdVideoOutputFlagDefault) : E_INVALIDARG;
                    }
                }
            }
            if (status == S_OK) {
                status = deckLinkOutput->FlushBufferedAudioSamples();
                // Audio may not be enabled on a video-only device/session.
                if (!self.playbackActiveAudioFormatDescription) status = S_OK;
            }
            _scheduledStopState = DeckLinkScheduledStopWaitingForFrames;
            if (status == S_OK) [self finishScheduledStopIfReady];
        }
        if (status != S_OK) [self finishScheduledStop:status];
      });
    });
}

- (HRESULT)writeAudioOnPlaybackQueue:(const void *)bytes sampleFrameCount:(UInt32)count
                         streamTime:(int64_t)time timeScale:(int64_t)scale written:(UInt32 *)written {
    *written = 0;
    if (!deckLinkOutput || !bytes || !count || time < 0 || scale <= 0) return E_INVALIDARG;
    if (atomic_load(&_scheduledStopRequested)) return E_ABORT;
    HRESULT status = S_OK;
    if (!self.playbackActive && !_audioPrerollActive) {
        status = deckLinkOutput->BeginAudioPreroll();
        if (status == S_OK) { _audioPrerollActive = YES; _scheduledAudioPrerolled = YES; }
    }
    if (status == S_OK) status = deckLinkOutput->ScheduleAudioSamples((void *)bytes, count, time, scale, written);
    if (*written) _scheduledAudioPrerolled = YES;
    return status;
}

- (HRESULT)readPlaybackClockOnQueue:(DeckLinkPlaybackClock *)clock {
    *clock = {};
    if (!deckLinkOutput) return E_ACCESSDENIED;
    HRESULT status = deckLinkOutput->IsScheduledPlaybackRunning(&clock->running);
    if (status == S_OK && self.playbackActiveAudioFormatDescription) status = deckLinkOutput->GetBufferedAudioSampleFrameCount(&clock->audioSamples);
    // Pair host and stream time at the native query, before any callback dispatch.
    double before = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    if (status == S_OK && clock->running) status = deckLinkOutput->GetScheduledStreamTime(48000, &clock->streamTime, &clock->speed);
    double after = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
    clock->hostTime = (before + after) * 0.5;
    return status;
}

- (void)scheduleAudioData:(NSData *)data sampleFrameCount:(UInt32)sampleFrameCount streamTime:(int64_t)streamTime timeScale:(int64_t)timeScale completedHandler:(void (^)(UInt32, NSError *))completion {
    void (^report)(UInt32, HRESULT) = ^(UInt32 written, HRESULT status) {
        if (completion) dispatch_async(_playbackCallbackQueue ?: dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(written, DeckLinkPlaybackError(status)); });
    };
    if (!deckLinkOutput || !data || !sampleFrameCount || streamTime < 0 || timeScale <= 0 || data.length > 8 * 1024 * 1024) {
        report(0, E_INVALIDARG); return;
    }
    if (atomic_load(&_scheduledStopRequested)) { report(0, E_ABORT); return; }
    uint64_t generation = atomic_load(&_playbackGeneration);
    uint_fast64_t count = atomic_load(&_scheduledAudioRequests);
    do {
        if (count >= 8) { report(0, E_OUTOFMEMORY); return; }
    } while (!atomic_compare_exchange_weak(&_scheduledAudioRequests, &count, count + 1));
    NSData *ownedData = [data copy];
    dispatch_async(self.playbackQueue, ^{
        HRESULT status = S_OK;
        uint32_t written = 0;
        const AudioStreamBasicDescription *format = self.playbackActiveAudioFormatDescription ? CMAudioFormatDescriptionGetStreamBasicDescription(self.playbackActiveAudioFormatDescription) : NULL;
        if (generation != atomic_load(&_playbackGeneration) || atomic_load(&_scheduledStopRequested)) status = E_ABORT;
        else if (!format || !format->mChannelsPerFrame || (format->mBitsPerChannel != 16 && format->mBitsPerChannel != 32) || sampleFrameCount > ownedData.length / ((uint64_t)format->mChannelsPerFrame * (format->mBitsPerChannel / 8))) status = E_INVALIDARG;
        else status = [self writeAudioOnPlaybackQueue:ownedData.bytes sampleFrameCount:sampleFrameCount streamTime:streamTime timeScale:timeScale written:&written];
        atomic_fetch_sub(&_scheduledAudioRequests, 1);
        report(written, status);
    });
}

- (void)getScheduledPlaybackStatusWithTimeScale:(NSUInteger)timeScale completedHandler:(void (^)(BOOL, int64_t, NSUInteger, NSUInteger, NSError *))completion {
    if (!completion) return;
    if (!deckLinkOutput || !timeScale || timeScale > INT64_MAX) {
        dispatch_async(_playbackCallbackQueue ?: dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{ completion(NO, 0, 0, 0, DeckLinkPlaybackError(E_INVALIDARG)); });
        return;
    }
    dispatch_async(self.frameDownloadQueue, ^{
      dispatch_async(self.playbackQueue, ^{
        bool running = false;
        BMDTimeValue streamTime = 0;
        double speed = 0;
        uint32_t video = 0, audio = 0;
        HRESULT status = deckLinkOutput->IsScheduledPlaybackRunning(&running);
        if (status == S_OK) status = deckLinkOutput->GetBufferedVideoFrameCount(&video);
        if (status == S_OK && self.playbackActiveAudioFormatDescription) status = deckLinkOutput->GetBufferedAudioSampleFrameCount(&audio);
        if (status == S_OK && running) status = deckLinkOutput->GetScheduledStreamTime(timeScale, &streamTime, &speed);
        dispatch_async(_playbackCallbackQueue, ^{ completion(running, streamTime, video, audio, DeckLinkPlaybackError(status)); });
      });
    });
}

- (void)playbackPixelBuffer:(CVPixelBufferRef)pixelBuffer {

	[self playbackPixelBuffer:pixelBuffer isFlipped:NO];
}

- (void)playbackPixelBuffer:(CVPixelBufferRef)pixelBuffer isFlipped:(BOOL)flipped
{
	uint64_t generation = atomic_load(&_playbackGeneration);
	atomic_fetch_add(&_sampleBufferCount_BackingStore, 1);

	CFRetain(pixelBuffer);
	dispatch_async(self.frameDownloadQueue, ^{
		// The first queue just creates an IDeckLinkVideoFrame (possibly downloading the frame from GPU to CPU RAM) even if the playbackQueue is sending out data to the device.
		
		IDeckLinkMacOutput *deckLinkMacOutput = NULL;
		if (deckLinkOutput->QueryInterface(IID_IDeckLinkMacOutput, (void **)&deckLinkMacOutput) != S_OK)
		{
			NSLog(@"%s:%d: error: couldn't get IDeckLinkMacOutput instance; maybe you need to install newer Blackmagic Desktop Video drivers", __FUNCTION__, __LINE__);
			CFRelease(pixelBuffer);
            atomic_fetch_sub(&_sampleBufferCount_BackingStore, 1);
			return;
		}

		IDeckLinkMutableVideoFrame *frame = NULL;
		HRESULT ret = deckLinkMacOutput->CreateVideoFrameFromCVPixelBufferRef(pixelBuffer, &frame);
        deckLinkMacOutput->Release();
		if (ret != S_OK)
		{
			if (ret == E_INVALIDARG)
				NSLog(@"%s:%d: error: CreateVideoFrameFromCVPixelBufferRef failed: E_INVALIDARG (One of the attributes/attachments of the provided CVPixelBuffer is not supported.  The CVPixelBuffer may be missing a value for attachment kCVImageBufferColorPrimariesKey.)", __FUNCTION__, __LINE__);
			else
				NSLog(@"%s:%d: error: CreateVideoFrameFromCVPixelBufferRef failed: %x", __FUNCTION__, __LINE__, ret);

			CFRelease(pixelBuffer);
            atomic_fetch_sub(&_sampleBufferCount_BackingStore, 1);
			return;
		}

		if (flipped) {
			
			frame->SetFlags(bmdFrameFlagFlipVertical);
		}
		
		dispatch_async(self.playbackQueue, ^{
			// the second queue is sending the image data to the device immediately but don't need to wait for next download
		//	NSLog(@"calling DisplayVideoFrameSync...");
			if (generation == atomic_load(&_playbackGeneration) && ![self hasScheduledPlaybackOnQueue])
                deckLinkOutput->DisplayVideoFrameSync(frame);
            else NSLog(@"DeckLink: immediate frame rejected during scheduled playback");
		//	NSLog(@"DisplayVideoFrameSync done!");
			frame->Release();
			
			CFRelease(pixelBuffer);

			atomic_fetch_add(&_sampleBufferCount_BackingStore, -1);

		});

	});
}

- (void)playbackMetalBuffer:(id<MTLBuffer>)metalBuffer ofSize:(NSSize)size rowBytes:(NSUInteger)rowBytes pixelFormat:(uint32_t)pixelformat isFlipped:(BOOL)flipped {
	
	atomic_fetch_add(&_sampleBufferCount_BackingStore, 1);

	//
	// unlike playbackPixelBuffer: this operation is happening synchronously
	// the metalBuffer is already in CPU RAM, and it is not retained, so when the operation is finished, we can re-use it on the host app
	//
	
	DeckLinkMetalBufferFrame *frame = new DeckLinkMetalBufferFrame(metalBuffer);
	
	frame->SetWidth((long)size.width);
	frame->SetHeight((long)size.height);
	frame->SetRowBytes((long)rowBytes);
	
	frame->SetPixelFormat(pixelformat);
	
	//NSLog(@"width: %lld height: %lld rowbytes: %lld", frame->GetWidth(), frame->GetHeight(), frame->GetRowBytes());
	
	if (flipped)
	{
		
		frame->setFlags(bmdFrameFlagFlipVertical);
	}
	
	// the second queue is sending the image data to the device immediately but don't need to wait for next download
    void (^display)(void) = ^{
	if (![self hasScheduledPlaybackOnQueue])
                deckLinkOutput->DisplayVideoFrameSync(frame);
            else NSLog(@"DeckLink: immediate frame rejected during scheduled playback");
    };
    if (dispatch_get_specific(&DeckLinkPlaybackQueueKey) == (__bridge void *)self) display();
    else dispatch_sync(self.playbackQueue, display);
	frame->Release();
	

	atomic_fetch_add(&_sampleBufferCount_BackingStore, -1);

}


- (void)playbackContinuousAudioBufferList:(AudioBufferList *)audioBufferList numberOfSamples:(UInt32)numberOfSamples completionHandler:(void(^)(void))completionHandler
{
	dispatch_async(self.playbackQueue, ^{
		uint32_t outNumberOfSamples = 0;
        HRESULT writeStatus = E_ACCESSDENIED;
		if (![self hasScheduledPlaybackOnQueue])
            writeStatus = deckLinkOutput->WriteAudioSamplesSync(audioBufferList->mBuffers[0].mData, numberOfSamples, &outNumberOfSamples);
		
		if (writeStatus != S_OK || numberOfSamples != outNumberOfSamples)
		{
			NSLog(@"%s:%d:Dropped Audio Samples: %u != %u (status 0x%08x)", __FUNCTION__, __LINE__, numberOfSamples, outNumberOfSamples, (unsigned int)writeStatus);
		}
		
		if (completionHandler)
		{
			completionHandler();
		}
	});
}

- (void)playback16bitAudioBuffer:(short *)audiobuffer numberOfSamples:(UInt32)numberOfSamples completionHandler:(void(^)(void))completionHandler
{
	dispatch_async(self.playbackQueue, ^{
		uint32_t outNumberOfSamples = 0;
        HRESULT writeStatus = E_ACCESSDENIED;
		if (![self hasScheduledPlaybackOnQueue])
            writeStatus = deckLinkOutput->WriteAudioSamplesSync(audiobuffer, numberOfSamples, &outNumberOfSamples);
		free(audiobuffer);
		if (writeStatus != S_OK || numberOfSamples != outNumberOfSamples)
		{
			NSLog(@"%s:%d:Dropped Audio Samples: %u != %u (status 0x%08x)", __FUNCTION__, __LINE__, numberOfSamples, outNumberOfSamples, (unsigned int)writeStatus);
		}
		
		if (completionHandler)
		{
			completionHandler();
		}
	});
}


- (NSUInteger)frameBufferCount
{
	return _sampleBufferCount_BackingStore;
}

@end
