# WiFiBridge 0.2.0

WiFiBridge is an experimental rootless jailbreak package for iOS 15. It provides two user-space forwarding options for devices connected to the iPhone's Personal Hotspot:

- **HTTP CONNECT proxy** on TCP `8080`. This is the most practical option for Safari and apps that respect the system HTTP proxy setting. HTTPS is tunneled with CONNECT.
- **SOCKS5 proxy** on TCP `1080`. This is useful for applications that offer manual SOCKS5 proxy configuration.

This version does **not** claim to be a transparent full-device Wi-Fi repeater. Apps that ignore proxy settings, UDP traffic, and some background services will not be forwarded. A real transparent repeater still needs a working AP interface plus packet forwarding/NAT and, on this device, may encounter an overlapping-subnet problem.

## Device assumptions

- iPhone 6s, iOS 15.8.x, Dopamine rootless, arm64.
- The Personal Hotspot/local AP is already enabled by the user's existing setup.
- The standard Apple hotspot gateway address is `172.20.10.1`.
- The iPhone itself can reach the internet over its active Wi-Fi connection.

## Build

The GitHub Actions workflow builds a rootless `.deb` package. Push the repository or run the workflow manually, then download the `WiFiBridge-0.2.0` artifact and install the `.deb` in Sileo.

## Use

1. Enable the iPhone's local Personal Hotspot/AP using the existing setup.
2. In NewTerm, run:

   ```sh
   wifibridge start
   wifibridge status
   wifibridge test
   ```

3. On a client connected to the iPhone hotspot, set its Wi-Fi HTTP proxy manually:
   - Server: `172.20.10.1`
   - Port: `8080`
   - Authentication: off

4. For an app with SOCKS5 settings, use `172.20.10.1:1080`.
5. Stop the service with `wifibridge stop`.
6. View recent logs with `wifibridge log`.

Custom bind address and ports:

```sh
wifibridge start 172.20.10.1 8080 1080
```

## Important limitations

- This is a proxy, not a transparent router. It will not carry arbitrary UDP or apps that bypass the configured proxy.
- The service binds only to the specified AP address by default, so the AP must be active before starting it.
- The default AP address is the common iOS Personal Hotspot address. If the local AP uses another address, pass that address to `start` and use it on clients.
- `wifibridge test` checks whether an HTTPS CONNECT tunnel can be opened to `example.com:443`. A PASS is a real upstream test, not merely a process check.
- The daemon logs to `/var/mobile/Library/Logs/WiFiBridge.log`.

## Planned next step

After confirming that the proxy path works on this exact iPhone, add a separate experimental PF/NAT backend. It must first resolve the `en0`/hotspot subnet overlap and must not be reported as active until client traffic is verified end-to-end.
