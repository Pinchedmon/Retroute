// Retroute — minimal menu-bar proxy client (mihomo core) for macOS 10.13+.
// Build: ./build.sh (compiles this file, fetches mihomo, assembles Retroute.app).
//
// Copyright (C) 2026 Pinchedmon. Licensed under the GNU GPL v3 or later, see LICENSE.

#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <CommonCrypto/CommonDigest.h>
#include <sys/sysctl.h>

static const int kProxyPort = 10808;   // mihomo mixed port: HTTP and SOCKS on one port
static NSString *const kDonateURL = @"https://new.donatepay.ru/donate/1536180";

#pragma mark - Device identity

// Panels with a device limit (Remnawave: "x-hwid-limit") hand out only stub servers such as
// "Приложение не поддерживается" unless the request names the device. The HWID is derived from the
// hardware UUID so it survives reinstalls and one Mac always takes the same slot.
static NSString *DeviceHWID(void) {
    NSString *uuid = nil;
    io_service_t dev = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("IOPlatformExpertDevice"));
    if (dev) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(dev, CFSTR(kIOPlatformUUIDKey), kCFAllocatorDefault, 0);
        if (v) uuid = (__bridge_transfer NSString *)v;
        IOObjectRelease(dev);
    }
    if (!uuid.length) uuid = [[NSUUID UUID] UUIDString];
    NSData *in = [uuid dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char h[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(in.bytes, (CC_LONG)in.length, h);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < 8; i++) [hex appendFormat:@"%02x", h[i]];
    return hex;
}

static NSString *DeviceModel(void) {
    char buf[128] = {0};
    size_t len = sizeof(buf) - 1;
    return sysctlbyname("hw.model", buf, &len, NULL, 0) == 0 ? @(buf) : @"Mac";
}

static NSString *OSVersion(void) {
    NSOperatingSystemVersion v = [NSProcessInfo processInfo].operatingSystemVersion;
    return [NSString stringWithFormat:@"%ld.%ld.%ld", (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion];
}

#pragma mark - Link parsing

static NSString *URLDecode(NSString *s) {
    if (!s) return nil;
    NSString *r = [[s stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding];
    return r ?: s;
}

static NSData *Base64DecodeLoose(NSString *s) {
    NSString *t = [[s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    t = [t stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    t = [[t componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    while (t.length % 4) t = [t stringByAppendingString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:t options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

static NSString *Base64DecodeString(NSString *s) {
    NSData *d = Base64DecodeLoose(s);
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
}

static NSDictionary<NSString *, NSString *> *QueryParams(NSString *query) {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        if (!pair.length) continue;
        NSRange eq = [pair rangeOfString:@"="];
        NSString *k = eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location];
        NSString *v = eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + 1];
        p[URLDecode(k)] = URLDecode(v) ?: @"";
    }
    return p;
}

// Splits "scheme://userinfo@host:port?query#fragment" without NSURL, which rejects many real-world links.
static BOOL SplitLink(NSString *link, NSString **user, NSString **host, int *port, NSDictionary<NSString *, NSString *> **query, NSString **name) {
    NSRange sep = [link rangeOfString:@"://"];
    if (sep.location == NSNotFound) return NO;
    NSString *rest = [link substringFromIndex:NSMaxRange(sep)];
    NSRange hash = [rest rangeOfString:@"#"];
    *name = hash.location == NSNotFound ? nil : URLDecode([rest substringFromIndex:hash.location + 1]);
    if (hash.location != NSNotFound) rest = [rest substringToIndex:hash.location];
    NSRange q = [rest rangeOfString:@"?"];
    *query = QueryParams(q.location == NSNotFound ? @"" : [rest substringFromIndex:q.location + 1]);
    if (q.location != NSNotFound) rest = [rest substringToIndex:q.location];
    if ([rest hasSuffix:@"/"]) rest = [rest substringToIndex:rest.length - 1];
    NSRange at = [rest rangeOfString:@"@" options:NSBackwardsSearch];
    *user = at.location == NSNotFound ? nil : URLDecode([rest substringToIndex:at.location]);
    NSString *hp = at.location == NSNotFound ? rest : [rest substringFromIndex:at.location + 1];
    NSRange colon = [hp rangeOfString:@":" options:NSBackwardsSearch];
    if (colon.location == NSNotFound) return NO;
    NSString *h = [hp substringToIndex:colon.location];
    if ([h hasPrefix:@"["] && [h hasSuffix:@"]"]) h = [h substringWithRange:NSMakeRange(1, h.length - 2)];
    *host = h;
    *port = [[hp substringFromIndex:colon.location + 1] intValue];
    return h.length > 0 && *port > 0;
}

static NSArray *SplitCSV(NSString *s) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *x in [s componentsSeparatedByString:@","]) if (x.length) [a addObject:x];
    return a;
}

static BOOL Truthy(NSString *v) { return [v isEqualToString:@"1"] || [v.lowercaseString isEqualToString:@"true"]; }

// "rt-headers" is Retroute's own link parameter (JSON object), attached by AttachHeaders below.
// Links saved by HappLite carry the same thing as "hl-headers".
static NSDictionary *ExtraHeaders(NSDictionary<NSString *, NSString *> *p) {
    NSString *raw = p[@"rt-headers"].length ? p[@"rt-headers"] : p[@"hl-headers"];
    if (!raw.length) return @{};
    NSDictionary *h = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [h isKindOfClass:[NSDictionary class]] ? h : @{};
}

// Xray allows ranges as "100-1000", a number or {"from":…,"to":…}; mihomo wants the string form.
static id RangeValue(id v) {
    if ([v isKindOfClass:[NSDictionary class]]) return [NSString stringWithFormat:@"%@-%@", v[@"from"], v[@"to"]];
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return v;
}

// The xhttp "extra" query parameter is Xray's JSON; servers with padding obfuscation reject requests
// (400 Bad Request) unless these settings match, so they are carried over to mihomo's names.
static void ApplyXHTTPExtra(NSMutableDictionary *xh, NSString *extraJSON) {
    if (!extraJSON.length) return;
    NSDictionary *e = [NSJSONSerialization JSONObjectWithData:[extraJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![e isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *plain = @{@"headers": @"headers", @"noGRPCHeader": @"no-grpc-header",
                            @"xPaddingKey": @"x-padding-key", @"xPaddingHeader": @"x-padding-header",
                            @"xPaddingMethod": @"x-padding-method", @"xPaddingObfsMode": @"x-padding-obfs-mode",
                            @"xPaddingPlacement": @"x-padding-placement"};
    for (NSString *k in plain) if (e[k]) xh[plain[k]] = e[k];
    NSDictionary *ranges = @{@"xPaddingBytes": @"x-padding-bytes", @"scMaxEachPostBytes": @"sc-max-each-post-bytes",
                             @"scMaxBufferedPosts": @"sc-max-buffered-posts"};
    for (NSString *k in ranges) if (e[k]) xh[ranges[k]] = RangeValue(e[k]);
    NSDictionary *x = e[@"xmux"];
    if ([x isKindOfClass:[NSDictionary class]]) {
        NSDictionary *mux = @{@"maxConcurrency": @"max-concurrency", @"maxConnections": @"max-connections",
                              @"cMaxReuseTimes": @"c-max-reuse-times", @"hMaxRequestTimes": @"h-max-request-times",
                              @"hMaxReusableSecs": @"h-max-reusable-secs", @"hKeepAlivePeriod": @"h-keep-alive-period"};
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        for (NSString *k in mux) if (x[k]) r[mux[k]] = [k isEqualToString:@"hKeepAlivePeriod"] ? x[k] : RangeValue(x[k]);
        if (r.count) xh[@"reuse-settings"] = r;
    }
}

// Transport part of a mihomo proxy (network + *-opts). NO for transports mihomo can't do.
static BOOL ApplyTransport(NSMutableDictionary *px, NSString *network, NSDictionary<NSString *, NSString *> *p) {
    NSString *net = network.length ? network.lowercaseString : @"tcp";
    NSString *host = p[@"host"], *path = p[@"path"];
    if ([net isEqualToString:@"tcp"] || [net isEqualToString:@"raw"]) {
        if ([p[@"headerType"] isEqualToString:@"http"]) {
            px[@"network"] = @"http";
            px[@"http-opts"] = @{@"path": path.length ? SplitCSV(path) : @[@"/"],
                                 @"headers": @{@"Host": host.length ? SplitCSV(host) : @[]}};
        } else {
            px[@"network"] = @"tcp";
        }
    } else if ([net isEqualToString:@"ws"] || [net isEqualToString:@"httpupgrade"]) {
        NSMutableDictionary *ws = [@{@"path": path.length ? path : @"/"} mutableCopy];
        NSMutableDictionary *hdr = [ExtraHeaders(p) mutableCopy];
        if (host.length) hdr[@"Host"] = host;
        if (hdr.count) ws[@"headers"] = hdr;
        if ([net isEqualToString:@"httpupgrade"]) ws[@"v2ray-http-upgrade"] = @YES;
        px[@"network"] = @"ws";
        px[@"ws-opts"] = ws;
    } else if ([net isEqualToString:@"grpc"]) {
        px[@"network"] = @"grpc";
        px[@"grpc-opts"] = @{@"grpc-service-name": p[@"serviceName"] ?: @""};
    } else if ([net isEqualToString:@"h2"] || [net isEqualToString:@"http"]) {
        NSMutableDictionary *h2 = [@{@"path": path.length ? path : @"/"} mutableCopy];
        if (host.length) h2[@"host"] = SplitCSV(host);
        px[@"network"] = @"h2";
        px[@"h2-opts"] = h2;
    } else if ([net isEqualToString:@"xhttp"] || [net isEqualToString:@"splithttp"]) {
        NSMutableDictionary *xh = [@{@"path": path.length ? path : @"/"} mutableCopy];
        if (host.length) xh[@"host"] = host;
        if (p[@"mode"].length) xh[@"mode"] = p[@"mode"];
        ApplyXHTTPExtra(xh, p[@"extra"]);
        if (ExtraHeaders(p).count) {
            NSMutableDictionary *hdr = [ExtraHeaders(p) mutableCopy];
            if ([xh[@"headers"] isKindOfClass:[NSDictionary class]]) [hdr addEntriesFromDictionary:xh[@"headers"]];
            xh[@"headers"] = hdr;
        }
        px[@"network"] = @"xhttp";
        px[@"xhttp-opts"] = xh;
    } else {
        return NO;
    }
    return YES;
}

// TLS / REALITY part. `sniKey` differs by protocol: trojan says "sni", others "servername".
static void ApplySecurity(NSMutableDictionary *px, NSString *security, NSDictionary<NSString *, NSString *> *p,
                          NSString *fallbackSNI, NSString *sniKey) {
    NSString *sni = p[@"sni"].length ? p[@"sni"] : (p[@"peer"].length ? p[@"peer"] : fallbackSNI);
    NSString *fp = p[@"fp"].length ? p[@"fp"] : @"chrome";
    if ([security isEqualToString:@"tls"]) {
        px[@"tls"] = @YES;
        if (sni.length) px[sniKey] = sni;
        px[@"client-fingerprint"] = fp;
        if (p[@"alpn"].length) px[@"alpn"] = SplitCSV(p[@"alpn"]);
        if (Truthy(p[@"allowInsecure"]) || Truthy(p[@"insecure"])) px[@"skip-cert-verify"] = @YES;
    } else if ([security isEqualToString:@"reality"]) {
        px[@"tls"] = @YES;
        if (sni.length) px[sniKey] = sni;
        px[@"client-fingerprint"] = fp;
        // Since XTLS/REALITY 8cdf7bf (Sep 2026) servers drop Client Hellos without an X25519MLKEM768
        // key share, so it is on unless the link explicitly turns it off.
        NSString *pq = p[@"support-x25519mlkem768"];
        px[@"reality-opts"] = @{@"public-key": p[@"pbk"] ?: @"", @"short-id": p[@"sid"] ?: @"",
                                @"support-x25519mlkem768": (pq.length ? Truthy(pq) : YES) ? @YES : @NO};
    }
}

// Returns @{@"name":…, @"proxy":…} (a mihomo proxy entry) or nil when the link is unsupported.
static NSDictionary *ParseLink(NSString *raw) {
    NSString *link = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *user, *host, *name; int port = 0; NSDictionary<NSString *, NSString *> *p;
    NSMutableDictionary *px = [@{@"name": @"proxy", @"udp": @YES} mutableCopy];

    if ([link hasPrefix:@"vmess://"]) {
        NSString *json = Base64DecodeString([link substringFromIndex:8]);
        NSDictionary *j = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if (![j isKindOfClass:[NSDictionary class]]) return nil;
        NSMutableDictionary<NSString *, NSString *> *q = [NSMutableDictionary dictionary];
        for (NSString *k in j) q[k] = [NSString stringWithFormat:@"%@", j[k]];
        q[@"headerType"] = q[@"type"];
        q[@"serviceName"] = q[@"path"];
        [px addEntriesFromDictionary:@{@"type": @"vmess", @"server": q[@"add"] ?: @"", @"port": @([q[@"port"] intValue]),
                                       @"uuid": q[@"id"] ?: @"", @"alterId": @([q[@"aid"] intValue]),
                                       @"cipher": q[@"scy"].length ? q[@"scy"] : @"auto"}];
        if (!ApplyTransport(px, q[@"net"], q)) return nil;
        ApplySecurity(px, q[@"tls"], q, q[@"host"], @"servername");
        return @{@"name": q[@"ps"].length ? q[@"ps"] : q[@"add"], @"proxy": px};
    }

    if ([link hasPrefix:@"ss://"]) {
        NSString *body = [link substringFromIndex:5];
        NSRange hash = [body rangeOfString:@"#"];
        NSString *frag = hash.location == NSNotFound ? nil : [body substringFromIndex:hash.location + 1];
        if (hash.location != NSNotFound) body = [body substringToIndex:hash.location];
        if ([body rangeOfString:@"@"].location == NSNotFound) {   // legacy: whole thing base64
            NSString *dec = Base64DecodeString([body componentsSeparatedByString:@"?"][0]);
            if (!dec) return nil;
            body = dec;
        }
        NSString *rebuilt = [NSString stringWithFormat:@"ss://%@%@", body, frag ? [@"#" stringByAppendingString:frag] : @""];
        if (!SplitLink(rebuilt, &user, &host, &port, &p, &name) || !user) return nil;
        NSString *cred = [user rangeOfString:@":"].location == NSNotFound ? Base64DecodeString(user) : user;
        NSRange c = [cred rangeOfString:@":"];
        if (!cred || c.location == NSNotFound) return nil;
        [px addEntriesFromDictionary:@{@"type": @"ss", @"server": host, @"port": @(port),
                                       @"cipher": [cred substringToIndex:c.location],
                                       @"password": [cred substringFromIndex:c.location + 1]}];
        return @{@"name": name.length ? name : host, @"proxy": px};
    }

    if ([link hasPrefix:@"hysteria2://"] || [link hasPrefix:@"hy2://"]) {
        if (!SplitLink(link, &user, &host, &port, &p, &name) || !user) return nil;
        [px addEntriesFromDictionary:@{@"type": @"hysteria2", @"server": host, @"port": @(port), @"password": user}];
        if (p[@"sni"].length) px[@"sni"] = p[@"sni"];
        if (Truthy(p[@"insecure"])) px[@"skip-cert-verify"] = @YES;
        // Self-signed servers are pinned by certificate SHA-256 ("C7:54:…"); mihomo takes plain hex.
        if (p[@"pinSHA256"].length)
            px[@"fingerprint"] = [[p[@"pinSHA256"] stringByReplacingOccurrencesOfString:@":" withString:@""] lowercaseString];
        if (p[@"obfs"].length) { px[@"obfs"] = p[@"obfs"]; px[@"obfs-password"] = p[@"obfs-password"] ?: @""; }
        return @{@"name": name.length ? name : host, @"proxy": px};
    }

    BOOL vless = [link hasPrefix:@"vless://"], trojan = [link hasPrefix:@"trojan://"];
    if (!vless && !trojan) return nil;
    if (!SplitLink(link, &user, &host, &port, &p, &name) || !user) return nil;
    NSString *security = p[@"security"] ?: (trojan ? @"tls" : @"none");
    if (vless) {
        [px addEntriesFromDictionary:@{@"type": @"vless", @"server": host, @"port": @(port), @"uuid": user}];
        if (p[@"flow"].length) px[@"flow"] = p[@"flow"];
        if (p[@"encryption"].length && ![p[@"encryption"] isEqualToString:@"none"]) px[@"encryption"] = p[@"encryption"];
    } else {
        [px addEntriesFromDictionary:@{@"type": @"trojan", @"server": host, @"port": @(port), @"password": user}];
    }
    if (!ApplyTransport(px, p[@"type"], p)) return nil;
    ApplySecurity(px, security, p, host, trojan ? @"sni" : @"servername");
    return @{@"name": name.length ? name : host, @"proxy": px};
}

// Accepts a subscription body (base64 or plain) or pasted links. Servers keep the raw link and are
// parsed again on connect, so parser fixes apply to already saved subscriptions.
static NSArray *ParseServers(NSString *text, NSUInteger *skipped) {
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t rangeOfString:@"://"].location == NSNotFound) t = Base64DecodeString(t) ?: @"";
    NSMutableArray *out = [NSMutableArray array];
    *skipped = 0;
    for (NSString *line in [t componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([l rangeOfString:@"://"].location == NSNotFound) continue;
        NSDictionary *s = ParseLink(l);
        if (s) [out addObject:@{@"name": s[@"name"], @"link": l}]; else (*skipped)++;
    }
    return out;
}

// Share links can't carry transport headers, yet some servers check them (httpupgrade with a browser
// Origin/User-Agent). The same subscription in Happ's JSON form has them, so they are copied onto the
// link whose name matches the config's "remarks". Returns plain links, one per line.
static NSString *AttachHeaders(NSString *linksText, NSData *happJSON) {
    NSString *t = [linksText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([t rangeOfString:@"://"].location == NSNotFound) t = Base64DecodeString(t) ?: linksText;
    NSArray *configs = happJSON ? [NSJSONSerialization JSONObjectWithData:happJSON options:0 error:nil] : nil;
    if (![configs isKindOfClass:[NSArray class]]) return t;

    NSMutableDictionary *byName = [NSMutableDictionary dictionary];
    for (NSDictionary *c in configs) {
        if (![c isKindOfClass:[NSDictionary class]] || ![c[@"remarks"] isKindOfClass:[NSString class]]) continue;
        for (NSDictionary *o in c[@"outbounds"]) {
            if (![o isKindOfClass:[NSDictionary class]] || ![o[@"tag"] isEqual:@"proxy"]) continue;
            NSDictionary *ss = o[@"streamSettings"];
            for (NSString *k in @[@"httpupgradeSettings", @"wsSettings", @"xhttpSettings"]) {
                NSDictionary *h = [ss isKindOfClass:[NSDictionary class]] ? ss[k][@"headers"] : nil;
                if ([h isKindOfClass:[NSDictionary class]] && h.count) byName[c[@"remarks"]] = h;
            }
        }
    }
    if (!byName.count) return t;

    NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
    [allowed removeCharactersInString:@"&=+#?"];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *line in [t componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *l = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *user, *host, *name; int port; NSDictionary *q;
        NSDictionary *h = SplitLink(l, &user, &host, &port, &q, &name) && name ? byName[name] : nil;
        if (h) {
            NSData *j = [NSJSONSerialization dataWithJSONObject:h options:0 error:nil];
            NSString *param = [@"rt-headers=" stringByAppendingString:
                [[[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] stringByAddingPercentEncodingWithAllowedCharacters:allowed]];
            NSRange hash = [l rangeOfString:@"#"];
            NSString *head = hash.location == NSNotFound ? l : [l substringToIndex:hash.location];
            NSString *tail = hash.location == NSNotFound ? @"" : [l substringFromIndex:hash.location];
            l = [NSString stringWithFormat:@"%@%@%@%@", head, [head rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", param, tail];
        }
        if (l.length) [out addObject:l];
    }
    return [out componentsJoinedByString:@"\n"];
}

static NSMutableURLRequest *SubscriptionRequest(NSString *url, NSString *userAgent) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [req setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    // Device-limited panels (Remnawave "x-hwid-limit") answer with stubs without these.
    [req setValue:DeviceHWID() forHTTPHeaderField:@"x-hwid"];
    [req setValue:@"macOS" forHTTPHeaderField:@"x-device-os"];
    [req setValue:OSVersion() forHTTPHeaderField:@"x-ver-os"];
    [req setValue:DeviceModel() forHTTPHeaderField:@"x-device-model"];
    req.timeoutInterval = 20;
    return req;
}

// Fetches share links (v2rayN UA), then the Happ JSON form for headers. The second request is best
// effort: if it fails, the links are used as they are. `done` runs on the main queue.
static void FetchSubscription(NSString *url, void (^done)(NSString *text, NSString *error)) {
    NSURLSession *s = [NSURLSession sharedSession];
    [[s dataTaskWithRequest:SubscriptionRequest(url, @"v2rayN/6.45") completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *body = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
        NSInteger code = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        if (e || !body || code >= 400) {
            NSString *err = e ? [NSString stringWithFormat:@"%@\n\n(%@ %ld)", e.localizedDescription, e.domain, (long)e.code]
                              : [NSString stringWithFormat:@"HTTP %ld", (long)code];
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, err); });
            return;
        }
        [[s dataTaskWithRequest:SubscriptionRequest(url, @"Happ/2.17.1/macos") completionHandler:^(NSData *jd, NSURLResponse *jr, NSError *je) {
            NSString *text = AttachHeaders(body, je ? nil : jd);
            dispatch_async(dispatch_get_main_queue(), ^{ done(text, nil); });
        }] resume];
    }] resume];
}

// mihomo reads YAML, and JSON is valid YAML — so the config is written with NSJSONSerialization.
static NSDictionary *BuildConfig(NSDictionary *proxy) {
    NSArray *privateNets = @[@"10.0.0.0/8", @"172.16.0.0/12", @"192.168.0.0/16", @"127.0.0.0/8",
                             @"169.254.0.0/16", @"100.64.0.0/10"];
    NSMutableArray *rules = [NSMutableArray array];
    for (NSString *net in privateNets) [rules addObject:[NSString stringWithFormat:@"IP-CIDR,%@,DIRECT,no-resolve", net]];
    [rules addObject:@"DOMAIN,localhost,DIRECT"];
    [rules addObject:@"MATCH,proxy"];
    return @{@"mixed-port": @(kProxyPort), @"bind-address": @"127.0.0.1", @"allow-lan": @NO,
             @"mode": @"rule", @"log-level": @"warning", @"ipv6": @NO,
             @"proxies": @[proxy], @"rules": rules};
}

// JSON text for the mihomo config. NSJSONSerialization writes "/" as "\/" — fine for JSON, but YAML
// rejects that escape, and the option to turn it off only exists from 10.15.
static NSData *ConfigData(NSDictionary *config) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    NSString *text = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    return [[text stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"] dataUsingEncoding:NSUTF8StringEncoding];
}

#pragma mark - App

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *item;
@property (strong) NSTask *core;
@property (strong) NSArray *servers;
@property (assign) BOOL wantConnected;
@end

@implementation AppDelegate

- (NSString *)supportDir {
    NSString *d = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Retroute"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
    return d;
}

- (NSUserDefaults *)defs { return [NSUserDefaults standardUserDefaults]; }

// HappLite kept its settings under the bundle id "local.happlite"; they are copied over once so an
// upgrade keeps the subscription and the chosen server.
- (void)importHappLiteSettings {
    if ([self.defs boolForKey:@"importedHappLite"]) return;
    [self.defs setBool:YES forKey:@"importedHappLite"];
    NSDictionary *old = [self.defs persistentDomainForName:@"local.happlite"];
    for (NSString *k in @[@"subscription", @"servers", @"selected"])
        if (old[k] && ![self.defs objectForKey:k]) [self.defs setObject:old[k] forKey:k];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self importHappLiteSettings];
    self.item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.item.menu = [NSMenu new];
    self.item.menu.delegate = self;
    // Servers saved by the Xray-based 1.0 carry a ready config instead of the link; they can't be
    // reused, so such a list is dropped and the subscription is fetched again.
    NSArray *saved = [self.defs arrayForKey:@"servers"] ?: @[];
    self.servers = [saved filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"link != nil"]];
    if (self.servers.count != saved.count) {
        [self.defs setObject:self.servers forKey:@"servers"];
        if ([self.defs stringForKey:@"subscription"].length) [self refresh:nil];
    }
    [self updateTitle];
    if (![self.defs stringForKey:@"subscription"].length && !self.servers.count) [self addSubscription:nil];
}

- (void)updateTitle {
    self.item.button.title = self.core.isRunning ? @"R ●" : @"R ○";
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    BOOL on = self.core.isRunning;
    NSInteger sel = [self.defs integerForKey:@"selected"];
    NSString *cur = sel < (NSInteger)self.servers.count ? self.servers[sel][@"name"] : @"—";
    [menu addItemWithTitle:(on ? [@"Подключено: " stringByAppendingString:cur] : @"Отключено") action:nil keyEquivalent:@""];
    [menu addItemWithTitle:(on ? @"Отключить" : @"Подключить") action:@selector(toggle:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *srv = [menu addItemWithTitle:@"Серверы" action:nil keyEquivalent:@""];
    srv.submenu = [NSMenu new];
    [self.servers enumerateObjectsUsingBlock:^(NSDictionary *s, NSUInteger i, BOOL *stop) {
        NSMenuItem *mi = [srv.submenu addItemWithTitle:s[@"name"] action:@selector(pick:) keyEquivalent:@""];
        mi.tag = i;
        mi.state = (NSInteger)i == sel ? NSControlStateValueOn : NSControlStateValueOff;
    }];
    if (!self.servers.count) [srv.submenu addItemWithTitle:@"(пусто)" action:nil keyEquivalent:@""];

    [menu addItemWithTitle:@"Обновить подписку" action:@selector(refresh:) keyEquivalent:@"r"];
    [menu addItemWithTitle:@"Добавить подписку или ссылки…" action:@selector(addSubscription:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Открыть лог" action:@selector(openLog:) keyEquivalent:@""];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Поддержать автора…" action:@selector(donate:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Выход" action:@selector(quit:) keyEquivalent:@"q"];
    for (NSMenuItem *mi in menu.itemArray) mi.target = self;
    for (NSMenuItem *mi in srv.submenu.itemArray) mi.target = self;
}

- (void)alert:(NSString *)title text:(NSString *)text {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = text ?: @"";
    [NSApp activateIgnoringOtherApps:YES];
    [a runModal];
}

- (void)addSubscription:(id)sender {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Подписка или ссылки";
    a.informativeText = @"Вставь URL подписки (https://…) или ссылки vless:// vmess:// trojan:// ss:// hysteria2:// — по одной в строке.";
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 120)];
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.font = [NSFont userFixedPitchFontOfSize:11];
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.string = [self.defs stringForKey:@"subscription"] ?: @"";
    sv.documentView = tv;
    sv.hasVerticalScroller = YES;
    a.accessoryView = sv;
    [a addButtonWithTitle:@"Сохранить"];
    [a addButtonWithTitle:@"Отмена"];
    [NSApp activateIgnoringOtherApps:YES];
    [a.window setInitialFirstResponder:tv];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString *input = [tv.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!input.length) return;
    if ([input hasPrefix:@"http://"] || [input hasPrefix:@"https://"]) {
        [self.defs setObject:input forKey:@"subscription"];
        [self refresh:nil];
    } else {
        [self.defs removeObjectForKey:@"subscription"];
        [self applyServerText:input];
    }
}

- (void)applyServerText:(NSString *)text {
    if ([text hasPrefix:@"happ://"] || [text rangeOfString:@"\nhapp://"].location != NSNotFound) {
        [self alert:@"Зашифрованная ссылка Happ" text:@"happ://crypt… расшифровывает только сам Happ. Попроси у провайдера обычную ссылку подписки."];
        return;
    }
    NSUInteger skipped = 0;
    NSArray *list = ParseServers(text, &skipped);
    // Stub answer (every server points at 0.0.0.0): the panel refused this device. Keep the old list.
    BOOL allStubs = list.count > 0;
    for (NSDictionary *s in list)
        if (![ParseLink(s[@"link"])[@"proxy"][@"server"] isEqualToString:@"0.0.0.0"]) { allStubs = NO; break; }
    if (allStubs) {
        NSArray *names = [list valueForKey:@"name"];
        [self alert:@"Подписка отдала заглушки вместо серверов"
               text:[NSString stringWithFormat:@"Ответ сервера: «%@».\n\nЧаще всего это значит, что исчерпан лимит устройств. Удали лишнее устройство в боте провайдера и нажми «Обновить подписку».\n\nHWID этого Mac: %@",
                     [names componentsJoinedByString:@" / "], DeviceHWID()]];
        return;
    }
    if (!list.count) {
        [self alert:@"Серверы не найдены" text:[NSString stringWithFormat:@"Пропущено ссылок: %lu. Поддерживаются vless/vmess/trojan/ss/hysteria2 с транспортом tcp/ws/grpc/h2/xhttp/httpupgrade. tuic и прочее — нет.", (unsigned long)skipped]];
        return;
    }
    self.servers = list;
    [self.defs setObject:list forKey:@"servers"];
    if ([self.defs integerForKey:@"selected"] >= (NSInteger)list.count) [self.defs setInteger:0 forKey:@"selected"];
    if (skipped) [self alert:[NSString stringWithFormat:@"Загружено серверов: %lu", (unsigned long)list.count]
                        text:[NSString stringWithFormat:@"Пропущено неподдерживаемых: %lu (tuic, wireguard и т.п.).", (unsigned long)skipped]];
    if (self.core.isRunning) [self connect];
}

- (void)refresh:(id)sender {
    NSString *sub = [self.defs stringForKey:@"subscription"];
    if (!sub.length) { if (sender) [self addSubscription:nil]; return; }
    FetchSubscription(sub, ^(NSString *text, NSString *error) {
        if (error) { [self alert:@"Не удалось скачать подписку" text:error]; return; }
        [self applyServerText:text];
    });
}

- (void)pick:(NSMenuItem *)mi {
    [self.defs setInteger:mi.tag forKey:@"selected"];
    if (self.core.isRunning) [self connect];
}

- (void)toggle:(id)sender {
    if (self.core.isRunning) [self disconnect]; else [self connect];
}

- (NSString *)logPath { return [[self supportDir] stringByAppendingPathComponent:@"core.log"]; }

- (void)openLog:(id)sender {
    [[NSFileManager defaultManager] createFileAtPath:[self logPath] contents:nil attributes:nil];
    [[NSWorkspace sharedWorkspace] openFile:[self logPath]];
}

- (void)connect {
    NSInteger sel = [self.defs integerForKey:@"selected"];
    if (sel >= (NSInteger)self.servers.count) { [self addSubscription:nil]; return; }
    [self stopCore];

    NSDictionary *parsed = ParseLink(self.servers[sel][@"link"]);
    if (!parsed) { [self alert:@"Сервер не поддерживается" text:@"Выбери другой сервер в меню «Серверы»."]; return; }
    NSString *cfgPath = [[self supportDir] stringByAppendingPathComponent:@"config.yaml"];
    NSData *cfg = ConfigData(BuildConfig(parsed[@"proxy"]));
    [cfg writeToFile:cfgPath atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:cfgPath error:nil];

    [[NSFileManager defaultManager] createFileAtPath:[self logPath] contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:[self logPath]];

    NSTask *t = [NSTask new];
    t.launchPath = [[NSBundle mainBundle] pathForResource:@"mihomo" ofType:nil];
    t.arguments = @[@"-d", [self supportDir], @"-f", cfgPath];
    t.standardOutput = log ?: [NSFileHandle fileHandleWithNullDevice];
    t.standardError = log ?: [NSFileHandle fileHandleWithNullDevice];
    __weak AppDelegate *weakSelf = self;
    t.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *s = weakSelf;
            if (s.core != task) return;
            [s setSystemProxy:NO];
            [s updateTitle];
            if (s.wantConnected) [s alert:@"Ядро остановилось" text:@"Меню → «Открыть лог» покажет причину."];
            s.wantConnected = NO;
        });
    };
    @try { [t launch]; } @catch (NSException *ex) { [self alert:@"Не удалось запустить ядро" text:ex.reason]; return; }
    self.core = t;
    self.wantConnected = YES;
    [self setSystemProxy:YES];
    [self updateTitle];
}

- (void)stopCore {
    NSTask *t = self.core;
    self.core = nil;
    self.wantConnected = NO;
    if (t.isRunning) { [t terminate]; [t waitUntilExit]; }
}

- (void)disconnect {
    [self stopCore];
    [self setSystemProxy:NO];
    [self updateTitle];
}

- (NSArray *)networkServices {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/sbin/networksetup";
    t.arguments = @[@"-listallnetworkservices"];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    [t launch];
    NSData *d = [pipe.fileHandleForReading readDataToEndOfFile];
    [t waitUntilExit];
    NSMutableArray *out = [NSMutableArray array];
    NSArray *lines = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 1; i < lines.count; i++)   // line 0 is the "asterisk denotes…" banner
        if ([lines[i] length] && ![lines[i] hasPrefix:@"*"]) [out addObject:lines[i]];
    return out;
}

- (int)runNetworksetup:(NSArray *)args {
    NSTask *t = [NSTask new];
    t.launchPath = @"/usr/sbin/networksetup";
    t.arguments = args;
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    [t launch];
    [t waitUntilExit];
    return t.terminationStatus;
}

- (void)setSystemProxy:(BOOL)on {
    NSString *h = @"127.0.0.1", *hp = [NSString stringWithFormat:@"%d", kProxyPort], *sp = hp;
    for (NSString *svc in [self networkServices]) {
        if (on) {
            [self runNetworksetup:@[@"-setwebproxy", svc, h, hp]];
            [self runNetworksetup:@[@"-setsecurewebproxy", svc, h, hp]];
            [self runNetworksetup:@[@"-setsocksfirewallproxy", svc, h, sp]];
        } else {
            [self runNetworksetup:@[@"-setwebproxystate", svc, @"off"]];
            [self runNetworksetup:@[@"-setsecurewebproxystate", svc, @"off"]];
            [self runNetworksetup:@[@"-setsocksfirewallproxystate", svc, @"off"]];
        }
    }
}

- (void)donate:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:kDonateURL]];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)n {
    if (self.core) [self disconnect];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Headless helper for testing: Retroute --gen '<link>' prints the mihomo config.
        if (argc == 3 && strcmp(argv[1], "--gen") == 0) {
            NSDictionary *s = ParseLink([NSString stringWithUTF8String:argv[2]]);
            if (!s) { fprintf(stderr, "unsupported link\n"); return 1; }
            NSData *d = ConfigData(BuildConfig(s[@"proxy"]));
            fwrite(d.bytes, 1, d.length, stdout);
            return 0;
        }
        // Retroute --fetch '<url>' prints the links exactly as the app would store them.
        if (argc == 3 && strcmp(argv[1], "--fetch") == 0) {
            __block int rc = 1;
            FetchSubscription([NSString stringWithUTF8String:argv[2]], ^(NSString *text, NSString *error) {
                if (error) fprintf(stderr, "%s\n", error.UTF8String); else { printf("%s\n", text.UTF8String); rc = 0; }
                CFRunLoopStop(CFRunLoopGetMain());
            });
            CFRunLoopRun();
            return rc;
        }
        if (argc == 2 && strcmp(argv[1], "--hwid") == 0) {
            printf("%s %s %s\n", DeviceHWID().UTF8String, OSVersion().UTF8String, DeviceModel().UTF8String);
            return 0;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *del = [AppDelegate new];
        app.delegate = del;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
