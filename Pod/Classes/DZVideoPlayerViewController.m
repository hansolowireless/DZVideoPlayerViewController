//
//  DZVideoPlayerViewController.m
//  OhMyTube
//
//  Created by Denis Zamataev on 29/05/15.
//  Copyright (c) 2015 Mysterious Organization. All rights reserved.
//

#import "DZVideoPlayerViewController.h"

static const NSString *ItemStatusContext;
static const NSString *PlayerRateContext;
static const NSString *PlayerStatusContext;
static const NSString *ItemLoadedRangesContext;
static const NSString *TimeControlStatusContext;
static const NSString *ExternalScreenContext;
static const NSString *StatusSeekContext;

@interface DZVideoPlayerViewController ()
{
    BOOL _isFullscreen;
    BOOL _isMuted;
}

@property (assign, nonatomic) BOOL isSeeking;
@property (assign, nonatomic) BOOL isControlsHidden;
@property (assign, nonatomic) CGRect initialFrame;
@property (strong, nonatomic) NSTimer *idleTimer;

// Player time observer target
@property (strong, nonatomic) id playerTimeObservationTarget;

// Remote command center targets
@property (strong, nonatomic) id playCommandTarget;
@property (strong, nonatomic) id pauseCommandTarget;

@property(nonatomic, strong) UILabel *airPlayMessageLabel;
@property(nonatomic, readwrite) CMTime chaseTime;
@property (assign, nonatomic) BOOL isSmoothlySeeking;
@property (assign, nonatomic) BOOL addedSeekObserver;
@property (assign, nonatomic) BOOL didInitialSeek;
@property (assign, nonatomic) NSTimeInterval initialPlayPosition;

@end

@implementation DZVideoPlayerViewController

+ (NSBundle *)bundle {
    NSBundle *bundle = [NSBundle bundleWithPath:[[NSBundle mainBundle]
                                                 pathForResource:@"DZVideoPlayerViewController"
                                                 ofType:@"bundle"]];
    return bundle;
}

+ (NSString *)nibNameForStyle:(DZVideoPlayerViewControllerStyle)style {
    NSString *nibName;
    NSString *classString = NSStringFromClass([DZVideoPlayerViewController class]);
    switch (style) {
        case DZVideoPlayerViewControllerStyleDefault:
            nibName = classString;
            break;
            
        case DZVideoPlayerViewControllerStyleSimple:
            nibName = [NSString stringWithFormat:@"%@_%@", classString, @"simple"];
            break;
            
        default:
            nibName = classString;
            break;
    }
    return nibName;
}

+ (DZVideoPlayerViewControllerConfiguration *)defaultConfiguration {
    DZVideoPlayerViewControllerConfiguration *configuration = [[DZVideoPlayerViewControllerConfiguration alloc] init];
    configuration.viewsToHideOnIdle = [NSMutableArray new];
    configuration.delayBeforeHidingViewsOnIdle = 3.0;
    configuration.isShowFullscreenExpandAndShrinkButtonsEnabled = YES;
    configuration.isHideControlsOnIdleEnabled = YES;
    configuration.isBackgroundPlaybackEnabled = YES;
    return configuration;
}

#pragma mark - Lifecycle

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];
    [self commonInit];
}

- (void)commonInit {
    self.configuration = [[self class] defaultConfiguration];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    if (self.topToolbarView) {
        [self.configuration.viewsToHideOnIdle addObject:self.topToolbarView];
    }
    if (self.bottomToolbarView) {
        [self.configuration.viewsToHideOnIdle addObject:self.bottomToolbarView];
    }
    
    self.initialFrame = self.view.frame;
    
    [self setupActions];
    [self setupNotifications];
    [self setupAudioSession];
    [self setupPlayer];
    [self setupRemoteCommandCenter];
    [self syncUI];
    
    self.bottomToolbarView.hidden = TRUE;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setupRemoteControlEvents];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)dealloc {
    [self resignNotifications];
    [self resignKVO];
    [self resignRemoteCommandCenter];
    [self resignPlayer];
    [self resetNowPlayingInfo];
}

#pragma mark - Properties

- (NSTimeInterval)availableDuration {
    NSTimeInterval result = 0;
    if( self.player != nil ) {
        NSArray *loadedTimeRanges = self.player.currentItem.loadedTimeRanges;
        
        if ([loadedTimeRanges count] > 0) {
            CMTimeRange timeRange = [[loadedTimeRanges objectAtIndex:0] CMTimeRangeValue];
            Float64 startSeconds = CMTimeGetSeconds(timeRange.start);
            Float64 durationSeconds = CMTimeGetSeconds(timeRange.duration);
            result = startSeconds + durationSeconds;
        }
    }
    
    return result;
}

- (NSTimeInterval)currentPlaybackTime {
    if( self.player != nil ) {
        CMTime time = self.player.currentTime;
        if (CMTIME_IS_VALID(time)) {
            return time.value / time.timescale;
        }
    }
    return 0;
}

- (NSTimeInterval)currentPlayerItemDuration
{
    NSTimeInterval currentPlayerItemDuration = 0.0;
    if (self.playerItem) {
        CMTime duration = self.playerItem.duration;
        if (CMTIME_IS_VALID(duration) && duration.timescale>0) {
            currentPlayerItemDuration = duration.value / duration.timescale;
        }
    }
    return currentPlayerItemDuration;
}

- (BOOL)isPlaying {
    if( self.player != nil ) {
        return [self.player rate] > 0.0f;
    }
    else {
        return NO;
    }
}

- (BOOL)isFullscreen {
    return _isFullscreen;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)isMuted {
    if( self.player != nil ) {
        _isMuted = self.player.muted;
    }
    return _isMuted;
}

- (void)setMuted:(BOOL)muted {
    _isMuted = muted;
    if( self.player != nil ) {
        self.player.muted = _isMuted;
        _isMuted = self.player.muted;
    }
}

#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
}


#pragma mark - Public Actions

- (void)prepareAndPlayAutomatically:(BOOL)playAutomatically withAsset: (AVURLAsset *)videoAsset andInitialPlayPosition:(NSTimeInterval)playPosition {
    
    [self.activityIndicatorView startAnimating];
    
    if (self.player) {
        [self stop];
    }
    
    if (self.playerItem) {
        [self.playerItem removeObserver:self forKeyPath:@"status" context:&ItemStatusContext];
    }
  
//    self.asset = [[AVURLAsset alloc] initWithURL:self.videoURL options:nil];
    self.asset = videoAsset;
    self.initialPlayPosition = playPosition;
    NSString *playableKey = @"playable";
    [_asset loadValuesAsynchronouslyForKeys:@[playableKey] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *error;
            AVKeyValueStatus status = [_asset statusOfValueForKey:playableKey error:&error];
            
            if (status == AVKeyValueStatusLoaded) {
                self.playerItem = [AVPlayerItem playerItemWithAsset:_asset];
                // ensure that this is done before the playerItem is associated with the player
                [self.playerItem addObserver:self forKeyPath:@"status"
                                     options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew
                                     context:&ItemStatusContext];

                if( self.player != nil ) {
                    self.player.usesExternalPlaybackWhileExternalScreenIsActive = YES;
                    self.player.allowsExternalPlayback = YES;
                   [self.player replaceCurrentItemWithPlayerItem:self.playerItem];
                }
                else {
                   [self setupPlayer];
                }
                
  //              if (playAutomatically) {
  //                  [self play];
  //              }
            }
            else {
                // You should deal with the error appropriately.
                NSLog(@"Error, the asset is not playable: %@", error);
                [self onFailedToLoadAssetWithError:error];
            }
        });
        
    }];
}

- (void)play {
    if( self.player != nil ) {
        [self.player play];
    }
    [self startIdleCountdown];
    [self syncUI];
    [self onPlay];
    [self updateNowPlayingInfo];
}

- (void)pause {
    if( self.player != nil ) {
        [self.player pause];
    }
    [self stopIdleCountdown];
    [self syncUI];
    [self onPause];
    [self updateNowPlayingInfo];
}

- (void)togglePlayPause {
    if ([self isPlaying]) {
        [self pause];
    }
    else {
        [self play];
    }
}

- (void)stop {
    if( self.player != nil ) {
        [self.player pause];
        [self.player seekToTime:kCMTimeZero];
    }
    [self stopIdleCountdown];
    [self syncUI];
    [self onStop];
    [self updateNowPlayingInfo];
}

- (void)syncUI {
    if ([self isPlaying]) {
        self.playButton.hidden = YES;
        self.playButton.enabled = NO;
        
        self.pauseButton.hidden = NO;
        self.pauseButton.enabled = YES;
    }
    else {
        self.playButton.hidden = NO;
        self.playButton.enabled = YES;
        
        self.pauseButton.hidden = YES;
        self.pauseButton.enabled = NO;
    }
    
    if (self.configuration.isShowFullscreenExpandAndShrinkButtonsEnabled) {
        if (self.isFullscreen) {
            self.fullscreenExpandButton.hidden = YES;
            self.fullscreenExpandButton.enabled = NO;
            
            self.fullscreenShrinkButton.hidden = NO;
            self.fullscreenShrinkButton.enabled = YES;
        }
        else {
            self.fullscreenExpandButton.hidden = NO;
            self.fullscreenExpandButton.enabled = YES;
            
            self.fullscreenShrinkButton.hidden = YES;
            self.fullscreenShrinkButton.enabled = NO;
        }
    }
    else {
        self.fullscreenExpandButton.hidden = YES;
        self.fullscreenExpandButton.enabled = NO;
        
        self.fullscreenShrinkButton.hidden = YES;
        self.fullscreenShrinkButton.enabled = NO;
    }
    
}

- (void)toggleFullscreen:(id)sender {
    _isFullscreen = !_isFullscreen;
    [self onToggleFullscreen];
    [self syncUI];
    [self startIdleCountdown];
}

- (void)seek:(UISlider *)slider {
    if( self.playerItem != nil ) {
        int timescale = self.playerItem.asset.duration.timescale;
        if( timescale > 0 ) {
            float time = slider.value * (self.playerItem.asset.duration.value / timescale);
            if( self.player != nil ) {
                [self.player seekToTime:CMTimeMakeWithSeconds(time, timescale)];
            }
        }
    }
}

- (void)seekToTime:(NSTimeInterval)newPlaybackTime {
    if( self.playerItem != nil ) {
        int timescale = 1;
        if(
           [self playerItem] != nil
           && [[self playerItem] asset] != nil
           )
        {
            timescale = self.playerItem.asset.duration.timescale;
        }
        if( self.player != nil ) {
            [self.player seekToTime:CMTimeMakeWithSeconds(newPlaybackTime, timescale)];
        }
    }
}

- (void)startSeeking:(id)sender {
    [self stopIdleCountdown];
    self.isSeeking = YES;
}

- (void)endSeeking:(id)sender {
    [self updateNowPlayingInfo];
    [self startIdleCountdown];
    self.isSeeking = NO;
}

//Seek safely to time. Added 31/05/2017 by Guillermo
- (void)stopPlayingAndSeekSmoothlyToTime:(CMTime)newChaseTime
{
    //Hide bottom toolbar
    if (!_isSeeking) {
        if (CMTIME_COMPARE_INLINE(newChaseTime, !=, self->_chaseTime))
        {
            self->_chaseTime = newChaseTime;
            
            if (!self->_isSmoothlySeeking)
                [self trySeekToChaseTime];
        }
    }
}

- (void)trySeekToChaseTime
{

    [self actuallySeekToTime];

//    if (_player.rate != 0)
//    {
//        [self actuallySeekToTime];
//    }
//    else if (!_isSeeking)
//    {
//        // wait until item becomes ready (KVO player.currentItem.status)
//        [self.player addObserver:self forKeyPath:@"rate"
//                             options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:&StatusSeekContext];
//        _addedSeekObserver = YES;
//    }
}

- (void)actuallySeekToTime
{
    self->_isSmoothlySeeking = YES;
    CMTime seekTimeInProgress = self->_chaseTime;
    [self->_player seekToTime:seekTimeInProgress toleranceBefore:kCMTimeZero
              toleranceAfter:kCMTimeZero completionHandler:
     ^(BOOL isFinished)
     {
         if (_addedSeekObserver == YES) {
             [self.player removeObserver:self forKeyPath:@"rate" context:&StatusSeekContext];
             _addedSeekObserver = NO;
         }
         if (CMTIME_COMPARE_INLINE(seekTimeInProgress, ==, self->_chaseTime)) {
             self->_isSmoothlySeeking = NO;
             [self pause];
             self->_didInitialSeek = YES;
             [self displayBottomBar:TRUE];
         }
         else
             [self trySeekToChaseTime];
     }];
}
//////

- (void)updateProgressIndicator:(id)sender {
    CGFloat duration = CMTimeGetSeconds(self.playerItem.asset.duration);
    
    if (duration == 0 || isnan(duration)) {
        // Video is a live stream
        self.progressIndicator.hidden = YES;
        [self.currentTimeLabel setText:nil];
        [self.remainingTimeLabel setText:nil];
    }
    else {
        self.progressIndicator.hidden = NO;
        
        CGFloat current;
        if ( self.isSeeking ) {
            current = self.progressIndicator.value * duration;
        }
        else if( self.player != nil ) {
            // Otherwise, use the actual video position
            current = CMTimeGetSeconds(self.player.currentTime);
        }
        else {
            current = self.progressIndicator.value * duration;
        }
        
        CGFloat left = duration - current;
        
        [self.progressIndicator setValue:(current / duration)];
        [self.progressIndicator setSecondaryValue:([self availableDuration] / duration)];
        
        // Set time labels
        
        NSString *currentTimeString = current > 0 ? [self stringFromTimeInterval:current] : @"00:00";
        NSString *remainingTimeString = left > 0 ? [self stringFromTimeInterval:left] : @"00:00";
        
        [self.currentTimeLabel setText:currentTimeString];
        [self.remainingTimeLabel setText:[NSString stringWithFormat:@"-%@", remainingTimeString]];
        self.currentTimeLabel.hidden = NO;
        self.remainingTimeLabel.hidden = NO;
    }
}

- (void)startIdleCountdown {
    if (self.idleTimer) {
        [self.idleTimer invalidate];
    }
    if (self.configuration.isHideControlsOnIdleEnabled) {
        self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:self.configuration.delayBeforeHidingViewsOnIdle
                                                          target:self selector:@selector(hideControls)
                                                        userInfo:nil repeats:NO];
    }
}

- (void)stopIdleCountdown {
    if (self.idleTimer) {
        [self.idleTimer invalidate];
    }
}

- (void)hideControls {
    [self hideControlsWithAnimationDuration:0.3f];
}
- (void)hideControlsWithAnimationDuration:(NSTimeInterval)animationDuration {
    NSArray *views = self.configuration.viewsToHideOnIdle;
    if( animationDuration <= 0 )
    {
        for (UIView *view in views) {
            view.alpha = 0.0;
        }
    }
    else
    {
        [UIView animateWithDuration:0.3f animations:^{
            for (UIView *view in views) {
                view.alpha = 0.0;
            }
        }];
    }
    self.isControlsHidden = YES;
}

- (void)showControls {
    [self showControlsWithAnimationDuration:0.3f];
}
- (void)showControlsWithAnimationDuration:(NSTimeInterval)animationDuration {
    NSArray *views = self.configuration.viewsToHideOnIdle;
    if( animationDuration <= 0 )
    {
        for (UIView *view in views) {
            view.alpha = 1.0;
        }
    }
    else
    {
        [UIView animateWithDuration:animationDuration animations:^{
            for (UIView *view in views) {
                view.alpha = 1.0;
            }
        }];
    }
    self.isControlsHidden = NO;
}

- (void)toggleControls {
    if (self.isControlsHidden) {
        [self showControls];
    }
    else {
        [self hideControls];
    }
    [self stopIdleCountdown];
    if (!self.isControlsHidden) {
        [self startIdleCountdown];
    }
}

- (void) displayBottomBar: (BOOL) show {
    dispatch_async(dispatch_get_main_queue(),
                   ^{
                       self.bottomToolbarView.hidden = !show;
                   });
}

- (void)updateNowPlayingInfo {
    NSMutableDictionary *nowPlayingInfo = [self gatherNowPlayingInfo];
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nowPlayingInfo;
}

- (void)resetNowPlayingInfo {
    [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = nil;
}

- (NSMutableDictionary *)gatherNowPlayingInfo {
    NSMutableDictionary *nowPlayingInfo = [[NSMutableDictionary alloc] init];
    if( self.player != nil ) {
        [nowPlayingInfo setObject:[NSNumber numberWithDouble:self.player.rate] forKey:MPNowPlayingInfoPropertyPlaybackRate];
    }
    else
    {
        [nowPlayingInfo setObject:[NSNumber numberWithDouble:(self.isPlaying?1.0:0.0)] forKey:MPNowPlayingInfoPropertyPlaybackRate];
    }
    [nowPlayingInfo setObject:[NSNumber numberWithDouble:self.currentPlaybackTime] forKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
    [self onGatherNowPlayingInfo:nowPlayingInfo];
    return nowPlayingInfo;
}

#pragma mark - Private Actions

- (void)setupPlayer {
    if ( self.playerItem != nil ) {
        self.player = [[AVPlayer alloc] initWithPlayerItem:self.playerItem];
        // self.player = [[AVQueuePlayer alloc] initWithItems:@[self.playerItem,[[AVPlayerItem alloc] initWithAsset:[AVAsset assetWithURL:[self videoURL]]]]];
    }
    else {
        self.player = [[AVPlayer alloc] initWithPlayerItem:nil];
        // self.player = [[AVQueuePlayer alloc] initWithPlayerItem:nil];
    }
    
    self.player.usesExternalPlaybackWhileExternalScreenIsActive = YES;
    self.player.allowsExternalPlayback = YES;
    
    [self setMuted:_isMuted];
    
    [self.player addObserver:self forKeyPath:@"rate"
                     options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:&PlayerRateContext];
    
    [self.player addObserver:self forKeyPath:@"status"
                     options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:&PlayerStatusContext];
    
    //Added Test
    if ([AVPlayer instancesRespondToSelector:@selector(timeControlStatus)]) {
        [self.player addObserver:self forKeyPath:@"timeControlStatus"
                         options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:&TimeControlStatusContext];
    }
    //Added for smoothly seeking
    _addedSeekObserver = NO;
    
    [self.player addObserver:self forKeyPath:@"externalPlaybackActive"
                     options:NSKeyValueObservingOptionInitial|NSKeyValueObservingOptionNew context:&ExternalScreenContext];

    DZVideoPlayerViewController __weak *welf = self;
    self.playerTimeObservationTarget = [self.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 1)  queue:nil usingBlock:^(CMTime time) {
        [welf updateProgressIndicator:welf];
        [welf syncUI];
    }];
    
    self.playerView.player = self.player;
    self.playerView.videoFillMode = AVLayerVideoGravityResizeAspect;
    
}

- (void)resignPlayer {
    [self.player removeTimeObserver:self.playerTimeObservationTarget];
    self.playerTimeObservationTarget = nil;
}

- (void)setupAudioSession {
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    
    NSError *setCategoryError = nil;
    BOOL success = [audioSession setCategory:AVAudioSessionCategoryPlayback error:&setCategoryError];
    
    if (!success) {[self onFailedToLoadAssetWithError:setCategoryError]; /* handle the error condition */}
    
    NSError *activationError = nil;
    success = [audioSession setActive:YES error:&activationError];
    if (!success) { [self onFailedToLoadAssetWithError:setCategoryError]; /* handle the error condition */ }
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAVAudioSessionInterruptionNotification:)
                                                 name:AVAudioSessionInterruptionNotification
                                               object:audioSession];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAVAudioSessionRouteChangeNotification:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:audioSession];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAVAudioSessionMediaServicesWereLostNotification:)
                                                 name:AVAudioSessionMediaServicesWereLostNotification
                                               object:audioSession];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAVAudioSessionMediaServicesWereResetNotification:)
                                                 name:AVAudioSessionMediaServicesWereResetNotification
                                               object:audioSession];
}

- (void)setupRemoteControlEvents {
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    [self becomeFirstResponder];
}

- (void)setupActions {
    UITapGestureRecognizer *tapGR = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleControls)];
    [self.playerView addGestureRecognizer:tapGR];
    
    [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
    [self.pauseButton addTarget:self action:@selector(pause) forControlEvents:UIControlEventTouchUpInside];
    
    [self.fullscreenShrinkButton addTarget:self action:@selector(toggleFullscreen:) forControlEvents:UIControlEventTouchUpInside];
    [self.fullscreenExpandButton addTarget:self action:@selector(toggleFullscreen:) forControlEvents:UIControlEventTouchUpInside];
    
    [self.progressIndicator addTarget:self action:@selector(seek:) forControlEvents:UIControlEventValueChanged];
    [self.progressIndicator addTarget:self action:@selector(startSeeking:) forControlEvents:UIControlEventTouchDown];
    [self.progressIndicator addTarget:self action:@selector(endSeeking:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    
    [self.doneButton addTarget:self action:@selector(onDoneButtonTouched) forControlEvents:UIControlEventTouchUpInside];
}

- (void)resignKVO {
    if( self.playerItem != nil ) {
        [self.playerItem removeObserver:self forKeyPath:@"status" context:&ItemStatusContext];
    }
    if( self.player != nil ) {
        [self.player removeObserver:self forKeyPath:@"rate" context:&PlayerRateContext];
        [self.player removeObserver:self forKeyPath:@"status" context:&PlayerStatusContext];
        if ([AVPlayer instancesRespondToSelector:@selector(timeControlStatus)]) {
            [self.player removeObserver:self forKeyPath:@"timeControlStatus" context:&TimeControlStatusContext];
        }
        [self.player removeObserver:self forKeyPath:@"externalPlaybackActive" context:&ExternalScreenContext];
    }
}

- (void)setupRemoteCommandCenter {
    DZVideoPlayerViewController __weak *welf = self;
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    self.playCommandTarget = [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [welf play];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
    self.pauseCommandTarget = [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        [welf pause];
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

- (void)resignRemoteCommandCenter {
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    [commandCenter.playCommand removeTarget:self.playCommandTarget];
    [commandCenter.pauseCommand removeTarget:self.pauseCommandTarget];
    self.playCommandTarget = nil;
    self.pauseCommandTarget = nil;
}

- (void)setupNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAVPlayerItemDidPlayToEndTime:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAVPlayerItemFailedToPlayToEndTime:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAVPlayerItemPlaybackStalled:)
                                                 name:AVPlayerItemPlaybackStalledNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleApplicationDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (void)resignNotifications {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemPlaybackStalledNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil];
}

#pragma mark - Helpers

- (NSString *)stringFromTimeInterval:(NSTimeInterval)time {
    NSString *string = [NSString stringWithFormat:@"%02li:%02li:%02li",
                        lround(floor(time / 3600.)) % 100,
                        lround(floor(time / 60.)) % 60,
                        lround(floor(time)) % 60];
    
    NSString *extraZeroes = @"00:";
    
    if ([string hasPrefix:extraZeroes]) {
        string = [string substringFromIndex:extraZeroes.length];
    }
    
    return string;
}

#pragma mark - Notification Handlers

- (void)handleAVPlayerItemDidPlayToEndTime:(NSNotification *)notification {
    [self stop];
    [self onDidPlayToEndTime];
}

- (void)handleAVPlayerItemFailedToPlayToEndTime:(NSNotification *)notification {
    [self stop];
    [self onFailedToPlayToEndTime];
}

- (void)handleAVPlayerItemPlaybackStalled:(NSNotification *)notification {
    [self pause];
    [self.activityIndicatorView startAnimating];
    [self onPlaybackStalled];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    if (self.configuration.isBackgroundPlaybackEnabled) {
        self.playerView.player = nil;
    }
}

- (void)handleApplicationDidBecomeActive:(NSNotification *)notification {
    if (self.configuration.isBackgroundPlaybackEnabled) {
        self.playerView.player = self.player;
    }
}

- (void)handleAVAudioSessionInterruptionNotification:(NSNotification *)notification {
    
}

- (void)handleAVAudioSessionRouteChangeNotification:(NSNotification *)notification {
    
}

- (void)handleAVAudioSessionMediaServicesWereLostNotification:(NSNotification *)notification {
    
}

- (void)handleAVAudioSessionMediaServicesWereResetNotification:(NSNotification *)notification {
    
}

#pragma mark - Remote Control Events

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    //if it is a remote control event handle it correctly
    if (event.type == UIEventTypeRemoteControl) {
        if (event.subtype == UIEventSubtypeRemoteControlPlay) {
            [self play];
        } else if (event.subtype == UIEventSubtypeRemoteControlPause) {
            [self pause];
        } else if (event.subtype == UIEventSubtypeRemoteControlTogglePlayPause) {
            [self togglePlayPause];
        } else if (event.subtype == UIEventSubtypeRemoteControlNextTrack) {
            [self onRequireNextTrack];
        } else if (event.subtype == UIEventSubtypeRemoteControlPreviousTrack) {
            [self onRequirePreviousTrack];
        }
    }
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == &ItemStatusContext) {

        if (self.player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
            [self.activityIndicatorView stopAnimating];
 
//            if (self.didInitialSeek == NO) {
//                dispatch_async(dispatch_get_main_queue(),
//                               ^{
//                                   self.bottomToolbarView.hidden = FALSE;
//                               });
//                [self play];
//            }
//            else {
//                self.didInitialSeek = NO;
//            }
            
            if (self.initialPlayPosition != 0 && _asset != nil) {
                CMTimeScale timeScale = _asset.duration.timescale;
                CMTime vodPlayPositionCMTime = CMTimeMakeWithSeconds(self.initialPlayPosition, timeScale);
                [self stopPlayingAndSeekSmoothlyToTime:vodPlayPositionCMTime];
            }
            else {
                [self displayBottomBar:TRUE];
                [self play];
            }
        }
        else if (self.player.currentItem.status == AVPlayerItemStatusFailed) {
            [self.activityIndicatorView stopAnimating];
            [self onFailedToLoadAssetWithError:self.player.currentItem.error];
        }
        dispatch_async(dispatch_get_main_queue(),
                       ^{
                           [self syncUI];
                       });
    }
    else if (context == &PlayerRateContext) {
        float rate = [change[NSKeyValueChangeNewKey] floatValue];
        //        dispatch_async(dispatch_get_main_queue(),
        //                       ^{
        //                           if (rate > 0) {
        //                               [self.activityIndicatorView stopAnimating];
        //                           }
        //                       });
        
    }
    else if (context == &PlayerStatusContext) {
        //        AVPlayerStatus status = [change[NSKeyValueChangeNewKey] integerValue];
        dispatch_async(dispatch_get_main_queue(),
                       ^{
                           [self syncUI];
                       });
    }
    else if (context == &TimeControlStatusContext) {
        if ([AVPlayer instancesRespondToSelector:@selector(timeControlStatus)]) {
            NSLog(@"Player Status waiting because %@", self.player.reasonForWaitingToPlay);
        }
    }
    else if (context == &ExternalScreenContext) {
        if (self.player.externalPlaybackActive == YES) {
            dispatch_async(dispatch_get_main_queue(),
                           ^{
                               self.airPlayMessageLabel = [[UILabel alloc] initWithFrame:CGRectMake(100, 100, 120, 30)];
                               self.airPlayMessageLabel.text = @"El contenido se está reproduciendo por Airplay";
                               self.airPlayMessageLabel.textColor = [UIColor whiteColor];
                               self.airPlayMessageLabel.backgroundColor = [UIColor clearColor];
                               self.airPlayMessageLabel.sizeToFit;
                               [self.airPlayMessageLabel setCenter: self.playerView.center];
                               [self.playerView addSubview:self.airPlayMessageLabel];
                               [self.playerView bringSubviewToFront:self.airPlayMessageLabel];
                               NSLog(@"airplay label ADDED");
                           });
        }
        else {
            dispatch_async(dispatch_get_main_queue(),
                           ^{
                               [self.airPlayMessageLabel removeFromSuperview];
                               self.airPlayMessageLabel = nil;
                               NSLog(@"airplay label REMOVED");
                           });
        }
    }
    else if (context == &StatusSeekContext) {
//        if (_player.currentItem.status == AVPlayerItemStatusReadyToPlay) {
//            [self trySeekToChaseTime];
//        }
        if (_player.rate != 0) {
            [self trySeekToChaseTime];
        }
    }
    else {
        // Make sure to call the superclass's implementation in the else block in case it is also implementing KVO
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Delegate invocations

- (void)onFailedToLoadAssetWithError:(NSError*)error {
    if ([self.delegate respondsToSelector:@selector(playerFailedToLoadAssetWithError:)]) {
        [self.delegate playerFailedToLoadAssetWithError:error];
    }
}

- (void)onPlay {
    if ([self.delegate respondsToSelector:@selector(playerDidPlay)]) {
        [self.delegate playerDidPlay];
    }
}

- (void)onPause {
    if ([self.delegate respondsToSelector:@selector(playerDidPause)]) {
        [self.delegate playerDidPause];
    }
}

- (void)onStop {
    if ([self.delegate respondsToSelector:@selector(playerDidStop)]) {
        [self.delegate playerDidStop];
    }
}

- (void)onDidPlayToEndTime {
    if ([self.delegate respondsToSelector:@selector(playerDidPlayToEndTime)]) {
        [self.delegate playerDidPlayToEndTime];
    }
}

- (void)onFailedToPlayToEndTime {
    if ([self.delegate respondsToSelector:@selector(playerFailedToPlayToEndTime)]) {
        [self.delegate playerFailedToPlayToEndTime];
    }
}

- (void)onRequireNextTrack {
    if ([self.delegate respondsToSelector:@selector(playerRequireNextTrack)]) {
        [self.delegate playerRequireNextTrack];
    }
}

- (void)onRequirePreviousTrack {
    if ([self.delegate respondsToSelector:@selector(playerRequirePreviousTrack)]) {
        [self.delegate playerRequirePreviousTrack];
    }
}

- (void)onToggleFullscreen {
    if ([self.delegate respondsToSelector:@selector(playerDidToggleFullscreen)]) {
        [self.delegate playerDidToggleFullscreen];
    }
}

- (void)onPlaybackStalled {
    if ([self.delegate respondsToSelector:@selector(playerPlaybackStalled)]) {
        [self.delegate playerPlaybackStalled];
    }
}

- (void)onGatherNowPlayingInfo:(NSMutableDictionary *)nowPlayingInfo {
    if ([self.delegate respondsToSelector:@selector(playerGatherNowPlayingInfo:)]) {
        [self.delegate playerGatherNowPlayingInfo:nowPlayingInfo];
    }
}

- (void)onDoneButtonTouched {
    if ([self.delegate respondsToSelector:@selector(playerDoneButtonTouched)]) {
        [self.delegate playerDoneButtonTouched];
    }
}

@end
