#import "DeckLinkDeviceInternalOutputCallback.h"

#include <stdatomic.h>

DeckLinkDeviceInternalOutputCallback::DeckLinkDeviceInternalOutputCallback(id<DeckLinkDeviceInternalOutputCallbackDelegate> delegate) :
delegate(delegate),
refCount(1)
{
}

HRESULT DeckLinkDeviceInternalOutputCallback::ScheduledFrameCompleted(IDeckLinkVideoFrame *completedFrame, BMDOutputFrameCompletionResult result)
{
	id<DeckLinkDeviceInternalOutputCallbackDelegate> target = delegate;
	if([target respondsToSelector:@selector(scheduledFrameCompleted:result:)])
	{
		[target scheduledFrameCompleted:completedFrame result:result];
	}
	return S_OK;
}

HRESULT DeckLinkDeviceInternalOutputCallback::ScheduledPlaybackHasStopped(void)
{
	id<DeckLinkDeviceInternalOutputCallbackDelegate> target = delegate;
	if([target respondsToSelector:@selector(scheduledPlaybackHasStopped)])
	{
		[target scheduledPlaybackHasStopped];
	}
	return S_OK;
}

HRESULT DeckLinkDeviceInternalOutputCallback::RenderAudioSamples(bool preroll)
{
	id<DeckLinkDeviceInternalOutputCallbackDelegate> target = delegate;
	if([target respondsToSelector:@selector(renderAudioSamplesPreroll:)])
	{
		[target renderAudioSamplesPreroll:preroll ? YES : NO];
	}
	return S_OK;
}

HRESULT DeckLinkDeviceInternalOutputCallback::QueryInterface(REFIID iid, LPVOID *ppv)
{
	if (!ppv) return E_POINTER;
	*ppv = NULL;
	
	CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
	if(memcmp(&iid, &iunknown, sizeof(REFIID)) == 0)
	{
		*ppv = this;
		AddRef();
		return S_OK;
	}
	
	if(memcmp(&iid, &IID_IDeckLinkVideoOutputCallback, sizeof(REFIID)) == 0)
	{
		*ppv = this;
		AddRef();
		return S_OK;
	}
	
	if(memcmp(&iid, &IID_IDeckLinkAudioOutputCallback, sizeof(REFIID)) == 0)
	{
		*ppv = this;
		AddRef();
		return S_OK;
	}
	
	return E_NOINTERFACE;
}

ULONG DeckLinkDeviceInternalOutputCallback::AddRef(void)
{
	return atomic_fetch_add(&refCount, 1) + 1;
}

ULONG DeckLinkDeviceInternalOutputCallback::Release(void)
{
	int32_t oldRefValue = atomic_fetch_add(&refCount, -1);	// Note: atomic_fetch_add() returns the previous value
	int32_t newRefValue = oldRefValue - 1;
	
	if(newRefValue == 0)
	{
		delete this;
		return 0;
	}
	
	return newRefValue;
}
