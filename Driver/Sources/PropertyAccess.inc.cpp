/**
 * @file PropertyAccess.inc.cpp
 * @brief Read/write implementations for plugin, device, stream, and control properties.
 *
 * This section serializes Core Audio property values, applies settable driver state,
 * and notifies the host when user-visible volume or mute controls change.
 */

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
        if (isOutputVolumeControlObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioVolumeControlClassID));
        }
        if (inObjectID == kObjectIDOutputMuteControl) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioMuteControlClassID));
        }
        break;
    case kAudioObjectPropertyBaseClass:
        if (isPlugInObject(inObjectID) || isDeviceObject(inObjectID) || isStreamObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioObjectClassID));
        }
        if (isOutputVolumeControlObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioLevelControlClassID));
        }
        if (inObjectID == kObjectIDOutputMuteControl) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioBooleanControlClassID));
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
        if (isControlObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, controlOwner(inObjectID));
        }
        break;
    case kAudioObjectPropertyName:
        if (inObjectID == kObjectIDOutputVolumeControl) {
            return writeString(inDataSize, outDataSize, outData, CFSTR("Master Volume"));
        }
        if (inObjectID == kObjectIDOutputMuteControl) {
            return writeString(inDataSize, outDataSize, outData, CFSTR("Mute"));
        }
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
            if (inDataSize < sizeof(AudioObjectID) * 3) {
                return kAudioHardwareBadPropertySizeError;
            }
            auto *objects = reinterpret_cast<AudioObjectID *>(outData);
            objects[0] = kObjectIDOutputStream;
            objects[1] = kObjectIDOutputVolumeControl;
            objects[2] = kObjectIDOutputMuteControl;
            *outDataSize = sizeof(AudioObjectID) * 3;
            return kAudioHardwareNoError;
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
    if (isOutputDeviceVolumeAddress(inObjectID, inAddress)) {
        switch (inAddress->mSelector) {
        case kXavucontrolPropertyVirtualMainVolume:
        case kAudioDevicePropertyVolumeScalar:
            return writeScalar(inDataSize, outDataSize, outData, clampedVolume(gOutputVolume.load()));
        case kAudioDevicePropertyVolumeDecibels:
            return writeScalar(inDataSize, outDataSize, outData, scalarToDecibels(gOutputVolume.load()));
        case kAudioDevicePropertyVolumeRangeDecibels: {
            AudioValueRange range {};
            range.mMinimum = kMinimumVolumeDecibels;
            range.mMaximum = kMaximumVolumeDecibels;
            return writeScalar(inDataSize, outDataSize, outData, range);
        }
        case kAudioDevicePropertyVolumeScalarToDecibels:
            if (inDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            return writeScalar(inDataSize, outDataSize, outData, scalarToDecibels(*reinterpret_cast<Float32 *>(outData)));
        case kAudioDevicePropertyVolumeDecibelsToScalar:
            if (inDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            return writeScalar(inDataSize, outDataSize, outData, decibelsToScalar(*reinterpret_cast<Float32 *>(outData)));
        case kXavucontrolPropertyVolumeDecibelsToScalarTransferFunction:
            return writeScalar(inDataSize, outDataSize, outData, UInt32(0));
        case kAudioDevicePropertyMute:
            return writeScalar(inDataSize, outDataSize, outData, UInt32(gOutputMuted.load() != 0 ? 1 : 0));
        default:
            break;
        }
    }

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
        if (isOutputDeviceObject(inObjectID)
            && (inAddress->mScope == kAudioObjectPropertyScopeOutput || inAddress->mScope == kAudioObjectPropertyScopeGlobal)) {
            if (inDataSize < sizeof(AudioObjectID) * 2) {
                return kAudioHardwareBadPropertySizeError;
            }
            auto *controls = reinterpret_cast<AudioObjectID *>(outData);
            controls[0] = kObjectIDOutputVolumeControl;
            controls[1] = kObjectIDOutputMuteControl;
            *outDataSize = sizeof(AudioObjectID) * 2;
            return kAudioHardwareNoError;
        }
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

OSStatus writeControlProperty(AudioObjectID inObjectID, const AudioObjectPropertyAddress *inAddress, UInt32 inDataSize, UInt32 *outDataSize, void *outData)
{
    switch (inAddress->mSelector) {
    case kAudioControlPropertyScope:
        return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioObjectPropertyScopeOutput));
    case kAudioControlPropertyElement:
        if (isOutputVolumeControlObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, outputVolumeControlElement(inObjectID));
        }
        return writeScalar(inDataSize, outDataSize, outData, UInt32(kAudioObjectPropertyElementMain));
    case kAudioLevelControlPropertyScalarValue:
        if (isOutputVolumeControlObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, clampedVolume(gOutputVolume.load()));
        }
        break;
    case kAudioLevelControlPropertyDecibelValue:
        if (isOutputVolumeControlObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, scalarToDecibels(gOutputVolume.load()));
        }
        break;
    case kAudioLevelControlPropertyDecibelRange: {
        if (!isOutputVolumeControlObject(inObjectID)) {
            break;
        }
        AudioValueRange range {};
        range.mMinimum = kMinimumVolumeDecibels;
        range.mMaximum = kMaximumVolumeDecibels;
        return writeScalar(inDataSize, outDataSize, outData, range);
    }
    case kAudioLevelControlPropertyConvertScalarToDecibels:
        if (isOutputVolumeControlObject(inObjectID)) {
            if (inDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            const Float32 scalar = *reinterpret_cast<Float32 *>(outData);
            return writeScalar(inDataSize, outDataSize, outData, scalarToDecibels(scalar));
        }
        break;
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        if (isOutputVolumeControlObject(inObjectID)) {
            if (inDataSize < sizeof(Float32)) {
                return kAudioHardwareBadPropertySizeError;
            }
            const Float32 decibels = *reinterpret_cast<Float32 *>(outData);
            return writeScalar(inDataSize, outDataSize, outData, decibelsToScalar(decibels));
        }
        break;
    case kXavucontrolPropertyLevelDecibelsToScalarTransferFunction:
        if (isOutputVolumeControlObject(inObjectID)) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(0));
        }
        break;
    case kAudioBooleanControlPropertyValue:
        if (inObjectID == kObjectIDOutputMuteControl) {
            return writeScalar(inDataSize, outDataSize, outData, UInt32(gOutputMuted.load() != 0 ? 1 : 0));
        }
        break;
    default:
        break;
    }

    return kAudioHardwareUnknownPropertyError;
}

void notifyPropertyChanged(AudioObjectID objectID, AudioObjectPropertySelector selector)
{
    if (gHost == nullptr) {
        return;
    }
    AudioObjectPropertyAddress address {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    gHost->PropertiesChanged(gHost, objectID, 1, &address);
}

void notifyOutputDevicePropertyChanged(AudioObjectPropertySelector selector)
{
    if (gHost == nullptr) {
        return;
    }
    AudioObjectPropertyAddress addresses[] {
        { selector, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
        { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { selector, kAudioObjectPropertyScopeWildcard, kAudioObjectPropertyElementWildcard },
        { selector, kAudioObjectPropertyScopeOutput, 1 },
        { selector, kAudioObjectPropertyScopeOutput, 2 }
    };
    gHost->PropertiesChanged(gHost, kObjectIDOutputDevice, 5, addresses);
}

void notifyOutputVolumeControlsChanged()
{
    notifyPropertyChanged(kObjectIDOutputVolumeControl, kAudioLevelControlPropertyScalarValue);
    notifyPropertyChanged(kObjectIDOutputVolumeControl, kAudioLevelControlPropertyDecibelValue);
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
            size = devicePropertyDataSize(inObjectID, inAddress);
        }
        if (size == 0 && isStreamObject(inObjectID)) {
            size = streamPropertyDataSize(inAddress);
        }
        if (size == 0 && isControlObject(inObjectID)) {
            size = controlPropertyDataSize(inObjectID, inAddress);
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
    if (isDeviceObject(inObjectID) && hasDeviceProperty(inObjectID, inAddress)) {
        return writeDeviceProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }
    if (isStreamObject(inObjectID) && hasStreamProperty(inAddress)) {
        return writeStreamProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
    }
    if (isControlObject(inObjectID) && hasControlProperty(inObjectID, inAddress)) {
        return writeControlProperty(inObjectID, inAddress, inDataSize, outDataSize, outData);
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

    if (isOutputDeviceVolumeAddress(inObjectID, inAddress) &&
        (inAddress->mSelector == kXavucontrolPropertyVirtualMainVolume ||
            inAddress->mSelector == kAudioDevicePropertyVolumeScalar)) {
        if (inDataSize != sizeof(Float32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gOutputVolume.store(clampedVolume(*reinterpret_cast<const Float32 *>(inData)));
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeScalar);
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeDecibels);
        notifyOutputDevicePropertyChanged(kXavucontrolPropertyVirtualMainVolume);
        notifyOutputVolumeControlsChanged();
        return kAudioHardwareNoError;
    }

    if (isOutputDeviceVolumeAddress(inObjectID, inAddress) && inAddress->mSelector == kAudioDevicePropertyVolumeDecibels) {
        if (inDataSize != sizeof(Float32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gOutputVolume.store(decibelsToScalar(*reinterpret_cast<const Float32 *>(inData)));
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeScalar);
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeDecibels);
        notifyOutputDevicePropertyChanged(kXavucontrolPropertyVirtualMainVolume);
        notifyOutputVolumeControlsChanged();
        return kAudioHardwareNoError;
    }

    if (isOutputDeviceVolumeAddress(inObjectID, inAddress) && inAddress->mSelector == kAudioDevicePropertyMute) {
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gOutputMuted.store(*reinterpret_cast<const UInt32 *>(inData) == 0 ? 0 : 1);
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyMute);
        notifyPropertyChanged(kObjectIDOutputMuteControl, kAudioBooleanControlPropertyValue);
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

    if (isOutputVolumeControlObject(inObjectID) && inAddress->mSelector == kAudioLevelControlPropertyScalarValue) {
        if (inDataSize != sizeof(Float32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gOutputVolume.store(clampedVolume(*reinterpret_cast<const Float32 *>(inData)));
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeScalar);
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeDecibels);
        notifyOutputDevicePropertyChanged(kXavucontrolPropertyVirtualMainVolume);
        notifyOutputVolumeControlsChanged();
        return kAudioHardwareNoError;
    }

    if (isOutputVolumeControlObject(inObjectID) && inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) {
        if (inDataSize != sizeof(Float32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gOutputVolume.store(decibelsToScalar(*reinterpret_cast<const Float32 *>(inData)));
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeScalar);
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyVolumeDecibels);
        notifyOutputDevicePropertyChanged(kXavucontrolPropertyVirtualMainVolume);
        notifyOutputVolumeControlsChanged();
        return kAudioHardwareNoError;
    }

    if (inObjectID == kObjectIDOutputMuteControl && inAddress->mSelector == kAudioBooleanControlPropertyValue) {
        if (inDataSize != sizeof(UInt32)) {
            return kAudioHardwareBadPropertySizeError;
        }
        gOutputMuted.store(*reinterpret_cast<const UInt32 *>(inData) == 0 ? 0 : 1);
        notifyOutputDevicePropertyChanged(kAudioDevicePropertyMute);
        notifyPropertyChanged(kObjectIDOutputMuteControl, kAudioBooleanControlPropertyValue);
        return kAudioHardwareNoError;
    }

    return kAudioHardwareUnsupportedOperationError;
}

