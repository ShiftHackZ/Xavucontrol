/**
 * @file DriverState.inc.cpp
 * @brief Compile-in section containing Core Audio object IDs, public device metadata,
 * shared diagnostics layout, and process-wide HAL driver state.
 *
 * This file is included by XavucontrolVirtualCable.cpp inside the driver's anonymous
 * namespace. Keeping it as an include section preserves the single translation unit
 * used by the Core Audio HAL bundle while making the source easier to navigate.
 */

constexpr AudioObjectID kObjectIDPlugIn = kAudioObjectPlugInObject;
constexpr AudioObjectID kObjectIDOutputDevice = 2;
constexpr AudioObjectID kObjectIDOutputStream = 3;
constexpr AudioObjectID kObjectIDInputDevice = 4;
constexpr AudioObjectID kObjectIDInputStream = 5;
constexpr AudioObjectID kObjectIDOutputVolumeControl = 6;
constexpr AudioObjectID kObjectIDOutputMuteControl = 7;

constexpr Float64 kDefaultSampleRate = 48000.0;
constexpr UInt32 kDefaultBufferFrameSize = 512;
constexpr UInt32 kChannelCount = 2;
constexpr UInt32 kDefaultZeroTimeStampPeriod = 16384;
constexpr UInt32 kDiagnosticsVersion = 6;
constexpr Float32 kMinimumVolumeDecibels = -96.0f;
constexpr Float32 kMaximumVolumeDecibels = 0.0f;
constexpr AudioObjectPropertySelector kXavucontrolPropertyDiagnosticsVersion = 'pvvs';
constexpr AudioObjectPropertySelector kXavucontrolPropertyCapturedFrames = 'pvfr';
constexpr AudioObjectPropertySelector kXavucontrolPropertyIOCycles = 'pvcy';
constexpr AudioObjectPropertySelector kXavucontrolPropertyLastPeak = 'pvpk';
constexpr AudioObjectPropertySelector kXavucontrolPropertyLastRMS = 'pvrm';
constexpr AudioObjectPropertySelector kXavucontrolPropertyVirtualMainVolume = 'vmvc';
constexpr AudioObjectPropertySelector kXavucontrolPropertyVolumeDecibelsToScalarTransferFunction = 'vctf';
constexpr AudioObjectPropertySelector kXavucontrolPropertyLevelDecibelsToScalarTransferFunction = 'lctf';
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
std::atomic<Float32> gOutputVolume { 1.0f };
std::atomic<UInt32> gOutputMuted { 0 };
UInt64 gStartHostTime = 0;
os_log_t gLog = os_log_create("org.moroz.xavucontrol.virtualcable", "HAL");
SharedDiagnostics *gSharedDiagnostics = nullptr;

extern AudioServerPlugInDriverInterface gDriverInterface;
AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
