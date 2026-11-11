#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <sys/socket.h>
#import <netdb.h>
#import <stdio.h>
#import <string.h>

static NSString *StringFromCF(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return nil;
    }
    return (__bridge NSString *)value;
}

static NSString *FlagsDescription(unsigned int flags) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (flags & IFF_UP) [parts addObject:@"UP"];
    if (flags & IFF_RUNNING) [parts addObject:@"RUNNING"];
    if (flags & IFF_LOOPBACK) [parts addObject:@"LOOPBACK"];
    if (flags & IFF_POINTOPOINT) [parts addObject:@"POINTOPOINT"];
    if (flags & IFF_BROADCAST) [parts addObject:@"BROADCAST"];
    return parts.count ? [parts componentsJoinedByString:@","] : @"none";
}

static void PrintPrimaryNetwork(void) {
    SCDynamicStoreRef store = SCDynamicStoreCreate(
        kCFAllocatorDefault,
        CFSTR("WiFiBridge-Diagnostics"),
        NULL,
        NULL
    );

    if (!store) {
        printf("Primary network: unavailable (SystemConfiguration store)\n");
        return;
    }

    CFDictionaryRef state = SCDynamicStoreCopyValue(
        store,
        CFSTR("State:/Network/Global/IPv4")
    );

    if (state && CFGetTypeID(state) == CFDictionaryGetTypeID()) {
        NSString *primary = StringFromCF(CFDictionaryGetValue(state, CFSTR("PrimaryInterface")));
        NSString *router = StringFromCF(CFDictionaryGetValue(state, CFSTR("Router")));

        printf("Primary interface: %s\n", primary ? primary.UTF8String : "unknown");
        printf("Default router:    %s\n", router ? router.UTF8String : "unknown");
    } else {
        printf("Primary network: not reported by SystemConfiguration\n");
    }

    if (state) CFRelease(state);
    CFRelease(store);
}

static void PrintInterfaces(void) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0 || !interfaces) {
        printf("\nInterfaces: getifaddrs failed\n");
        return;
    }

    printf("\nInterfaces and addresses:\n");
    NSMutableSet<NSString *> *printed = [NSMutableSet set];

    for (struct ifaddrs *entry = interfaces; entry; entry = entry->ifa_next) {
        if (!entry->ifa_name) continue;

        NSString *name = [NSString stringWithUTF8String:entry->ifa_name];
        if (!name) continue;

        if (![printed containsObject:name]) {
            [printed addObject:name];
            printf("  %s  [%s]\n",
                   name.UTF8String,
                   FlagsDescription(entry->ifa_flags).UTF8String);
        }

        if (!entry->ifa_addr) continue;

        int family = entry->ifa_addr->sa_family;
        char address[NI_MAXHOST] = {0};
        socklen_t length = 0;

        if (family == AF_INET) {
            length = sizeof(struct sockaddr_in);
        } else if (family == AF_INET6) {
            length = sizeof(struct sockaddr_in6);
        } else {
            continue;
        }

        int result = getnameinfo(
            entry->ifa_addr,
            length,
            address,
            sizeof(address),
            NULL,
            0,
            NI_NUMERICHOST
        );

        if (result == 0) {
            printf("      %s: %s\n",
                   family == AF_INET ? "IPv4" : "IPv6",
                   address);
        }
    }

    freeifaddrs(interfaces);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        printf("WiFiBridge Diagnostics 0.1.0\n");
        printf("Read-only report; no network settings are changed.\n\n");

        PrintPrimaryNetwork();
        PrintInterfaces();

        printf("\nNo SSIDs, passwords, MAC addresses, or packet contents are collected.\n");
        printf("This build does not enable hotspot, NAT, forwarding, or TTL changes.\n");
    }
    return 0;
}
