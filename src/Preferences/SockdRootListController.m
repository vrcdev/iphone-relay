#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

// Preferences.framework is private — declare the small slice we use instead
// of SDK headers. Linked via -undefined dynamic_lookup; Preferences.app has
// the framework loaded already.
@interface PSSpecifier : NSObject
@property(retain) NSString *identifier;
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set get:(SEL)get detail:(Class)detail cell:(int)cell edit:(Class)edit;
+ (id)groupSpecifierWithName:(NSString *)name;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController {
    @protected NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
- (id)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (PSSpecifier *)specifierForID:(NSString *)identifier;
@end

#define RELAY_PORT 9876
#define LOG_PATH @"/var/jb/var/log/sockd.log"

static int tcp_connect(uint32_t addr_be, uint16_t port, int msec) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET; sa.sin_port = htons(port); sa.sin_addr.s_addr = addr_be;
    fcntl(fd, F_SETFL, O_NONBLOCK);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0 && errno != EINPROGRESS) {
        close(fd); return -1;
    }
    fd_set w; FD_ZERO(&w); FD_SET(fd, &w);
    struct timeval tv = { msec / 1000, (msec % 1000) * 1000 };
    if (select(fd + 1, NULL, &w, NULL, &tv) <= 0) { close(fd); return -1; }
    int err = 0; socklen_t n = sizeof err;
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &n);
    if (err) { close(fd); return -1; }
    fcntl(fd, F_SETFL, 0);
    return fd;
}

static int read_timeout(int fd, void *buf, size_t len, int msec) {
    fd_set r; FD_ZERO(&r); FD_SET(fd, &r);
    struct timeval tv = { msec / 1000, (msec % 1000) * 1000 };
    if (select(fd + 1, &r, NULL, NULL, &tv) <= 0) return -1;
    return (int)read(fd, buf, len);
}

@interface SockdRootListController : PSListController
@end

@implementation SockdRootListController {
    NSString *_exitIP;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        PSSpecifier *g = [self specifierForID:@"loggroup"];
        if (g) [g setProperty:[self logTail] forKey:@"footerText"];
    }
    return _specifiers;
}

- (id)daemonStatus:(PSSpecifier *)spec {
    int fd = tcp_connect(htonl(INADDR_LOOPBACK), RELAY_PORT, 800);
    if (fd >= 0) { close(fd); return @"LISTENING on :9876"; }
    return @"not running";
}

- (id)wifiAddress:(PSSpecifier *)spec {
    NSString *out = @"not connected";
    struct ifaddrs *list = NULL, *ifa;
    if (getifaddrs(&list) == 0) {
        for (ifa = list; ifa; ifa = ifa->ifa_next) {
            if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_INET
                && strcmp(ifa->ifa_name, "en0") == 0) {
                out = [NSString stringWithUTF8String:
                       inet_ntoa(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr)];
                break;
            }
        }
        freeifaddrs(list);
    }
    return out;
}

- (id)exitIPStatus:(PSSpecifier *)spec {
    return _exitIP ?: @"tap Test Relay";
}

- (NSString *)logTail {
    NSString *log = [NSString stringWithContentsOfFile:LOG_PATH
                            encoding:NSUTF8StringEncoding error:nil];
    if (log.length == 0)
        return @"no log output (microsocks is quiet unless errors occur)";
    NSMutableArray *lines = [[log componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]] mutableCopy];
    [lines removeObject:@""];
    NSUInteger start = lines.count > 15 ? lines.count - 15 : 0;
    return [[lines subarrayWithRange:NSMakeRange(start, lines.count - start)]
            componentsJoinedByString:@"\n"];
}

- (void)refreshStatus {
    _specifiers = nil;
    [self reloadSpecifiers];
}

- (void)testRelay {
    _exitIP = @"testing…";
    PSSpecifier *s = [self specifierForID:@"exitip"];
    if (s) [self reloadSpecifier:s];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *ip = [self fetchExitIP];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_exitIP = ip;
            PSSpecifier *spec = [self specifierForID:@"exitip"];
            if (spec) [self reloadSpecifier:spec];
        });
    });
}

// Full relay check: SOCKS5 CONNECT through 127.0.0.1:9876 to ip-api.com:80,
// plain HTTP GET, parse the "query" field = the IP the world sees.
- (NSString *)fetchExitIP {
    // ObjC objects declared up top — goto can't jump over __strong inits under ARC
    NSMutableData *resp = nil;
    NSString *body = nil;
    NSRegularExpression *re = nil;
    NSTextCheckingResult *m = nil;
    int fd = tcp_connect(htonl(INADDR_LOOPBACK), RELAY_PORT, 3000);
    if (fd < 0) return @"daemon not listening";
    unsigned char buf[1024];
    unsigned char greet[3] = { 0x05, 0x01, 0x00 };
    if (write(fd, greet, 3) != 3) goto fail;
    if (read_timeout(fd, buf, 2, 3000) != 2 || buf[0] != 0x05) goto fail;

    const char *host = "ip-api.com";
    int hl = (int)strlen(host);
    unsigned char req[7 + 64];
    req[0] = 0x05; req[1] = 0x01; req[2] = 0x00; req[3] = 0x03; req[4] = hl;
    memcpy(req + 5, host, hl);
    req[5 + hl] = 0x00; req[6 + hl] = 80;
    if (write(fd, req, 7 + hl) != 7 + hl) goto fail;
    if (read_timeout(fd, buf, 10, 3000) < 4 || buf[1] != 0x00) goto fail;

    const char *get = "GET /json HTTP/1.0\r\nHost: ip-api.com\r\n\r\n";
    write(fd, get, strlen(get));
    resp = [NSMutableData new];
    int n;
    while ((n = read_timeout(fd, buf, sizeof buf, 4000)) > 0)
        [resp appendBytes:buf length:n];
    close(fd);

    body = [[NSString alloc] initWithData:resp
                               encoding:NSUTF8StringEncoding] ?: @"";
    re = [NSRegularExpression
        regularExpressionWithPattern:@"\"query\"\\s*:\\s*\"([^\"]+)\""
        options:0 error:nil];
    m = [re firstMatchInString:body options:0
        range:NSMakeRange(0, body.length)];
    return m ? [body substringWithRange:[m rangeAtIndex:1]]
             : @"connected, exit IP not parsed";
fail:
    close(fd);
    return @"SOCKS handshake failed";
}

@end
