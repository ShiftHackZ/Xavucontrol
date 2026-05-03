/**
 * @file PropertyModel.inc.cpp
 * @brief Core Audio object/property model for the virtual cable, virtual mic, streams,
 * and output volume/mute controls.
 *
 * These helpers answer which HAL properties exist and how large each property payload
 * is before the read/write callbacks serialize concrete values.
 */

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

bool isControlObject(AudioObjectID objectID)
{
    return objectID == kObjectIDOutputVolumeControl || objectID == kObjectIDOutputMuteControl;
}

bool isOutputVolumeControlObject(AudioObjectID objectID)
{
    return objectID == kObjectIDOutputVolumeControl;
}

UInt32 outputVolumeControlElement(AudioObjectID objectID)
{
    return objectID == kObjectIDOutputVolumeControl
        ? UInt32(kAudioObjectPropertyElementMain)
        : UInt32(kAudioObjectPropertyElementWildcard);
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

AudioObjectID controlOwner(AudioObjectID)
{
    return kObjectIDOutputDevice;
}

bool hasObjectProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
        return isPlugInObject(objectID) || isDeviceObject(objectID) || isStreamObject(objectID) || isControlObject(objectID);
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

bool isOutputDeviceVolumeAddress(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    if (!isOutputDeviceObject(objectID)) {
        return false;
    }
    if (address->mScope != kAudioObjectPropertyScopeOutput &&
        address->mScope != kAudioObjectPropertyScopeGlobal &&
        address->mScope != kAudioObjectPropertyScopeWildcard) {
        return false;
    }

    switch (address->mSelector) {
    case kXavucontrolPropertyVirtualMainVolume:
    case kAudioDevicePropertyVolumeScalar:
    case kAudioDevicePropertyVolumeDecibels:
    case kAudioDevicePropertyVolumeRangeDecibels:
    case kAudioDevicePropertyVolumeScalarToDecibels:
    case kAudioDevicePropertyVolumeDecibelsToScalar:
    case kXavucontrolPropertyVolumeDecibelsToScalarTransferFunction:
    case kAudioDevicePropertyMute:
        return address->mElement == kAudioObjectPropertyElementMain ||
            address->mElement == kAudioObjectPropertyElementWildcard ||
            address->mElement == 1 ||
            address->mElement == 2;
    default:
        return false;
    }
}

bool hasDeviceProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    if (isOutputDeviceVolumeAddress(objectID, address)) {
        return true;
    }

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

bool hasControlProperty(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioControlPropertyScope:
    case kAudioControlPropertyElement:
        return isControlObject(objectID);
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
    case kAudioLevelControlPropertyDecibelRange:
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
    case kXavucontrolPropertyLevelDecibelsToScalarTransferFunction:
        return isOutputVolumeControlObject(objectID);
    case kAudioBooleanControlPropertyValue:
        return objectID == kObjectIDOutputMuteControl;
    default:
        return false;
    }
}

UInt32 objectPropertyDataSize(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyOwner:
        return sizeof(UInt32);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
        return sizeof(CFStringRef);
    case kAudioObjectPropertyOwnedObjects:
        if (isPlugInObject(objectID)) {
            return sizeof(AudioObjectID) * 2;
        }
        if (isOutputDeviceObject(objectID)) {
            return sizeof(AudioObjectID) * 3;
        }
        if (isInputDeviceObject(objectID)) {
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

UInt32 devicePropertyDataSize(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    if (isOutputDeviceVolumeAddress(objectID, address)) {
        switch (address->mSelector) {
        case kXavucontrolPropertyVirtualMainVolume:
        case kAudioDevicePropertyVolumeScalar:
        case kAudioDevicePropertyVolumeDecibels:
        case kAudioDevicePropertyVolumeScalarToDecibels:
        case kAudioDevicePropertyVolumeDecibelsToScalar:
            return sizeof(Float32);
        case kAudioDevicePropertyVolumeRangeDecibels:
            return sizeof(AudioValueRange);
        case kXavucontrolPropertyVolumeDecibelsToScalarTransferFunction:
            return sizeof(UInt32);
        case kAudioDevicePropertyMute:
            return sizeof(UInt32);
        default:
            break;
        }
    }

    switch (address->mSelector) {
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
        return sizeof(CFStringRef);
    case kAudioDevicePropertyRelatedDevices:
        return sizeof(AudioObjectID) * 2;
    case kAudioObjectPropertyControlList:
        return isOutputDeviceObject(objectID)
                && (address->mScope == kAudioObjectPropertyScopeOutput || address->mScope == kAudioObjectPropertyScopeGlobal)
            ? sizeof(AudioObjectID) * 2
            : 0;
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

UInt32 controlPropertyDataSize(AudioObjectID objectID, const AudioObjectPropertyAddress *address)
{
    switch (address->mSelector) {
    case kAudioControlPropertyScope:
    case kAudioControlPropertyElement:
        return sizeof(UInt32);
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        return isOutputVolumeControlObject(objectID) ? sizeof(Float32) : 0;
    case kAudioLevelControlPropertyDecibelRange:
        return isOutputVolumeControlObject(objectID) ? sizeof(AudioValueRange) : 0;
    case kXavucontrolPropertyLevelDecibelsToScalarTransferFunction:
        return isOutputVolumeControlObject(objectID) ? sizeof(UInt32) : 0;
    case kAudioBooleanControlPropertyValue:
        return objectID == kObjectIDOutputMuteControl ? sizeof(UInt32) : 0;
    default:
        return 0;
    }
}

