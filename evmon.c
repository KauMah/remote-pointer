// evmon: listen to the HID *event system* (post-driver events, not raw reports) for the Siri Remote's services,
// after asking its sensor service to report. Motion parsed by AppleEmbeddedBluetoothSensors' plugin would
// show up here as Gyro/Accelerometer/VendorDefined events.
// Build: clang -O2 evmon.c -o evmon -framework IOKit -framework CoreFoundation
// Run:   ./evmon [seconds=30] [client type: 1=monitor 0=admin 2=passive 4=simple]
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon, void *sender, IOHIDEventRef event);

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef, int type, CFDictionaryRef);
extern void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef, CFRunLoopRef, CFStringRef);
extern void IOHIDEventSystemClientRegisterEventCallback(IOHIDEventSystemClientRef, IOHIDEventSystemClientEventCallback, void *, void *);
extern void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern Boolean IOHIDServiceClientSetProperty(IOHIDServiceClientRef, CFStringRef, CFTypeRef);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern CFTypeRef IOHIDServiceClientGetRegistryID(IOHIDServiceClientRef);
extern uint32_t IOHIDEventGetType(IOHIDEventRef);
extern uint64_t IOHIDEventGetSenderID(IOHIDEventRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, uint32_t field);
extern CFIndex IOHIDEventGetIntegerValue(IOHIDEventRef, uint32_t field);
extern uint8_t *IOHIDEventGetDataValue(IOHIDEventRef, uint32_t field);
extern CFArrayRef IOHIDEventGetChildren(IOHIDEventRef);

static CFAbsoluteTime t0;
static long counts[64];

static const char *tname(uint32_t t) {
    static const char *n[] = {"Null","VendorDefined","Button","Keyboard","Translation","Rotation","Scroll","Scale","Zoom",
        "Velocity","Orientation","Digitizer","ALS","Accelerometer","Proximity","Temperature","NavSwipe","Pointer","Progress",
        "MultiAxisPointer","Gyro","Compass","ZoomToggle","DockSwipe","SymHotKey","Power","LED","FluidTouch","BoundaryScroll",
        "Biometric","Unicode","Pressure","Force","MotionActivity","MotionGesture","GameController","Humidity","Collection","Brightness"};
    return t < sizeof n / sizeof *n ? n[t] : "?";
}

static void dump(IOHIDEventRef e, int depth) {
    uint32_t t = IOHIDEventGetType(e);
    if (t < 64) counts[t]++;
    uint32_t b = t << 16;
    printf("%8.3f %*s%-14s sender 0x%llx", CFAbsoluteTimeGetCurrent() - t0, depth * 2, "", tname(t),
           (unsigned long long)IOHIDEventGetSenderID(e));
    if (t == 1) { // vendor defined: usagePage, usage, version, length, data
        CFIndex up = IOHIDEventGetIntegerValue(e, b | 0), u = IOHIDEventGetIntegerValue(e, b | 1);
        CFIndex len = IOHIDEventGetIntegerValue(e, b | 3);
        uint8_t *d = IOHIDEventGetDataValue(e, b | 4);
        printf(" page 0x%lx usage 0x%lx len %ld:", (long)up, (long)u, (long)len);
        for (CFIndex i = 0; d && i < len && i < 48; i++) printf(" %02X", d[i]);
    } else {
        printf(" f0..3 % .4f % .4f % .4f % .4f", IOHIDEventGetFloatValue(e, b | 0), IOHIDEventGetFloatValue(e, b | 1),
               IOHIDEventGetFloatValue(e, b | 2), IOHIDEventGetFloatValue(e, b | 3));
    }
    printf("\n");
    CFArrayRef kids = IOHIDEventGetChildren(e);
    for (CFIndex i = 0; kids && i < CFArrayGetCount(kids); i++) dump((IOHIDEventRef)CFArrayGetValueAtIndex(kids, i), depth + 1);
}

static void onEvent(void *target, void *refcon, void *sender, IOHIDEventRef e) { dump(e, 0); }

static void stop(CFRunLoopTimerRef t, void *info) { CFRunLoopStop(CFRunLoopGetMain()); }

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    double secs = argc > 1 ? atof(argv[1]) : 30;
    int type = argc > 2 ? atoi(argv[2]) : 1;
    t0 = CFAbsoluteTimeGetCurrent();

    IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, type, NULL);
    if (!c) { printf("client type %d: create failed\n", type); return 1; }
    int pid = 0x266;
    CFNumberRef pidNum = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    const void *k[] = {CFSTR("ProductID")}, *v[] = {pidNum};
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(c, match);

    CFArrayRef services = IOHIDEventSystemClientCopyServices(c);
    CFIndex n = services ? CFArrayGetCount(services) : 0;
    printf("client type %d: %ld remote service(s)\n", type, (long)n);
    int interval = 10000; // µs
    CFNumberRef iv = CFNumberCreate(NULL, kCFNumberIntType, &interval);
    for (CFIndex i = 0; i < n; i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef cls = IOHIDServiceClientCopyProperty(s, CFSTR("IOClass"));
        char buf[128] = "?";
        if (cls && CFGetTypeID(cls) == CFStringGetTypeID()) CFStringGetCString(cls, buf, sizeof buf, kCFStringEncodingUTF8);
        Boolean ok = IOHIDServiceClientSetProperty(s, CFSTR("ReportInterval"), iv);
        printf("  service %s: set ReportInterval → %d\n", buf, ok);
    }

    IOHIDEventSystemClientRegisterEventCallback(c, onEvent, NULL, NULL);
    IOHIDEventSystemClientScheduleWithRunLoop(c, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + secs, 0, 0, 0, stop, NULL);
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopDefaultMode);
    printf("Listening %.0fs: move/tilt the remote, touch it, press a button.\n", secs);
    CFRunLoopRun();
    printf("summary:");
    for (int t = 0; t < 64; t++) if (counts[t]) printf(" %s=%ld", tname(t), counts[t]);
    printf("\n");
    return 0;
}
