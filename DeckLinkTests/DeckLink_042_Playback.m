#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>

#import "DeckLink.h"


@interface DeckLink_042_Playback : XCTestCase

@end


@implementation DeckLink_042_Playback

- (void)setUp
{
	[super setUp];
	
	self.continueAfterFailure = NO;
}

- (void)tearDown
{
	[super tearDown];
}

- (void)testVideoFormatDescriptions
{
	DeckLinkDevice *device = [DeckLinkDevice devicesWithIODirection:DeckLinkDeviceIODirectionPlayback].firstObject;
	XCTAssertNotNil(device);
	
	NSArray *videoFormatDescriptions = device.playbackVideoFormatDescriptions;
	XCTAssertGreaterThan(videoFormatDescriptions.count, 0);
	
	for (id videoFormatDescription_ in videoFormatDescriptions)
	{
		CMVideoFormatDescriptionRef videoFormatDescription = (__bridge CMVideoFormatDescriptionRef)videoFormatDescription_;
		
		XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"%s:%@", __FUNCTION__, videoFormatDescription]];
		[device setPlaybackActiveVideoFormatDescription:videoFormatDescription completedHandler:^(BOOL status, NSError *outError){
			if (status)
				[expectation fulfill];
		}];
		[self waitForExpectationsWithTimeout:1.0 handler:^(NSError *error) {}];
	}
}

- (void)testAudioFormatDescriptions
{
	DeckLinkDevice *device = [DeckLinkDevice devicesWithIODirection:DeckLinkDeviceIODirectionPlayback].firstObject;
	XCTAssertNotNil(device);
	
	NSArray *audioFormatDescriptions = device.playbackAudioFormatDescriptions;
	XCTAssertGreaterThan(audioFormatDescriptions.count, 0);
	
	for (id audioFormatDescription_ in audioFormatDescriptions)
	{
		CMAudioFormatDescriptionRef audioFormatDescription = (__bridge CMVideoFormatDescriptionRef)audioFormatDescription_;
		
		XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"%s:%@", __FUNCTION__, audioFormatDescription]];
		[device setPlaybackActiveAudioFormatDescription:audioFormatDescription completedHandler:^(BOOL status, NSError *outError){
			if (status)
				[expectation fulfill];
		}];
		[self waitForExpectationsWithTimeout:1.0 handler:^(NSError *error) {}];
	}
}

- (void)testKeying
{
	DeckLinkDevice *device = [DeckLinkDevice devicesWithIODirection:DeckLinkDeviceIODirectionPlayback].firstObject;
	XCTAssertNotNil(device);

	NSArray *keyingModes = device.playbackKeyingModes;
	// keyingModes may be nil
	
	for (NSString *keyingMode in keyingModes)
	{
		XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"%s:%@", __FUNCTION__, keyingMode]];
		[device setPlaybackActiveKeyingMode:keyingMode alpha:1 completedHandler:^(BOOL status, NSError *outError){
			if (status)
				[expectation fulfill];
		}];
		[self waitForExpectationsWithTimeout:1.0 handler:^(NSError *error) {}];
	}
	
	XCTestExpectation *expectation = [self expectationWithDescription:[NSString stringWithFormat:@"%s:Invalid", __FUNCTION__]];
	expectation.inverted = YES;
	[device setPlaybackActiveKeyingMode:@"Invalid" alpha:1 completedHandler:^(BOOL status, NSError *outError){
		if (status)
			[expectation fulfill];
	}];
	[self waitForExpectationsWithTimeout:1.0 handler:^(NSError *error) {}];
}

@end
