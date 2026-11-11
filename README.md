# WiFiBridge 0.1.0

Initial rootless diagnostic package for iPhone 6s (iPhone8,1), iOS 15.8.4, Dopamine.

## Current scope

This first build is deliberately read-only. It reports:

- the primary interface and default router exposed by SystemConfiguration;
- available network interface names and IPv4/IPv6 addresses;
- basic interface flags.

It does **not** create an access point, bridge Wi-Fi, enable IP forwarding/NAT, alter routes, or change TTL. Those features must not be added until the iOS networking path and Wi-Fi concurrency behavior are established.

The report does not print SSIDs, passwords, MAC addresses, or packet contents.

## Build

The GitHub Actions workflow builds a rootless `.deb` with Theos.

## Install and run

Install the resulting `.deb` in Sileo. In NewTerm, run:

```sh
wifibridge-diag
```

This is one diagnostic command; it does not modify network configuration.

## Target

- iOS 15.0+
- Rootless jailbreak
- ARM64
