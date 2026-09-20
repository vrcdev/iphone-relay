#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
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
#include <pthread.h>

/* hev-socks5-server embedded entry points (src/hev-main.c) */
int hev_socks5_server_main_from_str(const unsigned char *config_str,
                                    unsigned int config_len);
void hev_socks5_server_quit(void);

#define RELAY_PORT 12080
#ifndef BUILD_TAG
#define BUILD_TAG "dev"
#endif

static NSString *gLogPath;
static volatile int gServerStarted;

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

static void *server_thread(void *arg) {
    NSString *conf = [NSString stringWithFormat:
        @"main:\n"
        @"  workers: 4\n"
        @"  listen-address: '0.0.0.0'\n"
        @"  port: %d\n"
        @"  udp-listen-address: '0.0.0.0'\n"
        @"  udp-public-address-v4: '172.20.10.1'\n"
        @"  listen-ipv6-only: false\n"
        @"  domain-address-type: ipv4\n"
        /* Uncomment to force all upstream traffic onto cellular even when
           the phone is also joined to a Wi-Fi network: */
        /* @"  bind-interface: 'pdp_ip0'\n" */
        @"misc:\n"
        @"  log-file: '%@'\n"
        @"  log-level: debug\n",
        RELAY_PORT, gLogPath];
    NSData *d = [conf dataUsingEncoding:NSUTF8StringEncoding];
    gServerStarted = 1;
    hev_socks5_server_main_from_str(d.bytes, (unsigned int)d.length);
    return NULL;
}

/* Minimal HTTP endpoint so the log can be fetched over the tether:
     curl http://172.20.10.1:11880/log */
#define LOG_HTTP_PORT 11880

static void *log_http_thread(void *arg) {
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons(LOG_HTTP_PORT);
    sa.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof sa) < 0 || listen(lfd, 4) < 0)
        return NULL;
    for (;;) {
        int c = accept(lfd, NULL, NULL);
        if (c < 0) continue;
        char req[512];
        read(c, req, sizeof req);
        NSString *log = [NSString stringWithContentsOfFile:gLogPath
                                encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSData *body = [log dataUsingEncoding:NSUTF8StringEncoding];
        char hdr[128];
        int hn = snprintf(hdr, sizeof hdr,
            "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %lu\r\n\r\n",
            (unsigned long)body.length);
        write(c, hdr, hn);
        write(c, body.bytes, body.length);
        close(c);
    }
    return NULL;
}

@interface StatusViewController : UIViewController
@end

@implementation StatusViewController {
    UILabel *_statusLabel;
    UILabel *_ifaceLabel;
    UILabel *_exitLabel;
    UITextView *_logView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"Relay";

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    _statusLabel = [self makeLabel:UIFontTextStyleTitle1 bold:YES];
    _ifaceLabel = [self makeLabel:UIFontTextStyleBody bold:NO];
    _exitLabel = [self makeLabel:UIFontTextStyleBody bold:NO];
    [stack addArrangedSubview:_statusLabel];
    [stack addArrangedSubview:_ifaceLabel];
    [stack addArrangedSubview:_exitLabel];

    UIButton *test = [UIButton buttonWithType:UIButtonTypeSystem];
    [test setTitle:@"Test Relay" forState:UIControlStateNormal];
    test.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [test addTarget:self action:@selector(testRelay) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:test];

    UIButton *refresh = [UIButton buttonWithType:UIButtonTypeSystem];
    [refresh setTitle:@"Refresh" forState:UIControlStateNormal];
    [refresh addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:refresh];

    _logView = [[UITextView alloc] init];
    _logView.editable = NO;
    _logView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _logView.layer.borderColor = UIColor.separatorColor.CGColor;
    _logView.layer.borderWidth = 0.5;
    _logView.layer.cornerRadius = 6;
    [stack addArrangedSubview:_logView];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:g.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-16],
        [_logView.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    ]];

    [self refresh];
    [NSTimer scheduledTimerWithTimeInterval:2.0
                                     target:self
                                   selector:@selector(refresh)
                                   userInfo:nil
                                    repeats:YES];
}

- (UILabel *)makeLabel:(UIFontTextStyle)style bold:(BOOL)bold {
    UILabel *l = [[UILabel alloc] init];
    l.font = bold ? [UIFont boldSystemFontOfSize:[UIFont preferredFontForTextStyle:style].pointSize]
                  : [UIFont preferredFontForTextStyle:style];
    l.numberOfLines = 0;
    return l;
}

- (void)refresh {
    int fd = tcp_connect(htonl(INADDR_LOOPBACK), RELAY_PORT, 800);
    if (fd >= 0) {
        close(fd);
        _statusLabel.text = [NSString stringWithFormat:@"LISTENING on 0.0.0.0:%d [%s]", RELAY_PORT, BUILD_TAG];
        _statusLabel.textColor = UIColor.systemGreenColor;
    } else if (gServerStarted) {
        _statusLabel.text = @"server exited — see log";
        _statusLabel.textColor = UIColor.systemRedColor;
    } else {
        _statusLabel.text = @"starting…";
        _statusLabel.textColor = UIColor.systemOrangeColor;
    }
    _ifaceLabel.text = [NSString stringWithFormat:@"Interfaces:\n%@", [self ifaceAddresses]];
    NSString *lt = [self logTail];
    if (![lt isEqualToString:_logView.text]) _logView.text = lt;
}

- (void)testRelay {
    _exitLabel.text = @"Exit IP: testing…";
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *ip = [self fetchExitIP];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_exitLabel.text = [NSString stringWithFormat:@"Exit IP: %@", ip];
        });
    });
}

- (NSString *)ifaceAddresses {
    NSMutableString *out = [NSMutableString new];
    struct ifaddrs *list = NULL, *ifa;
    if (getifaddrs(&list) == 0) {
        for (ifa = list; ifa; ifa = ifa->ifa_next) {
            if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
            if (ifa->ifa_flags & IFF_LOOPBACK) continue;
            const char *a = inet_ntoa(((struct sockaddr_in *)ifa->ifa_addr)->sin_addr);
            [out appendFormat:@"  %s = %s\n", ifa->ifa_name, a];
        }
        freeifaddrs(list);
    }
    return out.length ? out : @"  none";
}

- (NSString *)logTail {
    NSString *log = [NSString stringWithContentsOfFile:gLogPath
                            encoding:NSUTF8StringEncoding error:nil];
    if (log.length == 0) return @"no log output yet";
    NSMutableArray *lines = [[log componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]] mutableCopy];
    [lines removeObject:@""];
    NSUInteger start = lines.count > 40 ? lines.count - 40 : 0;
    return [[lines subarrayWithRange:NSMakeRange(start, lines.count - start)]
            componentsJoinedByString:@"\n"];
}

- (NSString *)fetchExitIP {
    NSMutableData *resp = nil;
    NSString *body = nil;
    NSRegularExpression *re = nil;
    NSTextCheckingResult *m = nil;
    int fd = tcp_connect(htonl(INADDR_LOOPBACK), RELAY_PORT, 3000);
    if (fd < 0) return @"relay not listening";
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
    int rn = read_timeout(fd, buf, 10, 3000);
    if (rn < 4) goto fail;
    if (buf[1] != 0x00) {
        int rep = buf[1];
        close(fd);
        return [NSString stringWithFormat:@"connect refused, socks rep=0x%02x", rep];
    }

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

/* Publishing a Bonjour service is what triggers the iOS "Local Network"
   permission prompt — without the grant, the OS resets inbound connections
   from other devices even though the listen socket accepts loopback. */
static NSNetService *gBonjour;

/* Silent audio keeps the process alive when backgrounded/screen-locked.
   Paired with the 'audio' UIBackgroundMode. */
static AVAudioEngine *gEngine;
static AVAudioPlayerNode *gPlayer;

static void start_silence(void) {
    if (gEngine) return;
    NSError *err = nil;
    AVAudioSession *s = AVAudioSession.sharedInstance;
    [s setCategory:AVAudioSessionCategoryPlayback error:&err];
    [s setActive:YES error:&err];

    gEngine = [[AVAudioEngine alloc] init];
    gPlayer = [[AVAudioPlayerNode alloc] init];
    [gEngine attachNode:gPlayer];
    AVAudioFormat *fmt = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:44100 channels:1 interleaved:NO];
    [gEngine connect:gPlayer to:gEngine.mainMixerNode format:fmt];
    gEngine.mainMixerNode.outputVolume = 0.0;

    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:fmt frameCapacity:44100];
    buf.frameLength = 44100; /* zeros = silence */

    NSError *serr = nil;
    [gEngine startAndReturnError:&serr];
    [gPlayer play];
    [gPlayer scheduleBuffer:buf atTime:nil
        options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    gLogPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"relay.log"];

    pthread_t tid;
    pthread_create(&tid, NULL, server_thread, NULL);
    pthread_detach(tid);
    pthread_create(&tid, NULL, log_http_thread, NULL);
    pthread_detach(tid);

    app.idleTimerDisabled = YES;
    start_silence();

    gBonjour = [[NSNetService alloc] initWithDomain:@"local."
                                              type:@"_socks._tcp"
                                              name:@"Relay"
                                              port:RELAY_PORT];
    [gBonjour publish];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:[StatusViewController new]];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)app {
    start_silence();
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil,
                                 NSStringFromClass([AppDelegate class]));
    }
}
