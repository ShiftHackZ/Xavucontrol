/**
 * @file IOCallbacks.inc.cpp
 * @brief Real-time IO lifecycle callbacks and the exported AudioServerPlugIn interface table.
 */

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
