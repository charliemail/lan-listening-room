#import <WebRTC/WebRTC.h>
#import "RTCAudioDevice.h"

NS_ASSUME_NONNULL_BEGIN

// The macOS slice of stasel/WebRTC ships the ObjC ADM code but not RTCAudioDevice.h,
// so Swift cannot see the factory initializer's parameter type. Build it here instead.
RTCPeerConnectionFactory *LLMakeFactory(id<RTCAudioDevice> audioDevice);

NS_ASSUME_NONNULL_END
