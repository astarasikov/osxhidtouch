//
//  HidUtils.h
//  HidSample
//
//  Created by Alexander Tarasikov on 23.11.13.
//  Copyright (c) 2013 Alexander Tarasikov. All rights reserved.
//

#ifndef HidSample_HidUtils_h
#define HidSample_HidUtils_h

#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDUsageTables.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <IOKit/hidsystem/IOHIDParameter.h>

#include "config.h"

typedef enum CalibrationState {
    kCalibrationStateInactive   = 0,
    kCalibrationStateTopLeft,
    kCalibrationStateTopRight,
    kCalibrationStateBottomRight,
    kCalibrationStateBottomLeft
} CalibrationState;

typedef struct HIDData
{
    io_object_t			notification;
    IOHIDDeviceInterface122 ** 	hidDeviceInterface;
    IOHIDQueueInterface **      hidQueueInterface;
    CFDictionaryRef             hidElementDictionary;
    CFRunLoopSourceRef 		eventSource;
    CalibrationState            state;
    SInt32                      minx;
    SInt32                      maxx;
    SInt32                      miny;
    SInt32                      maxy;
    UInt8                       buffer[256];
} HIDData;

typedef HIDData * 		HIDDataRef;

typedef struct HIDElement {
    SInt32		currentValue;
    SInt32		usagePage;
    SInt32		usage;
    IOHIDElementType	type;
    IOHIDElementCookie	cookie;
    HIDDataRef          owner;
}HIDElement;
typedef HIDElement * 		HIDElementRef;

static const char *translateHIDType(IOHIDElementType type) {
    switch (type) {
        case 1:
            return "MISC";
        case 2:
            return "Button";
        case 3:
            return "Axis";
        case 4:
            return "ScanCodes";
        case 129:
            return "Output";
        case 257:
            return "Feature";
        case 513:
            return "Collection";
            
        default:
            return "unknown";
            break;
    }
};

static void printHidElement(const char *fname, HIDElement *element) {
    if (!element) {
        return;
    }
    
    const char *hidType = translateHIDType(element->type);
    const char *hidUsage = "unknown";
    
#define USAGE(__page, __usage, name) do {\
    if (element->usagePage == __page && element->usage == __usage) {\
        hidUsage = name;\
        break;\
    } \
} while (0)

do {
    USAGE(0x1, 0x30, "X");
    USAGE(0x1, 0x31, "Y");
    USAGE(0xd, kHIDUsage_Dig_TouchScreen, "Touchscreen");
    USAGE(0xd, 0x1, "Digitizer");
    USAGE(0xd, 2, "Pen");
    USAGE(0xd, 0x3, "Config");
    USAGE(0xd, 0x20, "stylus");
    USAGE(0xd, 0x22, "finger");
    USAGE(0xd, 0x23, "DevSettings");
    USAGE(0xd, 0x30, "pressure");
    USAGE(0xd, 0x32, "InRange");
    USAGE(0xd, kHIDUsage_Dig_Touch, "Touch");
    USAGE(0xd, 0x3c, "Invert");
    USAGE(0xd, 0x3f, "Azimuth");
    USAGE(0xd, 0x42, "TipSwitch");
    USAGE(0xd, 0x47, "Confidence");
    USAGE(0xd, 0x48, "MT Widght");
    USAGE(0xd, 0x49, "MT Height");
    USAGE(0xd, 0x51, "ContactID");
    USAGE(0xd, 0x53, "DevIndex");
    USAGE(0xd, 0x54, "TouchCount");
    USAGE(0xd, 0x55, "Contact Count Maximum");
    USAGE(0xd, 0x56, "ScanTime");
}    while (0);
    
#undef USAGE
   
#if TOUCH_REPORT
    printf("[%s]: <%x:%x> [%s] %s=0x%x (%d)\n",
           fname ? fname : "unknown",
           element->usagePage, element->usage,
           hidType,
           hidUsage,
           element->currentValue,
           element->currentValue);
    fflush(stdout);
#endif
}

#endif
