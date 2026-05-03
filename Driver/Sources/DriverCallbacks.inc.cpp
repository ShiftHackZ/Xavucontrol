/**
 * @file DriverCallbacks.inc.cpp
 * @brief COM-style lifetime callbacks and generic HAL property dispatch entrypoints.
 */

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
    if (isDeviceObject(inObjectID) && hasDeviceProperty(inObjectID, inAddress)) {
        return true;
    }
    if (isStreamObject(inObjectID) && hasStreamProperty(inAddress)) {
        return true;
    }
    if (isControlObject(inObjectID) && hasControlProperty(inObjectID, inAddress)) {
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
            inAddress->mSelector == kAudioDevicePropertyIOProcStreamUsage ||
            (isOutputDeviceVolumeAddress(inObjectID, inAddress) &&
                (inAddress->mSelector == kXavucontrolPropertyVirtualMainVolume ||
                    inAddress->mSelector == kAudioDevicePropertyVolumeScalar ||
                    inAddress->mSelector == kAudioDevicePropertyVolumeDecibels ||
                    inAddress->mSelector == kAudioDevicePropertyMute));
    }
    if (isStreamObject(inObjectID)) {
        *outIsSettable = inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
            inAddress->mSelector == kAudioStreamPropertyPhysicalFormat;
    }
    if (isControlObject(inObjectID)) {
        *outIsSettable = (isOutputVolumeControlObject(inObjectID) &&
                (inAddress->mSelector == kAudioLevelControlPropertyScalarValue ||
                    inAddress->mSelector == kAudioLevelControlPropertyDecibelValue)) ||
            (inObjectID == kObjectIDOutputMuteControl &&
                inAddress->mSelector == kAudioBooleanControlPropertyValue);
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
        size = devicePropertyDataSize(inObjectID, inAddress);
    }
    if (size == 0 && isStreamObject(inObjectID)) {
        size = streamPropertyDataSize(inAddress);
    }
    if (size == 0 && isControlObject(inObjectID)) {
        size = controlPropertyDataSize(inObjectID, inAddress);
    }

    if (size == 0 && !hasProperty(nullptr, inObjectID, 0, inAddress)) {
        logUnknownProperty("GetPropertyDataSize", inObjectID, inAddress);
        return kAudioHardwareUnknownPropertyError;
    }

    *outDataSize = size;
    return kAudioHardwareNoError;
}

