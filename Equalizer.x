#import "YTLite.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <MediaToolbox/MediaToolbox.h>

// ── Shared EQ state (UI thread writes, audio thread reads) ────────────────────

static float gYTLGains[5]  = {0, 0, 0, 0, 0};  // dB, -12..+12
static BOOL  gYTLEQEnabled  = NO;

static const float kBandFreqs[5] = {60.0f, 230.0f, 910.0f, 4000.0f, 14000.0f};
static NSString * const kGainsKey   = @"ytlEQGains";
static NSString * const kEnabledKey = @"ytlEQEnabled";

static void YTLEQLoadDefaults(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    gYTLEQEnabled = [d boolForKey:kEnabledKey];
    NSArray *saved = [d arrayForKey:kGainsKey];
    for (int i = 0; i < 5; i++)
        gYTLGains[i] = (saved.count == 5) ? [saved[i] floatValue] : 0.0f;
}

// ── Per-tap context ───────────────────────────────────────────────────────────

typedef struct {
    AudioUnit eqUnit;
    AudioBufferList *inputBuf;   // temp buffer fed to EQ render callback
    UInt32 numChannels;
    UInt32 bytesPerChannel;      // bytes per channel per max-frames block
    BOOL ready;
} YTLTapCtx;

static OSStatus EQInputCallback(void *inRefCon,
                                 AudioUnitRenderActionFlags *ioActionFlags,
                                 const AudioTimeStamp *inTimeStamp,
                                 UInt32 inBusNumber,
                                 UInt32 inNumberFrames,
                                 AudioBufferList *ioData) {
    YTLTapCtx *ctx = (YTLTapCtx *)inRefCon;
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        UInt32 src = (b < ctx->inputBuf->mNumberBuffers) ? b : 0;
        UInt32 bytes = MIN(ioData->mBuffers[b].mDataByteSize,
                           ctx->inputBuf->mBuffers[src].mDataByteSize);
        memcpy(ioData->mBuffers[b].mData,
               ctx->inputBuf->mBuffers[src].mData, bytes);
    }
    return noErr;
}

// ── MTAudioProcessingTap callbacks ───────────────────────────────────────────

static void TapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    YTLTapCtx *ctx = calloc(1, sizeof(YTLTapCtx));
    *tapStorageOut = ctx;
}

static void TapFinalize(MTAudioProcessingTapRef tap) {
    YTLTapCtx *ctx = (YTLTapCtx *)MTAudioProcessingTapGetStorage(tap);
    if (!ctx) return;
    if (ctx->eqUnit) {
        AudioUnitUninitialize(ctx->eqUnit);
        AudioComponentInstanceDispose(ctx->eqUnit);
    }
    if (ctx->inputBuf) {
        for (UInt32 b = 0; b < ctx->inputBuf->mNumberBuffers; b++)
            free(ctx->inputBuf->mBuffers[b].mData);
        free(ctx->inputBuf);
    }
    free(ctx);
}

static void TapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                       const AudioStreamBasicDescription *fmt) {
    YTLTapCtx *ctx = (YTLTapCtx *)MTAudioProcessingTapGetStorage(tap);
    if (!ctx) return;

    ctx->numChannels = fmt->mChannelsPerFrame;
    UInt32 bytesPerFrame = fmt->mBytesPerFrame > 0 ? fmt->mBytesPerFrame : 4;
    ctx->bytesPerChannel = (UInt32)maxFrames * bytesPerFrame;

    // Allocate temp input buffer (one buffer per channel, non-interleaved)
    ctx->inputBuf = calloc(1, sizeof(AudioBufferList) +
                              (ctx->numChannels - 1) * sizeof(AudioBuffer));
    ctx->inputBuf->mNumberBuffers = ctx->numChannels;
    for (UInt32 c = 0; c < ctx->numChannels; c++) {
        ctx->inputBuf->mBuffers[c].mNumberChannels = 1;
        ctx->inputBuf->mBuffers[c].mDataByteSize   = ctx->bytesPerChannel;
        ctx->inputBuf->mBuffers[c].mData           = malloc(ctx->bytesPerChannel);
    }

    // Create NBandEQ AudioUnit
    AudioComponentDescription desc = {
        .componentType         = kAudioUnitType_Effect,
        .componentSubType      = kAudioUnitSubType_NBandEQ,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &ctx->eqUnit) != noErr) return;

    UInt32 numBands = 5;
    AudioUnitSetProperty(ctx->eqUnit, kAUNBandEQProperty_NumberOfBands,
                         kAudioUnitScope_Global, 0, &numBands, sizeof(numBands));

    AudioUnitSetProperty(ctx->eqUnit, kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input, 0, fmt, sizeof(*fmt));
    AudioUnitSetProperty(ctx->eqUnit, kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Output, 0, fmt, sizeof(*fmt));

    AURenderCallbackStruct cb = { .inputProc = EQInputCallback, .inputProcRefCon = ctx };
    AudioUnitSetProperty(ctx->eqUnit, kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0, &cb, sizeof(cb));

    for (UInt32 i = 0; i < 5; i++) {
        AudioUnitSetParameter(ctx->eqUnit, kAUNBandEQParam_EQType + i,
                              kAudioUnitScope_Global, 0, kAUNBandEQFilterType_Parametric, 0);
        AudioUnitSetParameter(ctx->eqUnit, kAUNBandEQParam_Frequency + i,
                              kAudioUnitScope_Global, 0, kBandFreqs[i], 0);
        AudioUnitSetParameter(ctx->eqUnit, kAUNBandEQParam_Bandwidth + i,
                              kAudioUnitScope_Global, 0, 1.0f, 0);
        AudioUnitSetParameter(ctx->eqUnit, kAUNBandEQParam_Gain + i,
                              kAudioUnitScope_Global, 0, 0.0f, 0);
        AudioUnitSetParameter(ctx->eqUnit, kAUNBandEQParam_BypassBand + i,
                              kAudioUnitScope_Global, 0, 0.0f, 0);
    }

    if (AudioUnitInitialize(ctx->eqUnit) == noErr)
        ctx->ready = YES;
}

static void TapUnprepare(MTAudioProcessingTapRef tap) {
    YTLTapCtx *ctx = (YTLTapCtx *)MTAudioProcessingTapGetStorage(tap);
    if (!ctx || !ctx->eqUnit) return;
    AudioUnitUninitialize(ctx->eqUnit);
    AudioComponentInstanceDispose(ctx->eqUnit);
    ctx->eqUnit = NULL;
    ctx->ready  = NO;
}

static void TapProcess(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                       MTAudioProcessingTapFlags flags,
                       AudioBufferList *bufferListInOut,
                       CMItemCount *numberFramesOut,
                       MTAudioProcessingTapFlags *flagsOut) {
    MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                       flagsOut, NULL, numberFramesOut);

    YTLTapCtx *ctx = (YTLTapCtx *)MTAudioProcessingTapGetStorage(tap);
    if (!ctx || !ctx->ready || !gYTLEQEnabled) return;

    // Update gains from shared state (UI thread writes atomically enough for audio)
    for (UInt32 i = 0; i < 5; i++) {
        AudioUnitSetParameter(ctx->eqUnit, kAUNBandEQParam_Gain + i,
                              kAudioUnitScope_Global, 0, gYTLGains[i], 0);
    }

    // Copy source audio to temp input buffer for the render callback
    for (UInt32 b = 0; b < bufferListInOut->mNumberBuffers; b++) {
        UInt32 dst = (b < ctx->numChannels) ? b : ctx->numChannels - 1;
        UInt32 bytes = MIN(bufferListInOut->mBuffers[b].mDataByteSize,
                           ctx->inputBuf->mBuffers[dst].mDataByteSize);
        memcpy(ctx->inputBuf->mBuffers[dst].mData,
               bufferListInOut->mBuffers[b].mData, bytes);
        ctx->inputBuf->mBuffers[dst].mDataByteSize = bytes;
    }

    // Render through EQ; output overwrites bufferListInOut in-place
    AudioUnitRenderActionFlags renderFlags = 0;
    AudioTimeStamp ts = {0};
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    AudioUnitRender(ctx->eqUnit, &renderFlags, &ts,
                    0, (UInt32)*numberFramesOut, bufferListInOut);
}

// ── Inject tap into AVPlayerItem ─────────────────────────────────────────────

static void YTLInjectTap(AVPlayerItem *item) {
    MTAudioProcessingTapCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version    = kMTAudioProcessingTapCallbacksVersion_0;
    callbacks.init       = TapInit;
    callbacks.finalize   = TapFinalize;
    callbacks.prepare    = TapPrepare;
    callbacks.unprepare  = TapUnprepare;
    callbacks.process    = TapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                               kMTAudioProcessingTapCreationFlag_PostEffects,
                                               &tap);
    if (err != noErr || !tap) return;

    // kCMPersistentTrackID_Invalid applies to all audio tracks
    AVMutableAudioMixInputParameters *params = [AVMutableAudioMixInputParameters audioMixInputParameters];
    params.audioTapProcessor = tap;
    CFRelease(tap);

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = @[params];
    item.audioMix = mix;
}

%hook AVPlayerItem
- (instancetype)initWithAsset:(AVAsset *)asset {
    self = %orig;
    if (self) YTLInjectTap(self);
    return self;
}
- (instancetype)initWithURL:(NSURL *)URL {
    self = %orig;
    if (self) YTLInjectTap(self);
    return self;
}
%end

// ── Settings UI ───────────────────────────────────────────────────────────────

@interface YTLEqualizerViewController : UIViewController
@end

@implementation YTLEqualizerViewController {
    UISwitch    *_enableSwitch;
    UISlider    *_sliders[5];
    UILabel     *_valLabels[5];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    YTLEQLoadDefaults();

    self.title = @"Equalizer";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Close button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(close)];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:scroll];

    UIStackView *stack = [UIStackView new];
    stack.axis      = UILayoutConstraintAxisVertical;
    stack.spacing   = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    CGFloat pad = 20;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:pad],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:pad],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-pad],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-pad],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-2*pad],
    ]];

    // Enable toggle row
    UIView *toggleRow = [UIView new];
    toggleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [toggleRow.heightAnchor constraintEqualToConstant:44].active = YES;

    UILabel *enableLabel = [UILabel new];
    enableLabel.text = @"EQ Enabled";
    enableLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    enableLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [toggleRow addSubview:enableLabel];

    _enableSwitch = [UISwitch new];
    _enableSwitch.on = gYTLEQEnabled;
    _enableSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [_enableSwitch addTarget:self action:@selector(toggleEQ:) forControlEvents:UIControlEventValueChanged];
    [toggleRow addSubview:_enableSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [enableLabel.centerYAnchor constraintEqualToAnchor:toggleRow.centerYAnchor],
        [enableLabel.leadingAnchor constraintEqualToAnchor:toggleRow.leadingAnchor],
        [_enableSwitch.centerYAnchor constraintEqualToAnchor:toggleRow.centerYAnchor],
        [_enableSwitch.trailingAnchor constraintEqualToAnchor:toggleRow.trailingAnchor],
    ]];
    [stack addArrangedSubview:toggleRow];

    // Separator
    UIView *sep = [UIView new];
    sep.backgroundColor = [UIColor separatorColor];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [sep.heightAnchor constraintEqualToConstant:1].active = YES;
    [stack addArrangedSubview:sep];

    // 5 band sliders
    NSArray *labels = @[@"60 Hz", @"230 Hz", @"910 Hz", @"4 kHz", @"14 kHz"];
    for (int i = 0; i < 5; i++) {
        UIView *row = [self makeBandRow:i label:labels[i]];
        [stack addArrangedSubview:row];
    }
}

- (UIView *)makeBandRow:(int)index label:(NSString *)label {
    UIView *row = [UIView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:56].active = YES;

    UILabel *freqLabel = [UILabel new];
    freqLabel.text = label;
    freqLabel.font = [UIFont systemFontOfSize:13];
    freqLabel.textColor = [UIColor secondaryLabelColor];
    freqLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [freqLabel.widthAnchor constraintEqualToConstant:58].active = YES;
    [row addSubview:freqLabel];

    UISlider *slider = [UISlider new];
    slider.minimumValue = -12;
    slider.maximumValue = 12;
    slider.value = gYTLGains[index];
    slider.tag = index;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [row addSubview:slider];
    _sliders[index] = slider;

    UILabel *valLabel = [UILabel new];
    valLabel.text = [NSString stringWithFormat:@"%+.0f dB", gYTLGains[index]];
    valLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    valLabel.textColor = [UIColor secondaryLabelColor];
    valLabel.textAlignment = NSTextAlignmentRight;
    valLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [valLabel.widthAnchor constraintEqualToConstant:52].active = YES;
    [row addSubview:valLabel];
    _valLabels[index] = valLabel;

    [NSLayoutConstraint activateConstraints:@[
        [freqLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [freqLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [slider.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [slider.leadingAnchor constraintEqualToAnchor:freqLabel.trailingAnchor constant:8],
        [slider.trailingAnchor constraintEqualToAnchor:valLabel.leadingAnchor constant:-8],
        [valLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
    ]];

    return row;
}

- (void)toggleEQ:(UISwitch *)sw {
    gYTLEQEnabled = sw.isOn;
    [[NSUserDefaults standardUserDefaults] setBool:sw.isOn forKey:kEnabledKey];
}

- (void)sliderChanged:(UISlider *)sl {
    int i = (int)sl.tag;
    float rounded = roundf(sl.value);
    sl.value = rounded;
    gYTLGains[i] = rounded;
    _valLabels[i].text = [NSString stringWithFormat:@"%+.0f dB", rounded];

    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:5];
    for (int j = 0; j < 5; j++) [arr addObject:@(gYTLGains[j])];
    [[NSUserDefaults standardUserDefaults] setObject:arr forKey:kGainsKey];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
