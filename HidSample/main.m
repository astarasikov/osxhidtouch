#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOMessage.h>

#include <ApplicationServices/ApplicationServices.h>
#include <Foundation/Foundation.h>

#include "config.h"
#include "HidUtils.h"

//---------------------------------------------------------------------------
// Globals
//---------------------------------------------------------------------------
static IONotificationPortRef	gNotifyPort = NULL;
static io_iterator_t		gAddedIter = 0;

static NSLock *gLock = 0;

//---------------------------------------------------------------------------
// TypeDefs
//---------------------------------------------------------------------------

typedef enum {
    UP,
    DOWN,
    NO_CHANGE,
} ButtonState;

static void simulateClick(int x, int y, ButtonState button) {
    printf("CLICK %d %d %d\n", x, y, button);
    static int eventNumber = 0;
    if (button == DOWN) {
        CGEventRef move = CGEventCreateMouseEvent(NULL,
                kCGEventLeftMouseDown,
                CGPointMake(x, y),
                kCGMouseButtonLeft);
        CGEventSetIntegerValueField(move, kCGMouseEventNumber, eventNumber);
        CGEventPost(kCGHIDEventTap, move);
        CFRelease(move);
        eventNumber++;
    }
    else if (button == UP) {
        CGEventRef move_up = CGEventCreateMouseEvent(NULL,
                kCGEventLeftMouseUp,
                CGPointMake(x, y),
                kCGMouseButtonLeft);
        CGEventSetIntegerValueField(move_up, kCGMouseEventNumber, eventNumber);
        CGEventPost(kCGHIDEventTap, move_up);
        CFRelease(move_up);
        //eventNumber++;
    }
    if (button == NO_CHANGE) {
        CGEventRef move = CGEventCreateMouseEvent(NULL,
                kCGEventLeftMouseDragged,
                CGPointMake(x, y),
                kCGMouseButtonLeft);
        CGEventSetIntegerValueField(move, kCGMouseEventNumber, eventNumber);
        CGEventPost(kCGHIDEventTap, move);
        CFRelease(move);
        //eventNumber++;
    }
}

static void submitTouch(int fingerId, int x, int y, ButtonState button) {
    printf("%s: <%d, %d> state=%d\n", __func__, x, y, button);
    static int last_x[NUM_TOUCHES] = {
        0,
    };
    static int last_y[NUM_TOUCHES] = {
        0,
    };
    
    if (button == DOWN || button == UP) {
        if (last_x[fingerId] >0 && last_y[fingerId] > 0) {
            printf("last <%d %d>\n", last_x[fingerId], last_y[fingerId]);
            simulateClick(last_x[fingerId], last_y[fingerId], button);
            last_x[fingerId] = last_y[fingerId] = -1;
        }
    }
    else {
        if (x > 0) {
            last_x[fingerId] = x;
        }
        if (y > 0) {
            last_y[fingerId] = y;
        }
        if (last_x[fingerId] > 0 && last_y[fingerId] > 0) {
            simulateClick(last_x[fingerId], last_y[fingerId], NO_CHANGE);
        }
    }
}

static bool acceptHidElement(HIDElement *element) {
    printHidElement("acceptHidElement", element);
    
    switch (element->usagePage) {
        case kHIDPage_GenericDesktop:
            switch (element->usage) {
                case kHIDUsage_GD_X:
                case kHIDUsage_GD_Y:
                    return true;
            }
            break;
        case kHIDPage_Button:
            switch (element->usage) {
                case kHIDUsage_Button_1:
                    return true;
                    break;
            }
            break;
        case kHIDPage_Digitizer:
            return true;
            break;
    }
    
    return false;
}

static void reportHidElement(HIDElement *element) {
    if (!element) {
        return;
    }
    
    [gLock lock];
    
    printf("\n+++++++++++\n");
    printHidElement("report element", element);
    printf("------------\n");
    
    static int fingerId = 0;
    static ButtonState button = NO_CHANGE;
    
    //button
    if (element->type == 2) {
        button = element->currentValue ? DOWN : UP;
        submitTouch(fingerId, 0, 0, button);
    }
    else {
        button = NO_CHANGE;
    }
    
    if (element->usagePage == 0xd && element->usage == 0x22) {
        //fingerId = element->currentValue;
    }
    
    if (element->usagePage == 1 && element->currentValue < 0x10000) {
        float scale_x = SCREEN_RESX / 32768.0f;
        float scale_y = SCREEN_RESY / 32768.0f;
        
        short value = element->currentValue & 0xffff;
        
        if (element->usage == kHIDUsage_GD_X) {
            int x = (int)(value * scale_x);
            submitTouch(fingerId, x, 0, NO_CHANGE);
        }
        else if (element->usage == kHIDUsage_GD_Y) {
            int y = (int)(value * scale_y);
            submitTouch(fingerId, 0, y, NO_CHANGE);
        }
    }
    
    [gLock unlock];
}

#ifndef max
#define max(a, b) \
((a > b) ? a:b)
#endif

#ifndef min
#define min(a, b) \
((a < b) ? a:b)
#endif

//---------------------------------------------------------------------------
// Methods
//---------------------------------------------------------------------------
static void InitHIDNotifications();
static void HIDDeviceAdded(void *refCon, io_iterator_t iterator);
static void DeviceNotification(void *refCon, io_service_t service, natural_t messageType, void *messageArgument);
static bool FindHIDElements(HIDDataRef hidDataRef);
static bool SetupQueue(HIDDataRef hidDataRef);
static void QueueCallbackFunction(
                                  void * 			target,
                                  IOReturn 			result,
                                  void * 			refcon,
                                  void * 			sender);

int main (int argc, const char * argv[]) {
    // insert code here...
    
    if (argc == 1)
    {
        gLock = [[NSLock alloc] init];
        InitHIDNotifications();
        CFRunLoopRun();
    }
    
    return 0;
}


//---------------------------------------------------------------------------
// InitHIDNotifications
//
// This routine just creates our master port for IOKit and turns around
// and calls the routine that will alert us when a HID Device is plugged in.
//---------------------------------------------------------------------------

static void InitHIDNotifications()
{
    CFMutableDictionaryRef 	matchingDict;
    CFNumberRef                 refProdID;
    CFNumberRef                 refVendorID;
    SInt32                      productID = TOUCH_PID;
    SInt32                      vendorID = TOUCH_VID;
    mach_port_t 		masterPort;
    kern_return_t		kr;
    
    // first create a master_port for my task
    //
    kr = IOMasterPort(bootstrap_port, &masterPort);
    if (kr || !masterPort)
        return;
    
    // Create a notification port and add its run loop event source to our run loop
    // This is how async notifications get set up.
    //
    gNotifyPort = IONotificationPortCreate(masterPort);
    CFRunLoopAddSource(	CFRunLoopGetCurrent(),
                       IONotificationPortGetRunLoopSource(gNotifyPort),
                       kCFRunLoopDefaultMode);
    
    // Create the IOKit notifications that we need
    //
    /* Create a matching dictionary that (initially) matches all HID devices. */
    matchingDict = IOServiceMatching(kIOHIDDeviceKey);
    
    if (!matchingDict)
        return;
    
    /* Create objects for product and vendor IDs. */
    refProdID = CFNumberCreate (kCFAllocatorDefault, kCFNumberIntType, &productID);
    refVendorID = CFNumberCreate (kCFAllocatorDefault, kCFNumberIntType, &vendorID);
    
    /* Add objects to matching dictionary and clean up. */
    CFDictionarySetValue (matchingDict, CFSTR (kIOHIDVendorIDKey), refVendorID);
    CFDictionarySetValue (matchingDict, CFSTR (kIOHIDProductIDKey), refProdID);
    
    CFRelease(refProdID);
    CFRelease(refVendorID);
    
    // Now set up a notification to be called when a device is first matched by I/O Kit.
    // Note that this will not catch any devices that were already plugged in so we take
    // care of those later.
    kr = IOServiceAddMatchingNotification(gNotifyPort,			// notifyPort
                                          kIOFirstMatchNotification,	// notificationType
                                          matchingDict,			// matching
                                          HIDDeviceAdded,		// callback
                                          NULL,				// refCon
                                          &gAddedIter			// notification
                                          );
    
    if (kr != kIOReturnSuccess)
        return;
    
    HIDDeviceAdded(NULL, gAddedIter);
}

//---------------------------------------------------------------------------
// HIDDeviceAdded
//
// This routine is the callback for our IOServiceAddMatchingNotification.
// When we get called we will look at all the devices that were added and
// we will:
//
// Create some private data to relate to each device
//
// Submit an IOServiceAddInterestNotification of type kIOGeneralInterest for
// this device using the refCon field to store a pointer to our private data.
// When we get called with this interest notification, we can grab the refCon
// and access our private data.
//---------------------------------------------------------------------------

static void HIDDeviceAdded(void *refCon, io_iterator_t iterator)
{
    io_object_t 		hidDevice 		= 0;
    IOCFPlugInInterface **	plugInInterface 	= NULL;
    IOHIDDeviceInterface122 **	hidDeviceInterface 	= NULL;
    HRESULT 			result 			= S_FALSE;
    HIDDataRef                  hidDataRef              = NULL;
    IOReturn			kr;
    SInt32 			score;
    bool                        pass;
    
    /* Interate through all the devices that matched */
    while (0 != (hidDevice = IOIteratorNext(iterator)))
    {
        // Create the CF plugin for this device
        kr = IOCreatePlugInInterfaceForService(hidDevice, kIOHIDDeviceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &plugInInterface, &score);
        
        if (kr != kIOReturnSuccess)
            goto HIDDEVICEADDED_NONPLUGIN_CLEANUP;
        
        /* Obtain a device interface structure (hidDeviceInterface). */
        result = (*plugInInterface)->QueryInterface(plugInInterface, CFUUIDGetUUIDBytes(kIOHIDDeviceInterfaceID122),
                                                    (LPVOID *)&hidDeviceInterface);
        
        // Got the interface
        if ((result == S_OK) && hidDeviceInterface)
        {
            /* Create a custom object to keep data around for later. */
            hidDataRef = malloc(sizeof(HIDData));
            bzero(hidDataRef, sizeof(HIDData));
            
            hidDataRef->hidDeviceInterface = hidDeviceInterface;
            
            /* Open the device interface. */
            result = (*(hidDataRef->hidDeviceInterface))->open (hidDataRef->hidDeviceInterface, kIOHIDOptionsTypeSeizeDevice);
            
            if (result != S_OK)
                goto HIDDEVICEADDED_FAIL;
            
            /* Find the HID elements for this device and set up a receive queue. */
            pass = FindHIDElements(hidDataRef);
            pass = SetupQueue(hidDataRef);
            
            printf("Please touch screen to continue.\n\n");
            
            
            /* Register an interest in finding out anything that happens with this device (disconnection, for example) */
            IOServiceAddInterestNotification(
                                             gNotifyPort,		// notifyPort
                                             hidDevice,			// service
                                             kIOGeneralInterest,		// interestType
                                             DeviceNotification,		// callback
                                             hidDataRef,			// refCon
                                             &(hidDataRef->notification)	// notification
                                             );
            
            goto HIDDEVICEADDED_CLEANUP;
        }
        
    HIDDEVICEADDED_FAIL:
        // Failed to allocated a UPS interface.  Do some cleanup
        if (hidDeviceInterface)
        {
            (*hidDeviceInterface)->Release(hidDeviceInterface);
            hidDeviceInterface = NULL;
        }
        
        if (hidDataRef)
            free (hidDataRef);
        
    HIDDEVICEADDED_CLEANUP:
        // Clean up
        (*plugInInterface)->Release(plugInInterface);
        
    HIDDEVICEADDED_NONPLUGIN_CLEANUP:
        IOObjectRelease(hidDevice);
    }
}

//---------------------------------------------------------------------------
// DeviceNotification
//
// This routine will get called whenever any kIOGeneralInterest notification
// happens.
//---------------------------------------------------------------------------

static void DeviceNotification(void *		refCon,
                               io_service_t 	service,
                               natural_t 	messageType,
                               void *		messageArgument)
{
    kern_return_t	kr;
    HIDDataRef		hidDataRef = (HIDDataRef) refCon;
    
    /* Check to see if a device went away and clean up. */
    if ((hidDataRef != NULL) &&
        (messageType == kIOMessageServiceIsTerminated))
    {
        if (hidDataRef->hidQueueInterface != NULL)
        {
            kr = (*(hidDataRef->hidQueueInterface))->stop((hidDataRef->hidQueueInterface));
            kr = (*(hidDataRef->hidQueueInterface))->dispose((hidDataRef->hidQueueInterface));
            kr = (*(hidDataRef->hidQueueInterface))->Release (hidDataRef->hidQueueInterface);
            hidDataRef->hidQueueInterface = NULL;
        }
        
        if (hidDataRef->hidDeviceInterface != NULL)
        {
            kr = (*(hidDataRef->hidDeviceInterface))->close (hidDataRef->hidDeviceInterface);
            kr = (*(hidDataRef->hidDeviceInterface))->Release (hidDataRef->hidDeviceInterface);
            hidDataRef->hidDeviceInterface = NULL;
        }
        
        if (hidDataRef->notification)
        {
            kr = IOObjectRelease(hidDataRef->notification);
            hidDataRef->notification = 0;
        }
        
    }
}

//---------------------------------------------------------------------------
// FindHIDElements
//---------------------------------------------------------------------------
static bool FindHIDElements(HIDDataRef hidDataRef)
{
    CFArrayRef              elementArray	= NULL;
    CFMutableDictionaryRef  hidElements     = NULL;
    CFMutableDataRef        newData         = NULL;
    CFNumberRef             number		= NULL;
    CFDictionaryRef         element		= NULL;
    HIDElement              newElement;
    IOReturn                ret		= kIOReturnError;
    unsigned                i;
    
    if (!hidDataRef)
        return false;
    
    /* Create a mutable dictionary to hold HID elements. */
    hidElements = CFDictionaryCreateMutable(
                                            kCFAllocatorDefault,
                                            0,
                                            &kCFTypeDictionaryKeyCallBacks,
                                            &kCFTypeDictionaryValueCallBacks);
    if (!hidElements)
        return false;
    
    // Let's find the elements
    ret = (*hidDataRef->hidDeviceInterface)->copyMatchingElements(
                                                                  hidDataRef->hidDeviceInterface,
                                                                  NULL,
                                                                  &elementArray);
    
    
    if ((ret != kIOReturnSuccess) || !elementArray)
        goto FIND_ELEMENT_CLEANUP;
    
    //CFShow(elementArray);
    
    /* Iterate through the elements and read their values. */
    for (i=0; i<CFArrayGetCount(elementArray); i++)
    {
        element = (CFDictionaryRef) CFArrayGetValueAtIndex(elementArray, i);
        if (!element)
            continue;
        
        bzero(&newElement, sizeof(HIDElement));
        
        newElement.owner = hidDataRef;
        
        /* Read the element's usage page (top level category describing the type of
         element---kHIDPage_GenericDesktop, for example) */
        number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementUsagePageKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberSInt32Type, &newElement.usagePage);
        
        /* Read the element's usage (second level category describing the type of
         element---kHIDUsage_GD_Keyboard, for example) */
        number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementUsageKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberSInt32Type, &newElement.usage);
        
        /* Read the cookie (unique identifier) for the element */
        number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementCookieKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberIntType, &(newElement.cookie));
        
        /* Determine what type of element this is---button, Axis, etc. */
        number = (CFNumberRef)CFDictionaryGetValue(element, CFSTR(kIOHIDElementTypeKey));
        if (!number) continue;
        CFNumberGetValue(number, kCFNumberIntType, &(newElement.type));
        
        /* Pay attention to X/Y coordinates of a pointing device and
         the first mouse button.  For other elements, go on to the
         next element. */
        
        if (!acceptHidElement(&newElement)) {
            continue;
        }
        
        /* Add this element to the hidElements dictionary. */
        newData = CFDataCreateMutable(kCFAllocatorDefault, sizeof(HIDElement));
        if (!newData) continue;
        bcopy(&newElement, CFDataGetMutableBytePtr(newData), sizeof(HIDElement));
        
        number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &newElement.cookie);
        if (!number)  continue;
        CFDictionarySetValue(hidElements, number, newData);
        CFRelease(number);
        CFRelease(newData);
    }
    
FIND_ELEMENT_CLEANUP:
    if (elementArray) CFRelease(elementArray);
    
    if (CFDictionaryGetCount(hidElements) == 0)
    {
        CFRelease(hidElements);
        hidElements = NULL;
    }
    else
    {
        hidDataRef->hidElementDictionary = hidElements;
    }
    
    return hidDataRef->hidElementDictionary;
}

//---------------------------------------------------------------------------
// SetupQueue
//---------------------------------------------------------------------------
static bool SetupQueue(HIDDataRef hidDataRef)
{
    CFIndex		count 		= 0;
    CFIndex		i 		= 0;
    CFMutableDataRef *	elements	= NULL;
    CFStringRef *	keys		= NULL;
    IOReturn		ret;
    HIDElementRef	tempHIDElement	= NULL;
    bool		cookieAdded 	= false;
    bool                boolRet         = true;
    
    if (!hidDataRef->hidElementDictionary || (((count = CFDictionaryGetCount(hidDataRef->hidElementDictionary)) <= 0)))
        return false;
    
    keys 	= (CFStringRef *)malloc(sizeof(CFStringRef) * count);
    elements 	= (CFMutableDataRef *)malloc(sizeof(CFMutableDataRef) * count);
    
    CFDictionaryGetKeysAndValues(hidDataRef->hidElementDictionary, (const void **)keys, (const void **)elements);
    
    hidDataRef->hidQueueInterface = (*hidDataRef->hidDeviceInterface)->allocQueue(hidDataRef->hidDeviceInterface);
    if (!hidDataRef->hidQueueInterface)
    {
        boolRet = false;
        goto SETUP_QUEUE_CLEANUP;
    }
    
    ret = (*hidDataRef->hidQueueInterface)->create(hidDataRef->hidQueueInterface, 0, 8);
    if (ret != kIOReturnSuccess)
    {
        boolRet = false;
        goto SETUP_QUEUE_CLEANUP;
    }
    
    for (i=0; i<count; i++)
    {
        if (!elements[i] ||
            !(tempHIDElement = (HIDElementRef)CFDataGetMutableBytePtr(elements[i])))
            continue;
        
        printHidElement("SetupQueue", tempHIDElement);
        
        if ((tempHIDElement->type < kIOHIDElementTypeInput_Misc) || (tempHIDElement->type > kIOHIDElementTypeInput_ScanCodes))
            continue;
        
        ret = (*hidDataRef->hidQueueInterface)->addElement(hidDataRef->hidQueueInterface, tempHIDElement->cookie, 0);
        
        if (ret == kIOReturnSuccess)
            cookieAdded = true;
    }
    
    if (cookieAdded)
    {
        ret = (*hidDataRef->hidQueueInterface)->createAsyncEventSource(hidDataRef->hidQueueInterface, &hidDataRef->eventSource);
        if (ret != kIOReturnSuccess)
        {
            boolRet = false;
            goto SETUP_QUEUE_CLEANUP;
        }
        
        ret = (*hidDataRef->hidQueueInterface)->setEventCallout(hidDataRef->hidQueueInterface, QueueCallbackFunction, NULL, hidDataRef);
        if (ret != kIOReturnSuccess)
        {
            boolRet = false;
            goto SETUP_QUEUE_CLEANUP;
        }
        
        CFRunLoopAddSource(CFRunLoopGetCurrent(), hidDataRef->eventSource, kCFRunLoopDefaultMode);
        
        ret = (*hidDataRef->hidQueueInterface)->start(hidDataRef->hidQueueInterface);
        if (ret != kIOReturnSuccess)
        {
            boolRet = false;
            goto SETUP_QUEUE_CLEANUP;
        }
    }
    else
    {
        (*hidDataRef->hidQueueInterface)->stop(hidDataRef->hidQueueInterface);
        (*hidDataRef->hidQueueInterface)->dispose(hidDataRef->hidQueueInterface);
        (*hidDataRef->hidQueueInterface)->Release(hidDataRef->hidQueueInterface);
        hidDataRef->hidQueueInterface = NULL;
    }
    
SETUP_QUEUE_CLEANUP:
    
    free(keys);
    free(elements);
    
    return boolRet;
}


//---------------------------------------------------------------------------
// QueueCallbackFunction
//---------------------------------------------------------------------------
static void QueueCallbackFunction(
                                  void * 			target,
                                  IOReturn 			result,
                                  void * 			refcon,
                                  void * 			sender)
{
    HIDDataRef          hidDataRef      = (HIDDataRef)refcon;
    AbsoluteTime 	zeroTime 	= {0,0};
    CFNumberRef		number		= NULL;
    CFMutableDataRef	element		= NULL;
    HIDElementRef	tempHIDElement  = NULL;//(HIDElementRef)refcon;
    IOHIDEventStruct 	event;
    bool                change;
    
    if (!hidDataRef || (sender != hidDataRef->hidQueueInterface))
        return;
    
    while (result == kIOReturnSuccess)
    {
        result = (*hidDataRef->hidQueueInterface)->getNextEvent(
                                                                hidDataRef->hidQueueInterface,
                                                                &event,
                                                                zeroTime,
                                                                0);
        
        if (result != kIOReturnSuccess)
            continue;
        
        // Only intersted in 32 values right now
        if ((event.longValueSize != 0) && (event.longValue != NULL))
        {
            free(event.longValue);
            continue;
        }
        
        number = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &event.elementCookie);
        if (!number)  continue;
        element = (CFMutableDataRef)CFDictionaryGetValue(hidDataRef->hidElementDictionary, number);
        CFRelease(number);
        
        if (!element ||
            !(tempHIDElement = (HIDElement *)CFDataGetMutableBytePtr(element)))
            continue;
        
        change = (tempHIDElement->currentValue != event.value);
        tempHIDElement->currentValue = event.value;
        
        reportHidElement(tempHIDElement);
    }
    
}
