
#import <Foundation/Foundation.h>

#include <ifaddrs.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static NSString *InterfaceFlags(unsigned int flags) {
    NSMutableArray *items = [NSMutableArray array];

    if (flags & IFF_UP) [items addObject:@"UP"];
    if (flags & IFF_RUNNING) [items addObject:@"RUNNING"];
    if (flags & IFF_LOOPBACK) [items addObject:@"LOOPBACK"];
    if (flags & IFF_BROADCAST) [items addObject:@"BROADCAST"];
    if (flags & IFF_POINTOPOINT) [items addObject:@"POINTOPOINT"];
    if (flags & IFF_MULTICAST) [items addObject:@"MULTICAST"];

    return items.count ? [items componentsJoinedByString:@" "] : @"NONE";
}

static void PrintInterfaces(void) {
    struct ifaddrs *interfaces = NULL;

    if (getifaddrs(&interfaces) != 0) {
        fprintf(stderr, "WiFiBridge: getifaddrs failed: %s\n", strerror(errno));
        return;
    }

    NSMutableSet *printed = [NSMutableSet set];

    printf("=== WiFiBridge Diagnostics ===\n\n");

    for (struct ifaddrs *current = interfaces;
         current != NULL;
         current = current->ifa_next) {

        if (!current->ifa_name) {
            continue;
        }

        NSString *name = [NSString stringWithUTF8String:current->ifa_name];
        if (!name) {
            continue;
        }

        if (![printed containsObject:name]) {
            [printed addObject:name];

            printf("[%s]\n", current->ifa_name);
            printf("  Flags: %s\n",
                   [InterfaceFlags(current->ifa_flags) UTF8String]);
        }

        if (!current->ifa_addr) {
            continue;
        }

        int family = current->ifa_addr->sa_family;
        char addressBuffer[INET6_ADDRSTRLEN] = {0};

        if (family == AF_INET) {
            struct sockaddr_in *address =
                (struct sockaddr_in *)current->ifa_addr;

            if (inet_ntop(AF_INET,
                          &address->sin_addr,
                          addressBuffer,
                          sizeof(addressBuffer))) {
                printf("  IPv4: %s\n", addressBuffer);
            }
        } else if (family == AF_INET6) {
            struct sockaddr_in6 *address =
                (struct sockaddr_in6 *)current->ifa_addr;

            if (inet_ntop(AF_INET6,
                          &address->sin6_addr,
                          addressBuffer,
                          sizeof(addressBuffer))) {
                printf("  IPv6: %s\n", addressBuffer);
            }
        }
    }

    freeifaddrs(interfaces);

    printf("\n=== End ===\n");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        PrintInterfaces();
    }

    return 0;
}
