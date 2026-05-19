#include <IOKit/IOLib.h>
#include <IOKit/IOService.h>
#include <libkern/c++/OSData.h>
#include <mach/kmod.h>

extern "C" kern_return_t CodexRegionSpoof_start(kmod_info_t *ki, void *d);
extern "C" kern_return_t CodexRegionSpoof_stop(kmod_info_t *ki, void *d);

KMOD_EXPLICIT_DECL(local_codex_RegionSpoof, "1.0.0", CodexRegionSpoof_start, CodexRegionSpoof_stop)
extern "C" kmod_start_func_t *_realmain = CodexRegionSpoof_start;
extern "C" kmod_stop_func_t *_antimain = CodexRegionSpoof_stop;
extern "C" int _kext_apple_cc = __APPLE_CC__;

kern_return_t CodexRegionSpoof_start(kmod_info_t *, void *) {
    mach_timespec_t timeout = {5, 0};
    IOService *platform = IOService::waitForService(IOService::serviceMatching("IOPlatformExpertDevice"), &timeout);
    if (!platform) {
        IOLog("CodexRegionSpoof: IOPlatformExpertDevice not found\n");
        return KERN_FAILURE;
    }

    unsigned char bytes[32] = {0};
    bytes[0] = 'L'; bytes[1] = 'L'; bytes[2] = '/'; bytes[3] = 'A';
    OSData *data = OSData::withBytes(bytes, sizeof(bytes));
    if (!data) {
        IOLog("CodexRegionSpoof: OSData allocation failed\n");
        return KERN_RESOURCE_SHORTAGE;
    }
    bool regionOK = platform->setProperty("region-info", data);
    data->release();

    unsigned char countryBytes[3] = {'U', 'S', 'A'};
    OSData *country = OSData::withBytes(countryBytes, sizeof(countryBytes));
    if (!country) {
        IOLog("CodexRegionSpoof: country-of-origin OSData allocation failed\n");
        return KERN_RESOURCE_SHORTAGE;
    }
    bool countryOK = platform->setProperty("country-of-origin", country);
    country->release();

    IOLog("CodexRegionSpoof: set region-info LL/A ok=%d, country-of-origin USA ok=%d\n",
          regionOK ? 1 : 0, countryOK ? 1 : 0);
    return (regionOK && countryOK) ? KERN_SUCCESS : KERN_FAILURE;
}

kern_return_t CodexRegionSpoof_stop(kmod_info_t *, void *) {
    IOLog("CodexRegionSpoof: stop\n");
    return KERN_SUCCESS;
}
