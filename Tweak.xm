// LyricSync — synchronized lyrics highlighting for the iOS 6 Music app
//
// How it works (established by runtime reconnaissance on iPhone 4S / iOS 6.1.3):
//   * lyrics are rendered inside MPWebDocumentView (a UIWebDocumentView/WebKit subclass)
//     hosted by MPTextView (_rawText → _webView, scrolling via _scrollView);
//   * -[MPWebDocumentView setContentWithString:stylesheet:] receives RAW PLAIN TEXT
//     (\n-separated, no <br> — WebKit generates those itself), so an HTML swap via %orig
//     would get escaped; instead we rebuild the DOM through JS after the load;
//   * the WebKit web thread may asynchronously wipe our rebuilt DOM (deferred plain-text
//     assembly) — DOM health is verified and the rebuild repeated on mismatch;
//   * stringByEvaluatingJavaScriptFromString on a raw WebView requires WebThreadLock(),
//     otherwise a probabilistic SIGTRAP in WebCore races with web-thread activity;
//   * playback time: +[MPAVController sharedInstance] → -currentTime.
//
// Pipeline:
//   1) setContentWithString:stylesheet: → parse LRC [mm:ss.xx] markers (lines split by \n)
//      and hand them to the engine BEFORE %orig (the web load is synchronous, and
//      webViewDidFinishLoading fires inside %orig); content without markers → the engine
//      fully resets and the tweak stays passive;
//   2) webViewDidFinishLoading → boot: JS rebuilds <body> into per-line divs + CSS;
//   3) a 0.25 s timer: currentTime → binary search for the active line → JS toggles the
//      .now class (soft glow) and smoothly scrolls _scrollView.

#define LS_DEBUG 0

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>

// ============================================================
// Logging: LS_DEBUG 1 — verbose log to /var/log/syslog
// (filter: grep LyricSync /var/log/syslog), 0 — complete silence.
// LS_ERR is always active: it fires only on real failures.
// ============================================================
#if LS_DEBUG
  #define LS_LOG(fmt, ...) NSLog(@"[LyricSync] " fmt, ##__VA_ARGS__)
#else
  #define LS_LOG(fmt, ...) do {} while (0)
#endif
#define LS_ERR(fmt, ...) NSLog(@"[LyricSync][ERR] " fmt, ##__VA_ARGS__)

// ============================================================
// Private classes (not declared in the public SDK headers)
// ============================================================
@interface MPTextView : UIView
@end

@interface MPWebDocumentView : UIView
- (void)setContentWithString:(NSString *)string stylesheet:(NSString *)stylesheet;
- (id)webView; // the underlying WebView (WebKit), supports stringByEvaluatingJavaScriptFromString:
@end

@interface WebView : UIView
- (NSString *)stringByEvaluatingJavaScriptFromString:(NSString *)script;
@end

@interface MPAVController : NSObject
+ (id)sharedInstance;
- (double)currentTime;
@end

// Private WebKit functions (iOS 6 legacy WebKit, they live in WebCore): synchronize
// the main thread with the WebThread. Without WebThreadLock — probabilistic SIGTRAP in WebCore.
extern "C" void WebThreadLock(void);
extern "C" void WebThreadUnlock(void);

// Safe JS evaluation on the underlying WebView (main thread only)
static NSString *LSEvalJS(id webView, NSString *script) {
    NSString *ret = nil;
    @try {
        WebThreadLock();
        ret = [(WebView *)webView stringByEvaluatingJavaScriptFromString:script];
    } @catch (NSException *ex) {
        LS_ERR(@"LSEvalJS: %@", ex);
    } @finally {
        WebThreadUnlock();
    }
    return ret;
}

// Cached playback-controller class (hot path — used on every tick)
static Class LSAVControllerClass(void) {
    static Class c = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = objc_getClass("MPAVController"); });
    return c;
}

// ============================================================
// Utilities
// ============================================================

// Read an ivar by name (no KVC surprises)
static id LSObjectIvar(id obj, const char *name) {
    if (!obj) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return nil;
    return object_getIvar(obj, iv);
}

// Binary search: the last index i with times[i] <= t (or -1)
static NSInteger LSIndexForTime(NSArray *times, double t) {
    if (times.count == 0) return -1;
    if (t < [times[0] doubleValue]) return -1;
    NSUInteger lo = 0, hi = times.count;
    while (lo + 1 < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if ([times[mid] doubleValue] <= t) lo = mid; else hi = mid;
    }
    return (NSInteger)lo;
}

// LRC header regex: [mm:ss] / [mm:ss.xx] / [mm:ss.xxx] (anchored to ^)
static NSRegularExpression *LSTimeRegex(void) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [[NSRegularExpression alloc]
              initWithPattern:@"^\\[\\s*(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\s*\\]"
              options:0 error:NULL];
    });
    return re;
}

// Escape a string for embedding into a JS literal ("...")
static NSString *LSEscapeJS(NSString *s) {
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '\\': [out appendString:@"\\\\"]; break;
            case '"':  [out appendString:@"\\\""]; break;
            case '\'': [out appendString:@"\\'"]; break;
            case '\n': [out appendString:@"\\n"]; break;
            case '\r': [out appendString:@"\\r"]; break;
            case '\t': [out appendString:@"\\t"]; break;
            default:
                if (c < 32) [out appendFormat:@"\\u%04x", c];
                else [out appendFormat:@"%C", c];
        }
    }
    return out;
}

// ============================================================
// CSS + JS
// ============================================================
// Native iOS 6 skeuomorphism: the active line is pure white with a SINGLE soft glow
// (slide-to-unlock style), no pill/background/border. All lines share one font size so
// the layout never relayouts (the main source of jank); transitions only on
// color/text-shadow (cheap repaint without reflow).
static NSString * const kLSCSS =
    @"body { padding: 18px 10px 14px; font: 14px \".Helvetica NeueUI\"; font-weight: bold; "
    @"text-align: center; line-height: 130%; letter-spacing: 95%; color: #ffffff; width: 290px; word-wrap: break-word; background: transparent; }"
    @".ls-line { color: rgba(255,255,255,0.65); padding: 4px 8px; margin: 2px 0; "
    @"-webkit-transition: color .25s ease-out, text-shadow .25s ease-out; }"
    @".ls-line.past { color: rgba(255,255,255,0.30); text-shadow: none; }"
    @".ls-line.now { color: #ffffff; text-shadow: 0 0 8px rgba(255,255,255,0.45); }";

// __ls_set(i): toggles classes and returns "N:offset" — N = number of .ls-line divs
// (DOM health check), offset = offsetTop of the active line minus 85.
// Special cases: "0:-1" — no divs; "N:-1" — before the first line; "-2:-2" — JS error.
// __ls_count(): just the div count — a cheap DOM health probe.
static NSString * const kLSJS =
    @"function __ls_set(i){"
    @"try{"
    @"var els=document.getElementsByClassName('ls-line');var n=els.length;"
    @"if(n==0)return '0:-1';"
    @"if(i>=n)i=n-1;"
    @"for(var k=0;k<n;k++){var c='ls-line';"
    @"if(i>=0){if(k<i)c+=' past';else if(k==i)c+=' now';}"
    @"if(els[k].className!=c)els[k].className=c;}"
    @"if(i<0)return n+':-1';"
    @"return n+':'+(els[i].offsetTop-85);"
    @"}catch(e){return '-2:-2';}}"
    @"function __ls_count(){"
    @"try{return document.getElementsByClassName('ls-line').length}"
    @"catch(e){return -2}}";

// ============================================================
// LRC parsing from plain text
// ============================================================
// Input: raw lyrics text (lines separated by \n; fallback — <br>, if HTML arrives).
// Each line has leading [mm:ss.xx] markers and the text.
// End-marker lines (a marker with no text) are dropped.
//
// Output via out-parameters: times (NSArray<NSNumber*>, seconds) and texts (NSArray<NSString*>).
// Returns YES if at least 2 synchronized lines were collected.
static BOOL LSParseLRCFromText(NSString *rawText, NSArray **outTimes, NSArray **outTexts) {
    if (!rawText || rawText.length == 0) return NO;

    NSMutableString *norm = [NSMutableString stringWithString:rawText];
    [norm replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0, norm.length)];
    [norm replaceOccurrencesOfString:@"\r" withString:@"\n" options:0 range:NSMakeRange(0, norm.length)];

    NSArray *parts = nil;
    if ([norm rangeOfString:@"\n"].location != NSNotFound) {
        parts = [norm componentsSeparatedByString:@"\n"];
    } else {
        // In case the content arrived as HTML with <br> after all
        [norm replaceOccurrencesOfString:@"<br/>" withString:@"\n" options:0 range:NSMakeRange(0, norm.length)];
        [norm replaceOccurrencesOfString:@"<br />" withString:@"\n" options:0 range:NSMakeRange(0, norm.length)];
        [norm replaceOccurrencesOfString:@"<br>" withString:@"\n" options:0 range:NSMakeRange(0, norm.length)];
        parts = [norm componentsSeparatedByString:@"\n"];
    }

    NSMutableArray *times = [NSMutableArray array];
    NSMutableArray *texts = [NSMutableArray array];
    NSRegularExpression *re = LSTimeRegex();

    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *seg = [parts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (seg.length == 0) continue;

        // Consume the leading time markers (normally a single one)
        double firstTime = -1.0;
        NSUInteger markerCount = 0;
        while (YES) {
            NSTextCheckingResult *m = [re firstMatchInString:seg options:0 range:NSMakeRange(0, seg.length)];
            if (!m || m.range.location != 0) break;
            double mm = [[seg substringWithRange:[m rangeAtIndex:1]] doubleValue];
            double ss = [[seg substringWithRange:[m rangeAtIndex:2]] doubleValue];
            double frac = 0.0;
            if ([m rangeAtIndex:3].location != NSNotFound) {
                NSString *fs = [seg substringWithRange:[m rangeAtIndex:3]];
                frac = [fs doubleValue] / pow(10.0, (double)fs.length);
            }
            if (markerCount == 0) firstTime = mm * 60.0 + ss + frac;
            markerCount++;
            seg = [[seg substringFromIndex:m.range.length]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }

        if (firstTime >= 0.0 && seg.length > 0) {
            [times addObject:@(firstTime)];
            [texts addObject:seg];
        }
    }

    if (times.count < 2) return NO;

    if (outTimes) *outTimes = times;
    if (outTexts) *outTexts = texts;
    return YES;
}

// ============================================================
// Sync engine
// ============================================================
@interface LSSyncEngine : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSArray *lineTimes;   // NSNumber (double, seconds), document order
@property (nonatomic, strong) NSArray *lineTexts;   // line texts
@property (nonatomic, weak)   id    lastWebDocView; // MPWebDocumentView holding our lyrics
@property (nonatomic, weak)   id    activeTextView; // MPTextView
@property (nonatomic, assign) NSInteger currentIndex;
@property (nonatomic, assign) BOOL bootDone;        // DOM rebuilt for the current content
@property (nonatomic, assign) BOOL jsErrorLogged;   // anti-spam for JS errors
@property (nonatomic, assign) BOOL isVisible;       // lyrics currently on screen
@property (nonatomic, assign) NSTimeInterval verifyUntil; // DOM health check deadline
@property (nonatomic, assign) NSUInteger bootAttempts;    // boot attempt budget per content
+ (instancetype)shared;
- (void)noteContentReplacedWithWebDocView:(id)wv times:(NSArray *)times texts:(NSArray *)texts;
- (void)invalidateContent:(NSString *)reason;
- (void)viewDidMoveToSuperview:(id)tv;
- (void)didFinishLoadingForTextView:(id)tv;
- (void)stopTimer:(NSString *)reason;
- (void)bootIfReady;
- (NSInteger)currentIdxForTime:(double)t;
- (void)tick;
- (void)applyIndex:(NSInteger)idx animated:(BOOL)animated;
@end

@implementation LSSyncEngine

+ (instancetype)shared {
    static LSSyncEngine *e = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ e = [[LSSyncEngine alloc] init]; });
    return e;
}

- (void)noteContentReplacedWithWebDocView:(id)wv times:(NSArray *)times texts:(NSArray *)texts {
    self.lastWebDocView = wv;
    self.lineTimes = times;
    self.lineTexts = texts;
    self.currentIndex = -1;
    self.bootDone = NO;
    self.jsErrorLogged = NO;
    self.verifyUntil = 0.0;
    self.bootAttempts = 0;
    [self startTimer];
}

// Content without LRC markers (or a reset) — the engine fully steps aside:
// no data, no boot, no timer; the stock code renders as usual.
- (void)invalidateContent:(NSString *)reason {
    self.lastWebDocView = nil;
    self.lineTimes = nil;
    self.lineTexts = nil;
    self.currentIndex = -1;
    self.bootDone = NO;
    self.jsErrorLogged = NO;
    self.verifyUntil = 0.0;
    self.bootAttempts = 0;
    [self stopTimer:reason];
}

- (void)viewDidMoveToSuperview:(id)tv {
    UIView *sup = [tv superview];
    if (sup) {
        self.isVisible = YES;
        self.activeTextView = tv;
        // Timer and highlighting only when there is sync data
        if (self.lineTimes.count > 0) {
            [self startTimer];
            // The view is back in the hierarchy with the DOM already built — apply the
            // highlight immediately
            if (self.bootDone) {
                double t = [[LSAVControllerClass() sharedInstance] currentTime];
                NSInteger idx = [self currentIdxForTime:t];
                self.currentIndex = idx;
                [self applyIndex:idx animated:NO];
            }
        }
    } else {
        self.isVisible = NO;
        self.activeTextView = nil;
        [self stopTimer:@"superview==nil"];
    }
}

- (void)didFinishLoadingForTextView:(id)tv {
    self.activeTextView = tv;
    if (self.lineTimes.count == 0 || !self.lastWebDocView) return;

    // Rebuild the DOM into our markup (once per content)
    [self bootIfReady];

    // Initial highlight placement without animation
    double t = [[LSAVControllerClass() sharedInstance] currentTime];
    NSInteger idx = [self currentIdxForTime:t];
    self.currentIndex = idx;
    [self applyIndex:idx animated:NO];
}

- (void)startTimer {
    if (self.timer) return;
    self.timer = [NSTimer timerWithTimeInterval:0.25
                                         target:self
                                       selector:@selector(tick)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)stopTimer:(NSString *)reason {
    if (!self.timer) return;
    [self.timer invalidate];
    self.timer = nil;
}

- (NSInteger)currentIdxForTime:(double)t {
    return LSIndexForTime(self.lineTimes, t);
}

- (void)tick {
    // No sync data — the tweak is fully passive
    if (self.lineTimes.count == 0) return;

    // Boot also happens off-screen: pre-warm the DOM before the flip
    if (!self.bootDone) {
        if (self.bootAttempts < 12) [self bootIfReady];
        if (!self.bootDone) return;
    }

    // Off-screen: no JS calls; the highlight is applied by the resync on flip
    if (!self.isVisible) return;

    // Verification window: the WebKit web thread may asynchronously wipe our DOM
    // (deferred plain-text assembly) within the first ~2 s after the load. A cheap
    // __ls_count() probe (~1 ms) every 0.25 s for 3 s after the boot.
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (self.verifyUntil > 0.0) {
        if (now > self.verifyUntil) {
            self.verifyUntil = 0.0; // window closed, DOM is stable
        } else {
            id wv = self.lastWebDocView;
            id web = wv ? [(MPWebDocumentView *)wv webView] : nil;
            if (web) {
                NSString *ret = LSEvalJS(web, @"__ls_count()");
                int n = ret.intValue;
                if (n != (int)self.lineTexts.count && n != -2) {
                    // DOM wiped — rebuild (bootAttempts bounds the loop)
                    self.bootDone = NO;
                    if (self.bootAttempts < 12) [self bootIfReady];
                    if (self.bootDone) {
                        self.currentIndex = [self currentIdxForTime:
                            [[LSAVControllerClass() sharedInstance] currentTime]];
                        [self applyIndex:self.currentIndex animated:YES];
                    }
                    return;
                }
            }
        }
    }

    double t = [[LSAVControllerClass() sharedInstance] currentTime];
    NSInteger idx = [self currentIdxForTime:t];

    if (idx != self.currentIndex) {
        self.currentIndex = idx;
        [self applyIndex:idx animated:YES];
    }
}

// DOM rebuild: body → per-line divs + our CSS + the __ls_set/__ls_count functions.
- (void)bootIfReady {
    if (self.bootDone) return;
    if (self.lineTimes.count == 0) return; // no data — do not interfere
    id wv = self.lastWebDocView;
    if (!wv) return;
    id web = nil;
    @try { web = [(MPWebDocumentView *)wv webView]; }
    @catch (NSException *ex) { LS_ERR(@"boot: webView threw %@", ex); return; }
    if (!web) return;

    self.bootAttempts++;

    NSMutableString *js = [NSMutableString stringWithCapacity:8192];
    [js appendString:@"(function(){try{var L=["];
    for (NSUInteger i = 0; i < self.lineTexts.count; i++) {
        [js appendFormat:@"\"%@\",", LSEscapeJS(self.lineTexts[i])];
    }
    if (self.lineTexts.count > 0) {
        [js deleteCharactersInRange:NSMakeRange(js.length - 1, 1)];
    }
    [js appendString:@"];"];
    [js appendFormat:@"var st=document.createElement('style');st.textContent=\"%@\";document.head.appendChild(st);",
        LSEscapeJS(kLSCSS)];
    [js appendString:
        @"var b=document.body;b.innerHTML='';"
        @"for(var i=0;i<L.length;i++){var d=document.createElement('div');"
        @"d.className='ls-line';d.id='ls'+i;d.textContent=L[i];b.appendChild(d);}"
        @"}catch(e){return 'BOOT-ERR:'+e;}})()"];
    [js appendString:@";"];
    [js appendString:kLSJS];
    [js appendString:@";document.getElementsByClassName('ls-line').length"];

    NSString *ret = LSEvalJS(web, js);
    if (ret && [ret hasPrefix:@"BOOT-ERR"]) {
        LS_ERR(@"boot: JS rebuild failed: %@", ret);
        return;
    }
    // Boot succeeded only if the div count matches the line count exactly
    if (ret.intValue == (int)self.lineTexts.count) {
        self.bootDone = YES;
        // DOM health verification window (async web-thread re-assembly)
        self.verifyUntil = [[NSDate date] timeIntervalSince1970] + 3.0;
    }
}

- (void)applyIndex:(NSInteger)idx animated:(BOOL)animated {
    id wv = self.lastWebDocView;
    id web = nil;
    @try { web = [(MPWebDocumentView *)wv webView]; }
    @catch (NSException *ex) { LS_ERR(@"applyIndex: webView threw %@", ex); return; }
    if (!web) return;

    NSString *js = [NSString stringWithFormat:@"__ls_set(%ld)", (long)idx];
    NSString *ret = LSEvalJS(web, js);

    if (ret == nil) {
        if (!self.jsErrorLogged) {
            LS_ERR(@"JS bridge returned nil (scripts disabled? __ls_set undefined?)");
            self.jsErrorLogged = YES;
        }
        return;
    }

    // "N:offset" format: N doubles as the DOM health check
    NSArray *parts = [ret componentsSeparatedByString:@":"];
    int domCount = parts.count > 0 ? [parts[0] intValue] : -2;
    int target = parts.count > 1 ? [parts[1] intValue] : -2;

    if (domCount == -2) {
        if (!self.jsErrorLogged) {
            LS_ERR(@"JS: exception inside __ls_set (ret=%@)", ret);
            self.jsErrorLogged = YES;
        }
        return;
    }

    // Self-healing: the DOM was wiped by the stock content — rebuild and retry
    if (domCount != (int)self.lineTexts.count) {
        self.bootDone = NO;
        if (self.bootAttempts < 12) [self bootIfReady];
        if (!self.bootDone) return;
        ret = LSEvalJS(web, js);
        parts = [ret componentsSeparatedByString:@":"];
        domCount = parts.count > 0 ? [parts[0] intValue] : -2;
        target = parts.count > 1 ? [parts[1] intValue] : -2;
        if (domCount != (int)self.lineTexts.count) return;
    }

    if (idx < 0) return;    // before the first line — classes already cleared, no scrolling
    if (target < 0) return; // line at the very top — no scrolling needed

    id tv = self.activeTextView;
    UIScrollView *sv = (UIScrollView *)LSObjectIvar(tv, "_scrollView");
    if (!sv) return;

    CGSize cs = sv.contentSize;
    CGSize bs = sv.bounds.size;

    CGFloat maxOff = cs.height - bs.height;
    if (maxOff < 0) maxOff = 0;
    CGFloat off = target;
    if (off > maxOff) off = maxOff;
    if (off < 0) off = 0;

    // Never steal scrolling from the user
    if (sv.isDragging || sv.isDecelerating) return;

    [UIView animateWithDuration:0.35
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [(UIScrollView *)sv setContentOffset:CGPointMake(0, off) animated:NO]; }
                     completion:nil];
}

@end

// ============================================================
// Hooks
// ============================================================

%hook MPTextView

// Lyrics appear/disappear from the hierarchy — start/stop the timer here
- (void)didMoveToSuperview {
    %orig;
    [[LSSyncEngine shared] viewDidMoveToSuperview:self];
}

// Content finished loading into WebKit — rebuild the DOM and place the highlight
- (void)webViewDidFinishLoading:(id)fv {
    %orig;
    [[LSSyncEngine shared] didFinishLoadingForTextView:self];
}

// Lyrics removed (artwork flipped back) — stop the timer
- (void)_removeTextUI {
    [[LSSyncEngine shared] stopTimer:@"_removeTextUI"];
    %orig;
}

%end

%hook MPWebDocumentView

// LRC detection happens here; the content is NOT replaced (the input is plain text —
// HTML would get escaped), the DOM rebuild happens in webViewDidFinishLoading via the
// JS bridge.
- (void)setContentWithString:(NSString *)string stylesheet:(NSString *)stylesheet {
    NSArray *times = nil, *texts = nil;
    BOOL isLRC = LSParseLRCFromText(string, &times, &texts);

    if (!isLRC) {
        // Plain (or already ours) text — stock rendering; reset the engine so the
        // tweak never touches songs without LRC markers
        [[LSSyncEngine shared] invalidateContent:@"content without LRC markers"];
        %orig;
        return;
    }

    // IMPORTANT: the data goes to the engine BEFORE %orig — the WebKit load is
    // synchronous and webViewDidFinishLoading (and therefore boot) fires inside %orig.
    [[LSSyncEngine shared] noteContentReplacedWithWebDocView:self times:times texts:texts];

    %orig;
}

%end

// ============================================================
// Initialization
// ============================================================
%ctor {
    %init;
}
