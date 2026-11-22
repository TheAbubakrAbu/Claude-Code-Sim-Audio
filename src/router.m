#import "router.h"
#import <dlfcn.h>

// The private CoreSimulator calls used here, declared so they can be sent directly.
@interface NSObject (ClaudeSimAudioPrivate)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)developerDir error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSDictionary *)devicesByUDID;
- (unsigned long long)state;
- (id)io;
- (NSArray *)ioPorts;
- (id)descriptor;
- (NSString *)guestOutputHostDeviceUID;
- (void)routeGuestDeviceScope:(unsigned long long)scope
              toHostDeviceUID:(NSString *)uid
              completionQueue:(dispatch_queue_t)queue
            completionHandler:(void (^)(void))handler;
@end

static const unsigned long long kOutputScope = 2;  // SimAudioDeviceScope: 1 input, 2 output
static const unsigned long long kBooting = 2;      // SimDeviceState: 2 booting
static const unsigned long long kBooted = 3;       // SimDeviceState: 3 booted

static id gDeviceSet;
static NSMutableDictionary<NSString *, id> *gPorts;     // UDID -> route port descriptor
static NSMutableDictionary<NSString *, id> *gIOClients; // keeps each port's IO client alive

static BOOL Load(void) {
    static BOOL loaded;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        loaded = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW) != NULL;
        gPorts = [NSMutableDictionary dictionary];
        gIOClients = [NSMutableDictionary dictionary];
    });
    return loaded;
}

static void Reset(void) {
    gDeviceSet = nil;
    [gPorts removeAllObjects];
    [gIOClients removeAllObjects];
}

NSDictionary<NSString *, NSNumber *> *SimAudioLiveDevices(NSString *developerDir) {
    if (!Load()) return nil;
    @try {
        if (!gDeviceSet) {
            Class contextClass = NSClassFromString(@"SimServiceContext");
            if (!contextClass) return nil;
            NSError *error = nil;
            id context = [contextClass sharedServiceContextForDeveloperDir:developerDir error:&error];
            gDeviceSet = [context defaultDeviceSetWithError:&error];
            if (!gDeviceSet) return nil;
        }
        NSMutableDictionary<NSString *, NSNumber *> *live = [NSMutableDictionary dictionary];
        [[gDeviceSet devicesByUDID] enumerateKeysAndObjectsUsingBlock:^(NSUUID *uuid, id device, BOOL *stop) {
            unsigned long long state = [device state];
            if (state == kBooted || state == kBooting) live[uuid.UUIDString.uppercaseString] = @(state);
        }];
        return live;
    } @catch (NSException *exception) {
        Reset();
        return nil;
    }
}

static id Port(NSString *udid) {
    id port = gPorts[udid];
    if (port) return port;
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:udid];
    id device = uuid ? [gDeviceSet devicesByUDID][uuid] : nil;
    if (!device) return nil;
    Protocol *routable = NSProtocolFromString(@"SimAudioHostRoutable");
    if (!routable) return nil;
    id io = [device io];
    for (id candidate in [io ioPorts]) {
        id descriptor = [candidate descriptor];
        if ([descriptor conformsToProtocol:routable]) {
            gPorts[udid] = descriptor;
            gIOClients[udid] = io;
            return descriptor;
        }
    }
    return nil;
}

NSString *SimAudioOutputRoute(NSString *udid) {
    if (!Load() || !gDeviceSet) return nil;
    @try {
        return [Port(udid) guestOutputHostDeviceUID];
    } @catch (NSException *exception) {
        SimAudioForget(udid);
        return nil;
    }
}

BOOL SimAudioSetOutputRoute(NSString *udid, NSString *hostDeviceUID) {
    if (!Load() || !gDeviceSet) return NO;
    @try {
        id port = Port(udid);
        if (!port) return NO;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        dispatch_queue_t queue = dispatch_queue_create("local.claude.sim-audio.route", DISPATCH_QUEUE_SERIAL);
        [port routeGuestDeviceScope:kOutputScope toHostDeviceUID:hostDeviceUID completionQueue:queue completionHandler:^{
            dispatch_semaphore_signal(done);
        }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))) != 0) return NO;
        return [[port guestOutputHostDeviceUID] isEqualToString:hostDeviceUID];
    } @catch (NSException *exception) {
        SimAudioForget(udid);
        return NO;
    }
}

void SimAudioForget(NSString *udid) {
    [gPorts removeObjectForKey:udid];
    [gIOClients removeObjectForKey:udid];
}
