#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include "MetalContext.h"
#include "MetalPlatform.h"
#include "openmm/Context.h"
#include "openmm/internal/ContextImpl.h"
#include <cstdio>

using namespace OpenMM;
class Access : public MetalPlatform {
public:
    MetalContext& metal(Context& context) const {
        return *reinterpret_cast<PlatformData*>(getContextImpl(context).getPlatformData())->contexts[0];
    }
};
extern "C" int beginCapture(Context* context, const char* path) {
    @autoreleasepool {
        Access access;
        MTLCaptureDescriptor* desc = [[MTLCaptureDescriptor alloc] init];
        desc.captureObject = (id<MTLDevice>)access.metal(*context).getDevice();
        desc.destination = MTLCaptureDestinationGPUTraceDocument;
        desc.outputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        NSError* error = nil;
        bool ok = [[MTLCaptureManager sharedCaptureManager] startCaptureWithDescriptor:desc error:&error];
        if (!ok)
            fprintf(stderr, "capture: %s\n", [[error localizedDescription] UTF8String]);
        [desc release];
        return ok ? 0 : 1;
    }
}
extern "C" void endCapture() {
    [[MTLCaptureManager sharedCaptureManager] stopCapture];
}
