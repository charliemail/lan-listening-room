#import "RTCAudioDeviceShim.h"

RTCPeerConnectionFactory *LLMakeFactory(id<RTCAudioDevice> audioDevice) {
    return [[RTCPeerConnectionFactory alloc]
        initWithEncoderFactory:[[RTCDefaultVideoEncoderFactory alloc] init]
                decoderFactory:[[RTCDefaultVideoDecoderFactory alloc] init]
                   audioDevice:audioDevice];
}
