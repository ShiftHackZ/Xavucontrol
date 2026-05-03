#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>

/**
 * @file XavucontrolVirtualCable.cpp
 * @brief Single translation-unit entrypoint for the Xavucontrol Core Audio HAL driver.
 *
 * Core Audio loads this bundle through XavucontrolVirtualCableFactory. The implementation
 * is split into include sections under Driver/Sources for readability while preserving
 * the original anonymous namespace and link model.
 */

namespace {

#include "Sources/DriverState.inc.cpp"
#include "Sources/AudioBuffers.inc.cpp"
#include "Sources/PropertyModel.inc.cpp"
#include "Sources/DriverCallbacks.inc.cpp"
#include "Sources/PropertyAccess.inc.cpp"
#include "Sources/IOCallbacks.inc.cpp"

} // namespace

extern "C" __attribute__((visibility("default"))) void *XavucontrolVirtualCableFactory(CFAllocatorRef, CFUUIDRef inTypeUUID)
{
    if (CFEqual(inTypeUUID, kAudioServerPlugInTypeUUID)) {
        addRef(nullptr);
        return &gDriverInterfacePtr;
    }
    return nullptr;
}
