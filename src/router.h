// Simulator audio routes, through CoreSimulator's private host-route port (the same one the
// old Simulator app's I/O > Audio Output menu used). Every call catches Objective-C
// exceptions, which Swift cannot, and none of them is thread-safe: call them from one queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The simulators that are on, by UDID (uppercase): 3 for booted, 2 for still booting.
/// Nil when CoreSimulator cannot be reached.
NSDictionary<NSString *, NSNumber *> * _Nullable SimAudioLiveDevices(NSString *developerDir);

/// The simulator's output route: a host device UID, or "__sim__hostUseSystemDefaultDeviceUID".
NSString * _Nullable SimAudioOutputRoute(NSString *udid);

/// Points the simulator's audio output at a host device UID. YES once CoreSimulator reports it.
BOOL SimAudioSetOutputRoute(NSString *udid, NSString *hostDeviceUID);

/// Drops the cached connection to a simulator (it rebooted or shut down).
void SimAudioForget(NSString *udid);

NS_ASSUME_NONNULL_END
