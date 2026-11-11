#import <Foundation/Foundation.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <unistd.h>
#include <signal.h>
#include <pthread.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define DEFAULT_BIND_IP "172.20.10.1"
#define HTTP_PORT 8080
#define SOCKS_PORT 1080
#define MAX_HEADER 32768
#define PID_FILE "/var/mobile/Library/Preferences/com.wifibridge.proxy.pid"
#define LOG_FILE "/var/mobile/Library/Logs/WiFiBridge.log"

typedef enum { MODE_HTTP = 1, MODE_SOCKS = 2 } ProxyMode;
typedef struct { int fd; ProxyMode mode; int port; } ClientJob;

static volatile sig_atomic_t gRunning = 1;
static char gBindIP[64] = DEFAULT_BIND_IP;
static int gHTTPPort = HTTP_PORT;
static int gSOCKSPort = SOCKS_PORT;

static void StopSignal(int sig) { (void)sig; gRunning = 0; }

static int SendAll(int fd, const void *data, size_t length) {
    const unsigned char *p = data;
    while (length) {
        ssize_t n = send(fd, p, length, 0);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) return -1;
        p += n; length -= (size_t)n;
    }
    return 0;
}

static int ConnectHost(const char *host, const char *port) {
    struct addrinfo hints, *res = NULL, *it;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    int e = getaddrinfo(host, port, &hints, &res);
    if (e != 0) return -1;
    int out = -1;
    for (it = res; it; it = it->ai_next) {
        out = socket(it->ai_family, it->ai_socktype, it->ai_protocol);
        if (out < 0) continue;
        struct timeval tv = { .tv_sec = 15, .tv_usec = 0 };
        setsockopt(out, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(out, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
        if (connect(out, it->ai_addr, it->ai_addrlen) == 0) break;
        close(out); out = -1;
    }
    freeaddrinfo(res);
    return out;
}

static void Relay(int client, int remote, const unsigned char *initial, size_t initialLen) {
    if (initialLen) SendAll(remote, initial, initialLen);
    int clientOpen = 1, remoteOpen = 1;
    unsigned char buffer[32768];
    while (clientOpen || remoteOpen) {
        fd_set readSet;
        FD_ZERO(&readSet);
        int maxfd = -1;
        if (clientOpen) { FD_SET(client, &readSet); if (client > maxfd) maxfd = client; }
        if (remoteOpen) { FD_SET(remote, &readSet); if (remote > maxfd) maxfd = remote; }
        int ready = select(maxfd + 1, &readSet, NULL, NULL, NULL);
        if (ready < 0) { if (errno == EINTR) continue; break; }
        if (clientOpen && FD_ISSET(client, &readSet)) {
            ssize_t n = recv(client, buffer, sizeof(buffer), 0);
            if (n <= 0) { clientOpen = 0; shutdown(remote, SHUT_WR); }
            else if (SendAll(remote, buffer, (size_t)n) != 0) { clientOpen = 0; shutdown(remote, SHUT_WR); }
        }
        if (remoteOpen && FD_ISSET(remote, &readSet)) {
            ssize_t n = recv(remote, buffer, sizeof(buffer), 0);
            if (n <= 0) { remoteOpen = 0; shutdown(client, SHUT_WR); }
            else if (SendAll(client, buffer, (size_t)n) != 0) { remoteOpen = 0; shutdown(client, SHUT_WR); }
        }
    }
}

static int ReadHeader(int fd, unsigned char *buffer, size_t cap, size_t *headerEnd, size_t *total) {
    *total = 0; *headerEnd = 0;
    while (*total < cap - 1) {
        ssize_t n = recv(fd, buffer + *total, cap - 1 - *total, 0);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) return -1;
        *total += (size_t)n;
        buffer[*total] = 0;
        unsigned char *p = (unsigned char *)strstr((char *)buffer, "\r\n\r\n");
        if (p) { *headerEnd = (size_t)(p - buffer) + 4; return 0; }
    }
    return -1;
}

static int ParseHostPort(const char *authority, char *host, size_t hostCap, char *port, size_t portCap, const char *defaultPort) {
    if (!authority || !*authority) return -1;
    const char *start = authority;
    const char *end = authority + strlen(authority);
    while (end > start && (end[-1] == '\r' || end[-1] == '\n' || end[-1] == ' ')) end--;
    const char *colon = NULL;
    if (*start == '[') {
        const char *close = memchr(start, ']', (size_t)(end - start));
        if (!close) return -1;
        size_t n = (size_t)(close - start - 1);
        if (!n || n >= hostCap) return -1;
        memcpy(host, start + 1, n); host[n] = 0;
        if (close + 1 < end && close[1] == ':') colon = close + 1;
    } else {
        for (const char *p = start; p < end; p++) if (*p == ':') colon = p;
        size_t n = (size_t)((colon ? colon : end) - start);
        if (!n || n >= hostCap) return -1;
        memcpy(host, start, n); host[n] = 0;
    }
    if (colon) {
        size_t n = (size_t)(end - colon - 1);
        if (!n || n >= portCap) return -1;
        memcpy(port, colon + 1, n); port[n] = 0;
    } else snprintf(port, portCap, "%s", defaultPort);
    return 0;
}

static void HTTPClient(int fd) {
    unsigned char request[MAX_HEADER]; size_t headerEnd = 0, total = 0;
    if (ReadHeader(fd, request, sizeof(request), &headerEnd, &total) != 0) return;
    char *lineEnd = strstr((char *)request, "\r\n");
    if (!lineEnd) return;
    *lineEnd = 0;
    char method[32] = {0}, target[4096] = {0}, version[32] = {0};
    if (sscanf((char *)request, "%31s %4095s %31s", method, target, version) != 3) return;
    char host[1024] = {0}, port[16] = {0};
    int isConnect = strcasecmp(method, "CONNECT") == 0;
    if (isConnect) {
        if (ParseHostPort(target, host, sizeof(host), port, sizeof(port), "443") != 0) return;
    } else {
        const char *authority = NULL;
        const char *path = "/";
        if (strncasecmp(target, "http://", 7) == 0) {
            authority = target + 7;
            const char *slash = strpbrk(authority, "/?");
            if (slash) {
                size_t n = (size_t)(slash - authority);
                char auth[1200]; if (n >= sizeof(auth)) return;
                memcpy(auth, authority, n); auth[n] = 0;
                if (ParseHostPort(auth, host, sizeof(host), port, sizeof(port), "80") != 0) return;
                path = (*slash == '?') ? NULL : slash;
                if (!path) {
                    char tmp[4096]; snprintf(tmp, sizeof(tmp), "/%s", slash);
                    if (snprintf(target, sizeof(target), "%s", tmp) >= (int)sizeof(target)) return;
                    path = target;
                }
            } else {
                if (ParseHostPort(authority, host, sizeof(host), port, sizeof(port), "80") != 0) return;
            }
        } else {
            // Origin-form HTTP request: obtain Host from headers.
            char *headers = lineEnd + 2;
            char *h = NULL;
            if (strncasecmp(headers, "Host:", 5) == 0) h = headers;
            else h = strcasestr(headers, "\r\nHost:");
            if (!h) return;
            h += (h == headers) ? 5 : 7; while (*h == ' ' || *h == '\t') h++;
            char *he = strstr(h, "\r\n"); if (!he) return;
            char auth[1200]; size_t n = (size_t)(he - h); if (n >= sizeof(auth)) return;
            memcpy(auth, h, n); auth[n] = 0;
            if (ParseHostPort(auth, host, sizeof(host), port, sizeof(port), "80") != 0) return;
            path = target;
        }
        int remote = ConnectHost(host, port);
        if (remote < 0) { const char *e = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"; SendAll(fd, e, strlen(e)); return; }
        char first[8192];
        int firstLen = snprintf(first, sizeof(first), "%s %s %s\r\n", method, path, version);
        if (firstLen < 0 || firstLen >= (int)sizeof(first)) { close(remote); return; }
        SendAll(remote, first, (size_t)firstLen);
        SendAll(remote, lineEnd + 2, headerEnd - (size_t)(lineEnd + 2 - (char *)request));
        if (total > headerEnd) SendAll(remote, request + headerEnd, total - headerEnd);
        Relay(fd, remote, NULL, 0); close(remote); return;
    }
    int remote = ConnectHost(host, port);
    if (remote < 0) { const char *e = "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"; SendAll(fd, e, strlen(e)); return; }
    const char *ok = "HTTP/1.1 200 Connection Established\r\nProxy-Agent: WiFiBridge\r\n\r\n";
    SendAll(fd, ok, strlen(ok));
    Relay(fd, remote, request + headerEnd, total - headerEnd);
    close(remote);
}

static void SOCKSClient(int fd) {
    unsigned char greeting[260];
    ssize_t n = recv(fd, greeting, 2, MSG_WAITALL);
    if (n != 2 || greeting[0] != 5 || greeting[1] == 0) return;
    unsigned char methods[255];
    if (recv(fd, methods, greeting[1], MSG_WAITALL) != greeting[1]) return;
    int noAuth = 0; for (int i = 0; i < greeting[1]; i++) if (methods[i] == 0) noAuth = 1;
    unsigned char choice[2] = {5, noAuth ? 0 : 0xFF}; SendAll(fd, choice, 2);
    if (!noAuth) return;
    unsigned char head[4]; if (recv(fd, head, 4, MSG_WAITALL) != 4) return;
    if (head[0] != 5 || head[1] != 1) return; // CONNECT only
    char host[1024] = {0}, port[16] = {0};
    if (head[3] == 1) {
        struct in_addr a; if (recv(fd, &a, 4, MSG_WAITALL) != 4) return;
        if (!inet_ntop(AF_INET, &a, host, sizeof(host))) return;
    } else if (head[3] == 3) {
        unsigned char len; if (recv(fd, &len, 1, MSG_WAITALL) != 1 || len == 0) return;
        if (recv(fd, host, len, MSG_WAITALL) != len) return; host[len] = 0;
    } else if (head[3] == 4) {
        struct in6_addr a6; if (recv(fd, &a6, 16, MSG_WAITALL) != 16) return;
        if (!inet_ntop(AF_INET6, &a6, host, sizeof(host))) return;
    } else return;
    unsigned char pbuf[2]; if (recv(fd, pbuf, 2, MSG_WAITALL) != 2) return;
    snprintf(port, sizeof(port), "%u", ((unsigned)pbuf[0] << 8) | pbuf[1]);
    int remote = ConnectHost(host, port);
    if (remote < 0) { unsigned char fail[10] = {5, 5, 0, 1, 0,0,0,0,0,0}; SendAll(fd, fail, sizeof(fail)); return; }
    unsigned char ok[10] = {5, 0, 0, 1, 0,0,0,0,0,0}; SendAll(fd, ok, sizeof(ok));
    Relay(fd, remote, NULL, 0); close(remote);
}

static void *ClientThread(void *opaque) {
    ClientJob *job = opaque; int fd = job->fd; ProxyMode mode = job->mode; free(job);
    struct timeval tv = { .tv_sec = 30, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (mode == MODE_HTTP) HTTPClient(fd); else SOCKSClient(fd);
    close(fd); return NULL;
}

static int MakeListener(const char *ip, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) return -1;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET; addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, ip, &addr.sin_addr) != 1 || bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 32) != 0) { close(fd); return -1; }
    return fd;
}

static void *ListenerThread(void *opaque) {
    ClientJob *settings = opaque; ProxyMode mode = settings->mode; int listener = settings->fd; int port = settings->port; free(settings);
    fprintf(stderr, "WiFiBridge: %s proxy listening on %s:%d\n", mode == MODE_HTTP ? "HTTP" : "SOCKS5", gBindIP, port);
    while (gRunning) {
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        fd_set set; FD_ZERO(&set); FD_SET(listener, &set);
        int r = select(listener + 1, &set, NULL, NULL, &tv);
        if (r < 0) { if (errno == EINTR) continue; break; }
        if (r == 0) continue;
        int client = accept(listener, NULL, NULL); if (client < 0) continue;
        ClientJob *job = calloc(1, sizeof(ClientJob)); if (!job) { close(client); continue; }
        job->fd = client; job->mode = mode;
        pthread_t thread;
        if (pthread_create(&thread, NULL, ClientThread, job) == 0) pthread_detach(thread);
        else { close(client); free(job); }
    }
    close(listener); return NULL;
}

static int RunProxy(void) {
    signal(SIGTERM, StopSignal); signal(SIGINT, StopSignal); signal(SIGHUP, StopSignal); signal(SIGPIPE, SIG_IGN);
    int httpFD = MakeListener(gBindIP, gHTTPPort);
    if (httpFD < 0) { fprintf(stderr, "WiFiBridge: cannot bind HTTP %s:%d: %s\n", gBindIP, gHTTPPort, strerror(errno)); return 1; }
    int socksFD = MakeListener(gBindIP, gSOCKSPort);
    if (socksFD < 0) { fprintf(stderr, "WiFiBridge: cannot bind SOCKS5 %s:%d: %s\n", gBindIP, gSOCKSPort, strerror(errno)); close(httpFD); return 1; }
    pthread_t httpThread, socksThread;
    ClientJob *h = calloc(1, sizeof(ClientJob)); ClientJob *s = calloc(1, sizeof(ClientJob));
    if (!h || !s) { if (h) free(h); if (s) free(s); close(httpFD); close(socksFD); return 1; }
    h->fd = httpFD; h->mode = MODE_HTTP; h->port = gHTTPPort; s->fd = socksFD; s->mode = MODE_SOCKS; s->port = gSOCKSPort;
    if (pthread_create(&httpThread, NULL, ListenerThread, h) != 0) { free(h); free(s); close(httpFD); close(socksFD); return 1; }
    if (pthread_create(&socksThread, NULL, ListenerThread, s) != 0) { free(s); gRunning = 0; pthread_join(httpThread, NULL); close(socksFD); return 1; }
    pthread_join(httpThread, NULL); pthread_join(socksThread, NULL); return 0;
}

static NSString *ReadPID(void) { return [NSString stringWithContentsOfFile:@PID_FILE encoding:NSUTF8StringEncoding error:nil]; }
static int StartProxy(void) {
    NSString *old = ReadPID(); pid_t existing = (pid_t)[old intValue];
    if (existing > 1 && kill(existing, 0) == 0) { printf("WiFiBridge proxy already running (PID %d)\n", existing); return 0; }
    pid_t child = fork();
    if (child < 0) { perror("fork"); return 1; }
    if (child > 0) {
        usleep(700000);
        if (kill(child, 0) == 0) { printf("WiFiBridge proxy started (PID %d).\n", child); return 0; }
        puts("WiFiBridge could not bind the hotspot address. Turn on the local hotspot first; see wifibridge log.");
        return 1;
    }
    setsid(); chdir("/");
    int logfd = open(LOG_FILE, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (logfd >= 0) { dup2(logfd, STDOUT_FILENO); dup2(logfd, STDERR_FILENO); close(logfd); }
    close(STDIN_FILENO);
    NSString *pid = [NSString stringWithFormat:@"%d", getpid()];
    [pid writeToFile:@PID_FILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
    int result = RunProxy(); unlink(PID_FILE); _exit(result);
}

static int StopProxy(void) {
    pid_t pid = (pid_t)[ReadPID() intValue];
    if (pid <= 1) { puts("WiFiBridge proxy is not running."); return 0; }
    if (kill(pid, SIGTERM) != 0 && errno != ESRCH) { perror("kill"); return 1; }
    unlink(PID_FILE); puts("WiFiBridge proxy stopped."); return 0;
}

static int TestProxy(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0); if (fd < 0) { perror("socket"); return 1; }
    struct sockaddr_in addr; memset(&addr, 0, sizeof(addr)); addr.sin_family = AF_INET; addr.sin_port = htons(gHTTPPort);
    inet_pton(AF_INET, gBindIP, &addr.sin_addr);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { printf("FAIL: proxy is not listening on %s:%d (%s)\n", gBindIP, gHTTPPort, strerror(errno)); close(fd); return 1; }
    const char *req = "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n";
    if (SendAll(fd, req, strlen(req)) != 0) { close(fd); return 1; }
    struct timeval tv = { .tv_sec = 12, .tv_usec = 0 }; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    char response[512] = {0}; ssize_t n = recv(fd, response, sizeof(response)-1, 0); close(fd);
    if (n > 0 && strstr(response, "200 Connection Established")) { puts("PASS: proxy reached example.com:443 through the iPhone's active route."); return 0; }
    if (n > 0) printf("FAIL: upstream connection rejected: %.200s\n", response);
    else puts("FAIL: no response from upstream. Check Wi-Fi/VPN connectivity and the log.");
    return 1;
}

static void Usage(const char *name) {
    printf("WiFiBridge 0.2.0 — Wi-Fi upstream proxy\n\n");
    printf("Usage:\n  %s start [AP-IP] [HTTP-PORT] [SOCKS-PORT]\n  %s stop\n  %s status\n  %s test\n  %s log\n\n", name, name, name, name, name);
    printf("Default: bind %s, HTTP CONNECT proxy :%d, SOCKS5 proxy :%d\n", DEFAULT_BIND_IP, HTTP_PORT, SOCKS_PORT);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc >= 3 && strcmp(argv[1], "start") == 0) {
            snprintf(gBindIP, sizeof(gBindIP), "%s", argv[2]);
            if (argc >= 4) gHTTPPort = atoi(argv[3]);
            if (argc >= 5) gSOCKSPort = atoi(argv[4]);
        }
        if (argc < 2) { Usage(argv[0]); return 0; }
        if (strcmp(argv[1], "start") == 0) return StartProxy();
        if (strcmp(argv[1], "stop") == 0) return StopProxy();
        if (strcmp(argv[1], "status") == 0) {
            pid_t pid = (pid_t)[ReadPID() intValue];
            if (pid > 1 && kill(pid, 0) == 0) printf("RUNNING (PID %d) — HTTP %s:%d, SOCKS5 %s:%d\n", pid, gBindIP, gHTTPPort, gBindIP, gSOCKSPort);
            else puts("STOPPED");
            return 0;
        }
        if (strcmp(argv[1], "test") == 0) return TestProxy();
        if (strcmp(argv[1], "log") == 0) { execl("/usr/bin/tail", "tail", "-n", "80", LOG_FILE, NULL); perror("tail"); return 1; }
        Usage(argv[0]); return 1;
    }
}
