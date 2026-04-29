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

namespace {

constexpr AudioObjectID kObjectIDPlugIn = kAudioObjectPlugInObject;
constexpr AudioObjectID kObjectIDOutputDevice = 2;
constexpr AudioObjectID kObjectIDOutputStream = 3;
constexpr AudioObjectID kObjectIDInputDevice = 4;
constexpr AudioObjectID kObjectIDInputStream = 5;

constexpr Float64 kDefaultSampleRate = 48000.0;
constexpr UInt32 kDefaultBufferFrameSize = 512;
constexpr UInt32 kChannelCount = 2;
constexpr UInt32 kDefaultZeroTimeStampPeriod = 16384;
constexpr UInt32 kDiagnosticsVersion = 6;
constexpr AudioObjectPropertySelector kXavucontrolPropertyDiagnosticsVersion = 'pvvs';
constexpr AudioObjectPropertySelector kXavucontrolPropertyCapturedFrames = 'pvfr';
constexpr AudioObjectPropertySelector kXavucontrolPropertyIOCycles = 'pvcy';
constexpr AudioObjectPropertySelector kXavucontrolPropertyLastPeak = 'pvpk';
constexpr AudioObjectPropertySelector kXavucontrolPropertyLastRMS = 'pvrm';
constexpr UInt32 kSharedDiagnosticsMagic = 0x50564144; // PVAD
constexpr const char *kSharedDiagnosticsPath = "/tmp/xavucontrol_virtual_cable_diag_v1";
constexpr size_t kSharedAudioDataOffset = 4096;
constexpr size_t kSharedAudioCapacityBytes = 2 * 1024 * 1024;
constexpr size_t kSharedMicrophoneDataOffset = kSharedAudioDataOffset + kSharedAudioCapacityBytes;
constexpr size_t kSharedDiagnosticsSize = kSharedMicrophoneDataOffset + kSharedAudioCapacityBytes;

static const CFStringRef kOutputDeviceName = CFSTR("Xavucontrol Virtual Cable");
static const CFStringRef kInputDeviceName = CFSTR("Xavucontrol Virtual Mic");
static const CFStringRef kManufacturerName = CFSTR("xavucontrol-macos diagnostics-v1");
static const CFStringRef kBundleID = CFSTR("org.moroz.xavucontrol.virtualcable");
static const CFStringRef kModelUID = CFSTR("org.moroz.xavucontrol.virtualcable.diagnostics-v1");
static const CFStringRef kOutputDeviceUID = CFSTR("org.moroz.xavucontrol.virtualcable.device");
static const CFStringRef kInputDeviceUID = CFSTR("org.moroz.xavucontrol.virtualmic.device");
__attribute__((used)) static const char *kBuildMarker = "xavucontrol-virtual-cable-shared-audio-v1";

struct SharedDiagnostics {
    UInt32 magic;
    UInt32 version;
    UInt64 cycles;
    UInt64 frames;
    Float32 peak;
    Float32 rms;
    UInt64 startCount;
    UInt64 stopCount;
    UInt64 willMixOutputCount;
    UInt64 willWriteMixCount;
    UInt64 doMixOutputCount;
    UInt64 doWriteMixCount;
    UInt32 lastOperation;
    UInt64 willThreadCount;
    UInt64 willCycleCount;
    UInt64 beginThreadCount;
    UInt64 beginCycleCount;
    UInt64 beginWriteMixCount;
    UInt64 endThreadCount;
    UInt64 endCycleCount;
    UInt64 endWriteMixCount;
    UInt32 lastBeginOperation;
    UInt32 lastEndOperation;
    UInt32 audioCapacityBytes;
    UInt32 audioBytesPerFrame;
    Float64 audioSampleRate;
    UInt64 audioWriteBytePosition;
    UInt64 audioFramesWritten;
    UInt64 audioDroppedBytes;
    UInt32 microphoneCapacityBytes;
    UInt32 microphoneBytesPerFrame;
    Float64 microphoneSampleRate;
    UInt64 microphoneWriteBytePosition;
    UInt64 microphoneReadBytePosition;
    UInt64 microphoneFramesWritten;
    UInt64 microphoneFramesRead;
    UInt64 microphoneUnderrunFrames;
    Float32 microphonePeak;
    Float32 microphoneRMS;
};

AudioServerPlugInHostRef gHost = nullptr;
std::atomic<UInt32> gRefCount { 1 };
std::atomic<bool> gIsRunning { false };
std::atomic<Float64> gSampleRate { kDefaultSampleRate };
std::atomic<UInt32> gBufferFrameSize { kDefaultBufferFrameSize };
std::atomic<UInt64> gCapturedFrames { 0 };
std::atomic<UInt64> gIOCycleCount { 0 };
std::atomic<Float32> gLastPeak { 0 };
std::atomic<Float32> gLastRMS { 0 };
std::atomic<UInt64> gStartCount { 0 };
std::atomic<UInt64> gStopCount { 0 };
std::atomic<UInt64> gWillMixOutputCount { 0 };
std::atomic<UInt64> gWillWriteMixCount { 0 };
std::atomic<UInt64> gDoMixOutputCount { 0 };
std::atomic<UInt64> gDoWriteMixCount { 0 };
std::atomic<UInt32> gLastOperation { 0 };
std::atomic<UInt64> gWillThreadCount { 0 };
std::atomic<UInt64> gWillCycleCount { 0 };
std::atomic<UInt64> gBeginThreadCount { 0 };
std::atomic<UInt64> gBeginCycleCount { 0 };
std::atomic<UInt64> gBeginWriteMixCount { 0 };
std::atomic<UInt64> gEndThreadCount { 0 };
std::atomic<UInt64> gEndCycleCount { 0 };
std::atomic<UInt64> gEndWriteMixCount { 0 };
std::atomic<UInt32> gLastBeginOperation { 0 };
std::atomic<UInt32> gLastEndOperation { 0 };
std::atomic<UInt64> gRunningClientCount { 0 };
std::atomic<UInt64> gNumberTimeStamps { 0 };
std::atomic<UInt64> gMicrophoneReadBytePosition { 0 };
std::atomic<UInt64> gMicrophoneFramesRead { 0 };
std::atomic<UInt64> gMicrophoneUnderrunFrames { 0 };
std::atomic<Float32> gMicrophonePeak { 0 };
std::atomic<Float32> gMicrophoneRMS { 0 };
std::atomic<bool> gMicrophonePrimed { false };
UInt64 gStartHostTime = 0;
os_log_t gLog = os_log_create("org.moroz.xavucontrol.virtualcable", "HAL");
SharedDiagnostics *gSharedDiagnostics = nullptr;

extern AudioServerPlugInDriverInterface gDriverInterface;
AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;

bool uuidEquals(REFIID requestedUUID, CFUUIDRef expectedUUID)
{
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, requestedUUID);
    const bool result = CFEqual(requested, expectedUUID);
    CFRelease(requested);
    return result;
}

AudioStreamBasicDescription currentStreamFormat()
{
    AudioStreamBasicDescription format {};
    format.mSampleRate = gSampleRate.load();
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket = sizeof(Float32) * kChannelCount;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32) * kChannelCount;
    format.mChannelsPerFrame = kChannelCount;
    format.mBitsPerChannel = sizeof(Float32) * 8;
    return format;
}

Float64 hostTicksPerFrame()
{
    mach_timebase_info_data_t timebase {};
    mach_timebase_info(&timebase);
    const Float64 hostClockFrequency = (static_cast<Float64>(timebase.denom) / static_cast<Float64>(timebase.numer)) * 1'000'000'000.0;
    return hostClockFrequency / gSampleRate.load();
}

void initializeSharedDiagnostics()
{
    if (gSharedDiagnostics != nullptr) {
        return;
    }

    const int fd = open(kSharedDiagnosticsPath, O_CREAT | O_RDWR, 0666);
    if (fd == -1) {
        return;
    }

    fchmod(fd, 0666);

    if (ftruncate(fd, kSharedDiagnosticsSize) == -1) {
        close(fd);
        return;
    }

    void *mapping = mmap(nullptr, kSharedDiagnosticsSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) {
        return;
    }

    gSharedDiagnostics = static_cast<SharedDiagnostics *>(mapping);
    gSharedDiagnostics->magic = kSharedDiagnosticsMagic;
    gSharedDiagnostics->version = kDiagnosticsVersion;
    gSharedDiagnostics->cycles = 0;
    gSharedDiagnostics->frames = 0;
    gSharedDiagnostics->peak = 0;
    gSharedDiagnostics->rms = 0;
    gSharedDiagnostics->startCount = 0;
    gSharedDiagnostics->stopCount = 0;
    gSharedDiagnostics->willMixOutputCount = 0;
    gSharedDiagnostics->willWriteMixCount = 0;
    gSharedDiagnostics->doMixOutputCount = 0;
    gSharedDiagnostics->doWriteMixCount = 0;
    gSharedDiagnostics->lastOperation = 0;
    gSharedDiagnostics->willThreadCount = 0;
    gSharedDiagnostics->willCycleCount = 0;
    gSharedDiagnostics->beginThreadCount = 0;
    gSharedDiagnostics->beginCycleCount = 0;
    gSharedDiagnostics->beginWriteMixCount = 0;
    gSharedDiagnostics->endThreadCount = 0;
    gSharedDiagnostics->endCycleCount = 0;
    gSharedDiagnostics->endWriteMixCount = 0;
    gSharedDiagnostics->lastBeginOperation = 0;
    gSharedDiagnostics->lastEndOperation = 0;
    gSharedDiagnostics->audioCapacityBytes = UInt32(kSharedAudioCapacityBytes);
    gSharedDiagnostics->audioBytesPerFrame = sizeof(Float32) * kChannelCount;
    gSharedDiagnostics->audioSampleRate = gSampleRate.load();
    gSharedDiagnostics->audioWriteBytePosition = 0;
    gSharedDiagnostics->audioFramesWritten = 0;
    gSharedDiagnostics->audioDroppedBytes = 0;
    gSharedDiagnostics->microphoneCapacityBytes = UInt32(kSharedAudioCapacityBytes);
    gSharedDiagnostics->microphoneBytesPerFrame = sizeof(Float32) * kChannelCount;
    gSharedDiagnostics->microphoneSampleRate = gSampleRate.load();
    gSharedDiagnostics->microphoneWriteBytePosition = 0;
    gSharedDiagnostics->microphoneReadBytePosition = 0;
    gSharedDiagnostics->microphoneFramesWritten = 0;
    gSharedDiagnostics->microphoneFramesRead = 0;
    gSharedDiagnostics->microphoneUnderrunFrames = 0;
    gSharedDiagnostics->microphonePeak = 0;
    gSharedDiagnostics->microphoneRMS = 0;
}

void updateSharedDiagnostics()
{
    if (gSharedDiagnostics == nullptr) {
        return;
    }

    gSharedDiagnostics->magic = kSharedDiagnosticsMagic;
    gSharedDiagnostics->version = kDiagnosticsVersion;
    gSharedDiagnostics->cycles = gIOCycleCount.load();
    gSharedDiagnostics->frames = gCapturedFrames.load();
    gSharedDiagnostics->peak = gLastPeak.load();
    gSharedDiagnostics->rms = gLastRMS.load();
    gSharedDiagnostics->startCount = gStartCount.load();
    gSharedDiagnostics->stopCount = gStopCount.load();
    gSharedDiagnostics->willMixOutputCount = gWillMixOutputCount.load();
    gSharedDiagnostics->willWriteMixCount = gWillWriteMixCount.load();
    gSharedDiagnostics->doMixOutputCount = gDoMixOutputCount.load();
    gSharedDiagnostics->doWriteMixCount = gDoWriteMixCount.load();
    gSharedDiagnostics->lastOperation = gLastOperation.load();
    gSharedDiagnostics->willThreadCount = gWillThreadCount.load();
    gSharedDiagnostics->willCycleCount = gWillCycleCount.load();
    gSharedDiagnostics->beginThreadCount = gBeginThreadCount.load();
    gSharedDiagnostics->beginCycleCount = gBeginCycleCount.load();
    gSharedDiagnostics->beginWriteMixCount = gBeginWriteMixCount.load();
    gSharedDiagnostics->endThreadCount = gEndThreadCount.load();
    gSharedDiagnostics->endCycleCount = gEndCycleCount.load();
    gSharedDiagnostics->endWriteMixCount = gEndWriteMixCount.load();
    gSharedDiagnostics->lastBeginOperation = gLastBeginOperation.load();
    gSharedDiagnostics->lastEndOperation = gLastEndOperation.load();
    gSharedDiagnostics->audioCapacityBytes = UInt32(kSharedAudioCapacityBytes);
    gSharedDiagnostics->audioBytesPerFrame = sizeof(Float32) * kChannelCount;
    gSharedDiagnostics->audioSampleRate = gSampleRate.load();
    gSharedDiagnostics->microphoneCapacityBytes = UInt32(kSharedAudioCapacityBytes);
    gSharedDiagnostics->microphoneBytesPerFrame = sizeof(Float32) * kChannelCount;
    gSharedDiagnostics->microphoneSampleRate = gSampleRate.load();
    gSharedDiagnostics->microphoneReadBytePosition = gMicrophoneReadBytePosition.load();
    gSharedDiagnostics->microphoneFramesRead = gMicrophoneFramesRead.load();
    gSharedDiagnostics->microphoneUnderrunFrames = gMicrophoneUnderrunFrames.load();
    gSharedDiagnostics->microphonePeak = gMicrophonePeak.load();
    gSharedDiagnostics->microphoneRMS = gMicrophoneRMS.load();
}

void writeSharedAudio(const void *buffer, UInt32 frameCount)
{
    if (gSharedDiagnostics == nullptr || buffer == nullptr || frameCount == 0) {
        return;
    }

    const size_t bytesPerFrame = sizeof(Float32) * kChannelCount;
    size_t byteCount = static_cast<size_t>(frameCount) * bytesPerFrame;
    const auto *source = static_cast<const UInt8 *>(buffer);
    if (byteCount > kSharedAudioCapacityBytes) {
        const size_t bytesToSkip = byteCount - kSharedAudioCapacityBytes;
        source += bytesToSkip;
        byteCount = kSharedAudioCapacityBytes;
        gSharedDiagnostics->audioDroppedBytes += bytesToSkip;
    }

    auto *sharedBytes = reinterpret_cast<UInt8 *>(gSharedDiagnostics);
    auto *audioData = sharedBytes + kSharedAudioDataOffset;
    const UInt64 writePosition = gSharedDiagnostics->audioWriteBytePosition;
    const size_t writeOffset = static_cast<size_t>(writePosition % kSharedAudioCapacityBytes);
    const size_t firstChunk = std::min(byteCount, kSharedAudioCapacityBytes - writeOffset);
    std::memcpy(audioData + writeOffset, source, firstChunk);
    if (firstChunk < byteCount) {
        std::memcpy(audioData, source + firstChunk, byteCount - firstChunk);
    }

    gSharedDiagnostics->audioFramesWritten += frameCount;
    gSharedDiagnostics->audioWriteBytePosition = writePosition + byteCount;
}

void updateInputDiagnostics(const void *buffer, UInt32 frameCount)
{
    if (buffer == nullptr || frameCount == 0) {
        gLastPeak.store(0);
        gLastRMS.store(0);
        gIOCycleCount.fetch_add(1);
        updateSharedDiagnostics();
        return;
    }

    const auto *samples = static_cast<const Float32 *>(buffer);
    const UInt32 sampleCount = frameCount * kChannelCount;
    Float32 peak = 0;
    Float64 sumSquares = 0;
    for (UInt32 index = 0; index < sampleCount; ++index) {
        const Float32 sample = samples[index];
        peak = std::max(peak, std::abs(sample));
        sumSquares += static_cast<Float64>(sample) * static_cast<Float64>(sample);
    }

    gCapturedFrames.fetch_add(frameCount);
    gLastPeak.store(peak);
    gLastRMS.store(static_cast<Float32>(std::sqrt(sumSquares / sampleCount)));
    writeSharedAudio(buffer, frameCount);

    gIOCycleCount.fetch_add(1);
    updateSharedDiagnostics();
}

void updateMicrophoneDiagnostics(const void *buffer, UInt32 frameCount)
{
    if (buffer == nullptr || frameCount == 0) {
        gMicrophonePeak.store(0);
        gMicrophoneRMS.store(0);
        updateSharedDiagnostics();
        return;
    }

    const auto *samples = static_cast<const Float32 *>(buffer);
    const UInt32 sampleCount = frameCount * kChannelCount;
    Float32 peak = 0;
    Float64 sumSquares = 0;
    for (UInt32 index = 0; index < sampleCount; ++index) {
        const Float32 sample = samples[index];
        peak = std::max(peak, std::abs(sample));
        sumSquares += static_cast<Float64>(sample) * static_cast<Float64>(sample);
    }

    gMicrophonePeak.store(peak);
    gMicrophoneRMS.store(static_cast<Float32>(std::sqrt(sumSquares / sampleCount)));
    updateSharedDiagnostics();
}

void readSharedMicrophoneAudio(void *buffer, UInt32 frameCount)
{
    if (buffer == nullptr || frameCount == 0) {
        return;
    }

    const size_t bytesPerFrame = sizeof(Float32) * kChannelCount;
    const size_t byteCount = static_cast<size_t>(frameCount) * bytesPerFrame;
    auto *destination = static_cast<UInt8 *>(buffer);

    if (gSharedDiagnostics == nullptr) {
        std::memset(destination, 0, byteCount);
        gMicrophoneUnderrunFrames.fetch_add(frameCount);
        updateMicrophoneDiagnostics(buffer, frameCount);
        return;
    }

    const UInt64 writePosition = gSharedDiagnostics->microphoneWriteBytePosition;
    UInt64 readPosition = gMicrophoneReadBytePosition.load();
    const UInt64 capacity = UInt64(kSharedAudioCapacityBytes);

    if (writePosition < readPosition) {
        readPosition = writePosition;
        gMicrophoneReadBytePosition.store(readPosition);
        gMicrophonePrimed.store(false);
    }

    UInt64 available = writePosition > readPosition ? writePosition - readPosition : 0;
    if (available > capacity) {
        const UInt64 prebufferBytes = UInt64(bytesPerFrame) * 4096;
        readPosition = writePosition > prebufferBytes ? writePosition - prebufferBytes : writePosition;
        gMicrophoneReadBytePosition.store(readPosition);
        gMicrophonePrimed.store(true);
        available = writePosition > readPosition ? writePosition - readPosition : 0;
    }

    const UInt64 prebufferBytes = UInt64(bytesPerFrame) * 4096;
    const UInt64 targetPrebufferBytes = std::max<UInt64>(byteCount, prebufferBytes);
    if (!gMicrophonePrimed.load() && available < targetPrebufferBytes) {
        std::memset(destination, 0, byteCount);
        gMicrophoneUnderrunFrames.fetch_add(frameCount);
        gSharedDiagnostics->microphoneReadBytePosition = readPosition;
        updateMicrophoneDiagnostics(buffer, frameCount);
        return;
    }

    if (available < byteCount) {
        std::memset(destination, 0, byteCount);
        gMicrophoneUnderrunFrames.fetch_add(frameCount);
        gMicrophonePrimed.store(false);
        gSharedDiagnostics->microphoneReadBytePosition = readPosition;
        updateMicrophoneDiagnostics(buffer, frameCount);
        return;
    }

    size_t bytesToCopy = static_cast<size_t>(std::min<UInt64>(writePosition - readPosition, byteCount));
    auto *sharedBytes = reinterpret_cast<UInt8 *>(gSharedDiagnostics);
    auto *microphoneData = sharedBytes + kSharedMicrophoneDataOffset;
    const size_t readOffset = static_cast<size_t>(readPosition % capacity);
    const size_t firstChunk = std::min(bytesToCopy, kSharedAudioCapacityBytes - readOffset);
    std::memcpy(destination, microphoneData + readOffset, firstChunk);
    if (firstChunk < bytesToCopy) {
        std::memcpy(destination + firstChunk, microphoneData, bytesToCopy - firstChunk);
    }

    if (bytesToCopy < byteCount) {
        std::memset(destination + bytesToCopy, 0, byteCount - bytesToCopy);
        gMicrophoneUnderrunFrames.fetch_add((byteCount - bytesToCopy) / bytesPerFrame);
    }

    readPosition += bytesToCopy;
    gMicrophoneReadBytePosition.store(readPosition);
    gMicrophonePrimed.store(true);
    gMicrophoneFramesRead.fetch_add(bytesToCopy / bytesPerFrame);
    updateMicrophoneDiagnostics(buffer, frameCount);
}

template <typename T>
OSStatus writeScalar(UInt32 inDataSize, UInt32 *outDataSize, void *outData, const T &value)
{
    if (inDataSize < sizeof(T)) {
        return kAudioHardwareBadPropertySizeError;
    }

    *reinterpret_cast<T *>(outData) = value;
    *outDataSize = sizeof(T);
    return kAudioHardwareNoError;
}

void logUnknownProperty(const char *operation, AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    if (address == nullptr) {
        return;
    }

    char selector[5] = {
        static_cast<char>((address->mSelector >> 24) & 0xFF),
        static_cast<char>((address->mSelector >> 16) & 0xFF),
        static_cast<char>((address->mSelector >> 8) & 0xFF),
        static_cast<char>(address->mSelector & 0xFF),
        0
    };
    char scope[5] = {
        static_cast<char>((address->mScope >> 24) & 0xFF),
        static_cast<char>((address->mScope >> 16) & 0xFF),
        static_cast<char>((address->mScope >> 8) & 0xFF),
        static_cast<char>(address->mScope & 0xFF),
        0
    };

    os_log_error(gLog, "%{public}s unknown property object=%u selector=%{public}s scope=%{public}s element=%u",
        operation,
        objectID,
        selector,
        scope,
        address->mElement);
}

OSStatus writeString(UInt32 inDataSize, UInt32 *outDataSize, void *outData, CFStringRef value)
{
    if (inDataSize < sizeof(CFStringRef)) {
        return kAudioHardwareBadPropertySizeError;
    }

    *reinterpret_cast<CFStringRef *>(outData) = static_cast<CFStringRef>(CFRetain(value));
    *outDataSize = sizeof(CFStringRef);
    return kAudioHardwareNoError;
}

bool isPlugInObject(AudioObjectID objectID)
{
    return objectID == kObjectIDPlugIn;
}

bool isDeviceObject(AudioObjectID objectID)
{
    return objectID == kObjectIDOutputDevice || objectID == kObjectIDInputDevice;
}

bool isStreamObject(AudioObjectID objectID)
{
    return objectID == kObjectIDOutputStream || objectID == kObjectIDInputStream;
}

bool isOutputDeviceObject(AudioObjectID objectID)
{
    return objectID == kObjectIDOutputDevice;
}

bool isInputDeviceObject(AudioObjectID objectID)
{
    return objectID == kObjectIDInputDevice;
}

AudioObjectID streamOwner(AudioObjectID streamObjectID)
{
    return streamObjectID == kObjectIDInputStream ? kObjectIDInputDevice : kObjectIDOutputDevice;
}

bool hasObjectProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
        return isPlugInObject(objectID) || isDeviceObject(objectID) || isStreamObject(objectID);
    default:
        return false;
    }
}

bool hasPlugInProperty(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioPlugInPropertyBundleID:
    case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyBoxList:
    case kAudioPlugInPropertyTranslateUIDToBox:
    case kAudioPlugInPropertyClockDeviceList:
    case kAudioPlugInPropertyTranslateUIDToClockDevice:
        return true;
    default:
        return false;
    }
}

bool hasDeviceProperty(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceIsRunningSomewhere:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyClockAlgorithm:
    case kAudioDevicePropertyClockIsStable:
    case kAudioDevicePropertyBufferFrameSize:
    case kAudioDevicePropertyBufferFrameSizeRange:
    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
    case kAudioDevicePropertyIOCycleUsage:
    case kAudioDevicePropertyIOProcStreamUsage:
    case kAudioDevicePropertyActualSampleRate:
    case kAudioDevicePropertyStreamConfiguration:
    case kAudioDevicePropertyStreams:
    case kAudioObjectPropertyControlList:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyPreferredChannelsForStereo:
    case kXavucontrolPropertyDiagnosticsVersion:
    case kXavucontrolPropertyCapturedFrames:
    case kXavucontrolPropertyIOCycles:
    case kXavucontrolPropertyLastPeak:
    case kXavucontrolPropertyLastRMS:
        return true;
    default:
        return false;
    }
}

bool hasStreamProperty(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailablePhysicalFormats:
    case kAudioStreamPropertyLatency:
        return true;
    default:
        return false;
    }
}

UInt32 objectPropertyDataSize(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
        return sizeof(UInt32);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
        return sizeof(CFStringRef);
    case kAudioObjectPropertyOwnedObjects:
        if (isPlugInObject(objectID)) {
            return sizeof(AudioObjectID) * 2;
        }
        if (isDeviceObject(objectID)) {
            return sizeof(AudioObjectID);
        }
        return 0;
    default:
        return 0;
    }
}

UInt32 plugInPropertyDataSize(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioPlugInPropertyBundleID:
        return sizeof(CFStringRef);
    case kAudioPlugInPropertyDeviceList:
        return sizeof(AudioObjectID) * 2;
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyTranslateUIDToBox:
    case kAudioPlugInPropertyTranslateUIDToClockDevice:
        return sizeof(AudioObjectID);
    case kAudioPlugInPropertyBoxList:
    case kAudioPlugInPropertyClockDeviceList:
        return 0;
    default:
        return 0;
    }
}

UInt32 devicePropertyDataSize(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
        return sizeof(CFStringRef);
    case kAudioDevicePropertyRelatedDevices:
        return sizeof(AudioObjectID) * 2;
    case kAudioObjectPropertyControlList:
        return 0;
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceIsRunningSomewhere:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyClockAlgorithm:
    case kAudioDevicePropertyClockIsStable:
    case kAudioDevicePropertyBufferFrameSize:
    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
        return sizeof(UInt32);
    case kAudioDevicePropertyIOCycleUsage:
        return sizeof(Float32);
    case kAudioDevicePropertyIOProcStreamUsage:
        return offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + sizeof(UInt32);
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyActualSampleRate:
        return sizeof(Float64);
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyBufferFrameSizeRange:
        return sizeof(AudioValueRange);
    case kAudioDevicePropertyPreferredChannelsForStereo:
        return sizeof(UInt32) * 2;
    case kXavucontrolPropertyDiagnosticsVersion:
        return sizeof(UInt32);
    case kXavucontrolPropertyCapturedFrames:
    case kXavucontrolPropertyIOCycles:
        return sizeof(UInt64);
    case kXavucontrolPropertyLastPeak:
    case kXavucontrolPropertyLastRMS:
        return sizeof(Float32);
    case kAudioDevicePropertyStreams:
        return (address->mScope == kAudioObjectPropertyScopeOutput || address->mScope == kAudioObjectPropertyScopeInput)
            ? sizeof(AudioObjectID)
            : 0;
    case kAudioDevicePropertyStreamConfiguration:
        return offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
    default:
        return 0;
    }
}

UInt32 streamPropertyDataSize(const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
    case kAudioStreamPropertyLatency:
        return sizeof(UInt32);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        return sizeof(AudioStreamBasicDescription);
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        return sizeof(AudioStreamRangedDescription);
    default:
        return 0;
    }
}

HRESULT STDMETHODCALLTYPE queryInterface(void *, REFIID inUUID, LPVOID *outInterface)
{
    if (outInterface == nullptr) {
        return E_POINTER;
    }

    *outInterface = nullptr;
    if (uuidEquals(inUUID, IUnknownUUID) || uuidEquals(inUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        gRefCount.fetch_add(1);
        *outInterface = &gDriverInterfacePtr;
        return S_OK;
    }

    return E_NOINTERFACE;
}

ULONG STDMETHODCALLTYPE addRef(void *)
{
    return gRefCount.fetch_add(1) + 1;
}

ULONG STDMETHODCALLTYPE release(void *)
{
    const UInt32 previous = gRefCount.fetch_sub(1);
    return previous > 0 ? previous - 1 : 0;
}

OSStatus STDMETHODCALLTYPE initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef inHost)
{
    gHost = inHost;
    gStartHostTime = mach_absolute_time();
    gNumberTimeStamps.store(0);
    initializeSharedDiagnostics();
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE createDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *)
{
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus STDMETHODCALLTYPE destroyDevice(AudioServerPlugInDriverRef, AudioObjectID)
{
    return kAudioHardwareUnsupportedOperationError;
}

OSStatus STDMETHODCALLTYPE addDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *)
{
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE removeDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *)
{
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE performDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *)
{
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE abortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *)
{
    return kAudioHardwareNoError;
}

Boolean STDMETHODCALLTYPE hasProperty(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress)
{
    if (inAddress == nullptr) {
        return false;
    }

    if (hasObjectProperty(inObjectID, inAddress)) {
        return true;
    }
    if (isPlugInObject(inObjectID) && hasPlugInProperty(inAddress)) {
        return true;
    }
    if (isDeviceObject(inObjectID) && hasDeviceProperty(inAddress)) {
        return true;
    }
    if (isStreamObject(inObjectID) && hasStreamProperty(inAddress)) {
        return true;
    }
    return false;
}

OSStatus STDMETHODCALLTYPE isPropertySettable(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable)
{
    if (outIsSettable == nullptr || inAddress == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    *outIsSettable = false;
    if (isDeviceObject(inObjectID)) {
        *outIsSettable = inAddress->mSelector == kAudioDevicePropertyNominalSampleRate ||
            inAddress->mSelector == kAudioDevicePropertyBufferFrameSize ||
            inAddress->mSelector == kAudioDevicePropertyIOProcStreamUsage;
    }
    if (isStreamObject(inObjectID)) {
        *outIsSettable = inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat;
    }
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE getPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, UInt32, const void *, UInt32 *outDataSize)
{
    if (inAddress == nullptr || outDataSize == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    UInt32 size = objectPropertyDataSize(inObjectID, inAddress);
    if (size == 0 && isPlugInObject(inObjectID)) {
        size = plugInPropertyDataSize(inAddress);
    }
    if (size == 0 && isDeviceObject(inObjectID)) {
        size = devicePropertyDataSize(inAddress);
    }
    if (size == 0 && isStreamObject(inObjectID)) {
        size = streamPropertyDataSize(inAddress);
    }

    if (size == 0 && !hasProperty(nullptr, inObjectID, 0, inAddress)) {
        logUnknownProperty("GetPropertyDataSize", inObjectID, inAddress);
        return kAudioHardwareUnknownPropertyError;
    }

    *outDataSize = size;
    return kAudioHardwareNoError;
}

OSStatus writeObjectProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    switch (inAddress->mSelector) {
    case kAudioObjectPropertyClass:
        if (isPlugInObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioPlugInClassID));
        }
        if (isDeviceObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioDeviceClassID));
        }
        if (isStreamObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioStreamClassID));
        }
        break;
    case kAudioObjectPropertyOwner:
        if (isPlugInObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, AudioObjectID(kAudioObjectUnknown));
        }
        if (isDeviceObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, kObjectIDPlugIn);
        }
        if (isStreamObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, streamOwner(inObjectID));
        }
        break;
    case kAudioObjectPropertyName:
        if (inObjectID == kObjectIDInputDevice || inObjectID == kObjectIDInputStream) {
            return writeString(inDataSize, outDataSize, outData, kInputDeviceName);
        }
        return writeString(inDataSize, outDataSize, outData, kOutputDeviceName);
    case kAudioObjectPropertyManufacturer:
        return writeString(inDataSize, outDataSize, outData, kManufacturerName);
    case kAudioObjectPropertyOwnedObjects:
        if (isPlugInObject(inObjectID)) {
            if (inDataSize < sizeof(AudioObjectID) * 2) {
                return kAudioHardwareBadPropertySizeError;
            }
            auto *objects = reinterpret_cast<AudioObjectID *>(outData);
            objects[0] = kObjectIDOutputDevice;
            objects[1] = kObjectIDInputDevice;
            *outDataSize = sizeof(AudioObjectID) * 2;
            return kAudioHardwareNoError;
        }
        if (isOutputDeviceObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, kObjectIDOutputStream);
        }
        if (isInputDeviceObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, kObjectIDInputStream);
        }
        break;
    default:
        break;
    }

    logUnknownProperty("GetPropertyData", inObjectID, inAddress);
    return kAudioHardwareUnknownPropertyError;
}

OSStatus writePlugInProperty(const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    switch (inAddress->mSelector) {
    case kAudioPlugInPropertyBundleID:
        return writeString(inDataSize, outDataSize, outData, kBundleID);
    case kAudioPlugInPropertyDeviceList: {
        if (inDataSize < sizeof(AudioObjectID) * 2) {
            return kAudioHardwareBadPropertySizeError;
        }
        auto *devices = reinterpret_cast<AudioObjectID *>(outData);
        devices[0] = kObjectIDOutputDevice;
        devices[1] = kObjectIDInputDevice;
        *outDataSize = sizeof(AudioObjectID) * 2;
        return kAudioHardwareNoError;
    }
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID objectID = kAudioObjectUnknown;
        if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != nullptr) {
            auto uid = *reinterpret_cast<CFStringRef const *>(inQualifierData);
            if (uid != nullptr && CFEqual(uid, kOutputDeviceUID)) {
                objectID = kObjectIDOutputDevice;
            } else if (uid != nullptr && CFEqual(uid, kInputDeviceUID)) {
                objectID = kObjectIDInputDevice;
            }
        }
        return writeScalar(inDataSize, outDataSize, outData, objectID);
    }
    case kAudioPlugInPropertyBoxList:
    case kAudioPlugInPropertyClockDeviceList:
        *outDataSize = 0;
        return kAudioHardwareNoError;
    case kAudioPlugInPropertyTranslateUIDToBox:
    case kAudioPlugInPropertyTranslateUIDToClockDevice:
        return writeScalar(inDataSize, outDataSize, outData, AudioObjectID(kAudioObjectUnknown));
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus writeDeviceProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    switch (inAddress->mSelector) {
    case kAudioDevicePropertyDeviceUID:
        return writeString(inDataSize, outDataSize, outData, isInputDeviceObject(inObjectID) ? kInputDeviceUID : kOutputDeviceUID);
    case kAudioDevicePropertyModelUID:
        return writeString(inDataSize, outDataSize, outData, kModelUID);
    case kAudioDevicePropertyTransportType:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioDeviceTransportTypeVirtual));
    case kAudioDevicePropertyRelatedDevices:
        if (inDataSize < sizeof(AudioObjectID) * 2) {
            return kAudioHardwareBadPropertySizeError;
        }
        reinterpret_cast<AudioObjectID *>(outData)[0] = kObjectIDOutputDevice;
        reinterpret_cast<AudioObjectID *>(outData)[1] = kObjectIDInputDevice;
        *outDataSize = sizeof(AudioObjectID) * 2;
        return kAudioHardwareNoError;
    case kAudioObjectPropertyControlList:
        *outDataSize = 0;
        return kAudioHardwareNoError;
    case kAudioDevicePropertyClockDomain:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(0));
    case kAudioDevicePropertyDeviceIsAlive:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(1));
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceIsRunningSomewhere:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(gIsRunning.load() ? 1 : 0));
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(
            (isOutputDeviceObject(inObjectID) && inAddress->mScope == kAudioObjectPropertyScopeOutput)
                || (isInputDeviceObject(inObjectID) && inAddress->mScope == kAudioObjectPropertyScopeInput)
                ? 1
                : 0
        ));
    case kAudioDevicePropertyZeroTimeStampPeriod:
        return writeScalar(inDataSize, outDataSize, outData, kDefaultZeroTimeStampPeriod);
    case kAudioDevicePropertyClockAlgorithm:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioDeviceClockAlgorithmSimpleIIR));
    case kAudioDevicePropertyClockIsStable:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(1));
    case kAudioDevicePropertyNominalSampleRate:
        return writeScalar(inDataSize, outDataSize, outData, gSampleRate.load());
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        if (inDataSize < sizeof(AudioValueRange)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioValueRange range {};
        range.mMinimum = kDefaultSampleRate;
        range.mMaximum = kDefaultSampleRate;
        return writeScalar(inDataSize, outDataSize, outData, range);
    }
    case kAudioDevicePropertyBufferFrameSize:
        return writeScalar(inDataSize, outDataSize, outData, gBufferFrameSize.load());
    case kAudioDevicePropertyBufferFrameSizeRange: {
        if (inDataSize < sizeof(AudioValueRange)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioValueRange range {};
        range.mMinimum = kDefaultBufferFrameSize;
        range.mMaximum = kDefaultBufferFrameSize;
        return writeScalar(inDataSize, outDataSize, outData, range);
    }
    case kAudioDevicePropertyUsesVariableBufferFrameSizes:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(0));
    case kAudioDevicePropertyIOCycleUsage:
        return writeScalar(inDataSize, outDataSize, outData, Float32(0.1));
    case kAudioDevicePropertyActualSampleRate:
        return writeScalar(inDataSize, outDataSize, outData, gSampleRate.load());
    case kAudioDevicePropertyIOProcStreamUsage: {
        const UInt32 neededSize = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + sizeof(UInt32);
        if (inDataSize < neededSize) {
            return kAudioHardwareBadPropertySizeError;
        }
        auto *usage = reinterpret_cast<AudioHardwareIOProcStreamUsage *>(outData);
        usage->mNumberStreams = 1;
        usage->mStreamIsOn[0] = 1;
        *outDataSize = neededSize;
        return kAudioHardwareNoError;
    }
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(0));
    case kAudioDevicePropertyPreferredChannelsForStereo:
        if (inDataSize < sizeof(UInt32) * 2) {
            return kAudioHardwareBadPropertySizeError;
        }
        reinterpret_cast<UInt32 *>(outData)[0] = 1;
        reinterpret_cast<UInt32 *>(outData)[1] = 2;
        *outDataSize = sizeof(UInt32) * 2;
        return kAudioHardwareNoError;
    case kXavucontrolPropertyDiagnosticsVersion:
        return writeScalar(inDataSize, outDataSize, outData, kDiagnosticsVersion);
    case kXavucontrolPropertyCapturedFrames:
        return writeScalar(inDataSize, outDataSize, outData, gCapturedFrames.load());
    case kXavucontrolPropertyIOCycles:
        return writeScalar(inDataSize, outDataSize, outData, gIOCycleCount.load());
    case kXavucontrolPropertyLastPeak:
        return writeScalar(inDataSize, outDataSize, outData, gLastPeak.load());
    case kXavucontrolPropertyLastRMS:
        return writeScalar(inDataSize, outDataSize, outData, gLastRMS.load());
    case kAudioDevicePropertyStreams:
        if (isOutputDeviceObject(inObjectID) && inAddress->mScope == kAudioObjectPropertyScopeOutput) {
            return writeScalar(inDataSize, outDataSize, outData, kObjectIDOutputStream);
        }
        if (isInputDeviceObject(inObjectID) && inAddress->mScope == kAudioObjectPropertyScopeInput) {
            return writeScalar(inDataSize, outDataSize, outData, kObjectIDInputStream);
        }
        *outDataSize = 0;
        return kAudioHardwareNoError;
    case kAudioDevicePropertyStreamConfiguration: {
        const UInt32 neededSize = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
        if (inDataSize < neededSize) {
            return kAudioHardwareBadPropertySizeError;
        }
        auto *bufferList = reinterpret_cast<AudioBufferList *>(outData);
        bufferList->mNumberBuffers = 1;
        if ((isOutputDeviceObject(inObjectID) && inAddress->mScope != kAudioObjectPropertyScopeOutput)
            || (isInputDeviceObject(inObjectID) && inAddress->mScope != kAudioObjectPropertyScopeInput)) {
            *outDataSize = 0;
            return kAudioHardwareNoError;
        }
        bufferList->mBuffers[0].mNumberChannels = kChannelCount;
        bufferList->mBuffers[0].mDataByteSize = 0;
        bufferList->mBuffers[0].mData = nullptr;
        *outDataSize = neededSize;
        return kAudioHardwareNoError;
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus writeStreamProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    switch (inAddress->mSelector) {
    case kAudioStreamPropertyDirection:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(inObjectID == kObjectIDInputStream ? 1 : 0));
    case kAudioStreamPropertyTerminalType:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(0));
    case kAudioStreamPropertyStartingChannel:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(1));
    case kAudioStreamPropertyLatency:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(0));
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        return writeScalar(inDataSize, outDataSize, outData, currentStreamFormat());
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        if (inDataSize < sizeof(AudioStreamRangedDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioStreamRangedDescription description {};
        description.mFormat = currentStreamFormat();
        description.mSampleRateRange.mMinimum = kDefaultSampleRate;
        description.mSampleRateRange.mMaximum = kDefaultSampleRate;
        return writeScalar(inDataSize, outDataSize, outData, description);
    }
    default:
        return kAudioHardwareUnknownPropertyError;
    }
}

OSStatus STDMETHODCALLTYPE getPropertyData(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    if (inAddress == nullptr || outDataSize == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    if (outData == nullptr) {
        UInt32 size = objectPropertyDataSize(inObjectID, inAddress);
        if (size == 0 && isPlugInObject(inObjectID)) {
            size = plugInPropertyDataSize(inAddress);
        }
        if (size == 0 && isDeviceObject(inObjectID)) {
            size = devicePropertyDataSize(inAddress);
        }
        if (size == 0 && isStreamObject(inObjectID)) {
            size = streamPropertyDataSize(inAddress);
        }
        if (size == 0 && hasProperty(nullptr, inObjectID, 0, inAddress)) {
            *outDataSize = 0;
            return kAudioHardwareNoError;
        }
        return kAudioHardwareIllegalOperationError;
    }

    if (hasObjectProperty(inObjectID, inAddress)) {
        return writeObjectProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }
    if (isPlugInObject(inObjectID) && hasPlugInProperty(inAddress)) {
        return writePlugInProperty(inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData);
    }
    if (isDeviceObject(inObjectID) && hasDeviceProperty(inAddress)) {
        return writeDeviceProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }
    if (isStreamObject(inObjectID) && hasStreamProperty(inAddress)) {
        return writeStreamProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }

    return kAudioHardwareUnknownPropertyError;
}

OSStatus STDMETHODCALLTYPE setPropertyData(AudioServerPlugInDriverRef, AudioObjectID inObjectID, pid_t, const AudioObjectPropertyAddress *inAddress, UInt32, const void *, UInt32 inDataSize, const void *inData)
{
    if (inAddress == nullptr || inData == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    if (isDeviceObject(inObjectID) && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gSampleRate.store(*reinterpret_cast<const Float64 *>(inData));
        return kAudioHardwareNoError;
    }

    if (isDeviceObject(inObjectID) && inAddress->mSelector == kAudioDevicePropertyBufferFrameSize) {
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gBufferFrameSize.store(*reinterpret_cast<const UInt32 *>(inData));
        return kAudioHardwareNoError;
    }

    if (isDeviceObject(inObjectID) && inAddress->mSelector == kAudioDevicePropertyIOProcStreamUsage) {
        const UInt32 minimumSize = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + sizeof(UInt32);
        if (inDataSize < minimumSize) {
            return kAudioHardwareBadPropertySizeError;
        }
        return kAudioHardwareNoError;
    }

    if (isStreamObject(inObjectID) &&
        (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        const auto *format = reinterpret_cast<const AudioStreamBasicDescription *>(inData);
        gSampleRate.store(format->mSampleRate);
        return kAudioHardwareNoError;
    }

    return kAudioHardwareUnsupportedOperationError;
}

OSStatus STDMETHODCALLTYPE startIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32)
{
    const UInt64 previousClients = gRunningClientCount.fetch_add(1);
    if (previousClients == 0) {
        gStartHostTime = mach_absolute_time();
        gNumberTimeStamps.store(0);
        gIsRunning.store(true);
    }
    gStartCount.fetch_add(1);
    updateSharedDiagnostics();
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE stopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32)
{
    UInt64 clients = gRunningClientCount.load();
    while (clients > 0 && !gRunningClientCount.compare_exchange_weak(clients, clients - 1)) {
    }
    if (clients <= 1) {
        gIsRunning.store(false);
    }
    gStopCount.fetch_add(1);
    updateSharedDiagnostics();
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE getZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed)
{
    if (outSampleTime == nullptr || outHostTime == nullptr || outSeed == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    const UInt64 now = mach_absolute_time();
    if (gStartHostTime == 0) {
        gStartHostTime = now;
    }

    const Float64 ticksPerFrame = hostTicksPerFrame();
    const Float64 ticksPerPeriod = ticksPerFrame * static_cast<Float64>(kDefaultZeroTimeStampPeriod);
    UInt64 timestampNumber = gNumberTimeStamps.load();
    UInt64 nextTimestampHostTime = gStartHostTime + static_cast<UInt64>((static_cast<Float64>(timestampNumber + 1) * ticksPerPeriod));

    while (nextTimestampHostTime <= now) {
        timestampNumber += 1;
        gNumberTimeStamps.store(timestampNumber);
        nextTimestampHostTime = gStartHostTime + static_cast<UInt64>((static_cast<Float64>(timestampNumber + 1) * ticksPerPeriod));
    }

    *outSampleTime = static_cast<Float64>(timestampNumber * UInt64(kDefaultZeroTimeStampPeriod));
    *outHostTime = gStartHostTime + static_cast<UInt64>(static_cast<Float64>(timestampNumber) * ticksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE willDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace)
{
    if (outWillDo == nullptr || outWillDoInPlace == nullptr) {
        return kAudioHardwareIllegalOperationError;
    }

    if (inOperationID == kAudioServerPlugInIOOperationMixOutput) {
        gWillMixOutputCount.fetch_add(1);
    }
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        gWillWriteMixCount.fetch_add(1);
    }
    if (inOperationID == kAudioServerPlugInIOOperationThread) {
        gWillThreadCount.fetch_add(1);
    }
    if (inOperationID == kAudioServerPlugInIOOperationCycle) {
        gWillCycleCount.fetch_add(1);
    }

    *outWillDo = inOperationID == kAudioServerPlugInIOOperationWriteMix ||
        inOperationID == kAudioServerPlugInIOOperationReadInput;
    *outWillDoInPlace = *outWillDo;
    updateSharedDiagnostics();
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE beginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32 inOperationID, const AudioServerPlugInIOCycleInfo *)
{
    gLastBeginOperation.store(inOperationID);
    if (inOperationID == kAudioServerPlugInIOOperationThread) {
        gBeginThreadCount.fetch_add(1);
    } else if (inOperationID == kAudioServerPlugInIOOperationCycle) {
        gBeginCycleCount.fetch_add(1);
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        gBeginWriteMixCount.fetch_add(1);
    }
    updateSharedDiagnostics();
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE doIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *, void *ioMainBuffer, void *)
{
    gLastOperation.store(inOperationID);
    if (inOperationID == kAudioServerPlugInIOOperationMixOutput) {
        gDoMixOutputCount.fetch_add(1);
        updateInputDiagnostics(ioMainBuffer, inIOBufferFrameSize);
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        gDoWriteMixCount.fetch_add(1);
        updateInputDiagnostics(ioMainBuffer, inIOBufferFrameSize);
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        readSharedMicrophoneAudio(ioMainBuffer, inIOBufferFrameSize);
    } else {
        updateSharedDiagnostics();
    }
    return kAudioHardwareNoError;
}

OSStatus STDMETHODCALLTYPE endIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32 inOperationID, const AudioServerPlugInIOCycleInfo *)
{
    gLastEndOperation.store(inOperationID);
    if (inOperationID == kAudioServerPlugInIOOperationThread) {
        gEndThreadCount.fetch_add(1);
    } else if (inOperationID == kAudioServerPlugInIOOperationCycle) {
        gEndCycleCount.fetch_add(1);
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        gEndWriteMixCount.fetch_add(1);
    }
    updateSharedDiagnostics();
    return kAudioHardwareNoError;
}

AudioServerPlugInDriverInterface gDriverInterface = {
    nullptr,
    queryInterface,
    addRef,
    release,
    initialize,
    createDevice,
    destroyDevice,
    addDeviceClient,
    removeDeviceClient,
    performDeviceConfigurationChange,
    abortDeviceConfigurationChange,
    hasProperty,
    isPropertySettable,
    getPropertyDataSize,
    getPropertyData,
    setPropertyData,
    startIO,
    stopIO,
    getZeroTimeStamp,
    willDoIOOperation,
    beginIOOperation,
    doIOOperation,
    endIOOperation
};

} // namespace

extern "C" __attribute__((visibility("default"))) void *XavucontrolVirtualCableFactory(CFAllocatorRef, CFUUIDRef inTypeUUID)
{
    if (CFEqual(inTypeUUID, kAudioServerPlugInTypeUUID)) {
        addRef(nullptr);
        return &gDriverInterfacePtr;
    }
    return nullptr;
}
