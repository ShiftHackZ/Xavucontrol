/**
 * @file AudioBuffers.inc.cpp
 * @brief Utility helpers plus shared-memory audio and diagnostics buffer handling.
 *
 * The output side writes app playback PCM into the shared virtual-cable ring buffer.
 * The input side reads mixed virtual microphone PCM back out for Core Audio clients.
 */

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

Float32 clampedVolume(Float32 value)
{
    if (!std::isfinite(value)) {
        return 1.0f;
    }
    return std::clamp(value, Float32(0), Float32(1));
}

Float32 scalarToDecibels(Float32 scalar)
{
    const Float32 volume = clampedVolume(scalar);
    if (volume <= 0.0f) {
        return kMinimumVolumeDecibels;
    }
    return std::clamp(Float32(20.0f * std::log10(volume)), kMinimumVolumeDecibels, kMaximumVolumeDecibels);
}

Float32 decibelsToScalar(Float32 decibels)
{
    if (!std::isfinite(decibels)) {
        return 1.0f;
    }
    const Float32 clampedDecibels = std::clamp(decibels, kMinimumVolumeDecibels, kMaximumVolumeDecibels);
    if (clampedDecibels <= kMinimumVolumeDecibels) {
        return 0.0f;
    }
    return clampedVolume(Float32(std::pow(10.0f, clampedDecibels / 20.0f)));
}

void copyFloatAudioWithGain(UInt8 *destination, const UInt8 *source, size_t byteCount, Float32 gain)
{
    if (gain <= 0.0f) {
        std::memset(destination, 0, byteCount);
        return;
    }
    if (gain >= 0.99999f) {
        std::memcpy(destination, source, byteCount);
        return;
    }

    const size_t sampleCount = byteCount / sizeof(Float32);
    auto *destinationSamples = reinterpret_cast<Float32 *>(destination);
    const auto *sourceSamples = reinterpret_cast<const Float32 *>(source);
    for (size_t index = 0; index < sampleCount; ++index) {
        destinationSamples[index] = sourceSamples[index] * gain;
    }
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

    const Float32 gain = gOutputMuted.load() != 0 ? 0.0f : clampedVolume(gOutputVolume.load());
    copyFloatAudioWithGain(audioData + writeOffset, source, firstChunk, gain);
    if (firstChunk < byteCount) {
        copyFloatAudioWithGain(audioData, source + firstChunk, byteCount - firstChunk, gain);
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
