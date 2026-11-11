// mtprobe: read touch frames from every multitouch device (built-in trackpad, Magic Trackpad,
// and — per open-appleremote — the 1st-gen Siri Remote) via the private MultitouchSupport framework.
// Build: clang -O2 mtprobe.c -o mtprobe -framework CoreFoundation
// Run:   ./mtprobe            Ctrl-C to quit.
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdbool.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTVector;
typedef struct {
    int frame;
    double timestamp;
    int identifier, state, unknown1, unknown2;
    MTVector normalized;   // 0..1, origin bottom-left
    float size;
    int zero1;
    float angle, majorAxis, minorAxis;
    MTVector mm;
    int zero2[2];
    float unknown3;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTTouch *, int, double, int);

static CFArrayRef (*MTDeviceCreateList)(void);
static void (*MTRegisterContactFrameCallback)(MTDeviceRef, MTContactCallback);
static void (*MTDeviceStart)(MTDeviceRef, int);
static bool (*MTDeviceIsBuiltIn)(MTDeviceRef);
static int (*MTDeviceGetFamilyID)(MTDeviceRef, int *);

static CFArrayRef devices;

static int indexOf(MTDeviceRef d) {
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++)
        if (CFArrayGetValueAtIndex(devices, i) == d) return (int)i;
    return -1;
}

static int onFrame(MTDeviceRef dev, MTTouch *t, int n, double ts, int frame) {
    printf("%10.3f dev %d frame %d touches %d", ts, indexOf(dev), frame, n);
    for (int i = 0; i < n; i++)
        printf(" | id %d state %d pos %.3f,%.3f vel %.2f,%.2f size %.2f",
               t[i].identifier, t[i].state, t[i].normalized.pos.x, t[i].normalized.pos.y,
               t[i].normalized.vel.x, t[i].normalized.vel.y, t[i].size);
    printf("\n");
    return 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 1; }
    MTDeviceCreateList = dlsym(h, "MTDeviceCreateList");
    MTRegisterContactFrameCallback = dlsym(h, "MTRegisterContactFrameCallback");
    MTDeviceStart = dlsym(h, "MTDeviceStart");
    MTDeviceIsBuiltIn = dlsym(h, "MTDeviceIsBuiltIn");
    MTDeviceGetFamilyID = dlsym(h, "MTDeviceGetFamilyID");
    if (!MTDeviceCreateList || !MTRegisterContactFrameCallback || !MTDeviceStart) {
        fprintf(stderr, "missing MultitouchSupport symbols\n"); return 1;
    }

    devices = MTDeviceCreateList();
    CFIndex count = devices ? CFArrayGetCount(devices) : 0;
    printf("%ld multitouch device(s)\n", (long)count);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        int family = -1;
        if (MTDeviceGetFamilyID) MTDeviceGetFamilyID(d, &family);
        printf("dev %ld: family %d builtin %d\n", (long)i, family, MTDeviceIsBuiltIn ? MTDeviceIsBuiltIn(d) : -1);
        MTRegisterContactFrameCallback(d, onFrame);
        MTDeviceStart(d, 0);
    }
    printf("Listening. Touch the remote's surface (and your trackpad once, to tell them apart). Ctrl-C to quit.\n");
    CFRunLoopRun();
    return 0;
}
