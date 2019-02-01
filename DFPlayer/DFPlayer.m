//
//  DFPlayer.m
//  DFPlayer
//
//  Created by ihoudf on 2017/7/18.
//  Copyright © 2017年 ihoudf. All rights reserved.
//

#import "DFPlayer.h"
#import "DFPlayerFileManager.h"
#import "DFPlayerResourceLoader.h"
#import "DFPlayerTool.h"
#import "DFPlayerRemoteApplication.h"
/**类型KEY*/
NSString * const DFPlayerModeKey                = @"DFPlayerMode";
/**Asset KEY*/
NSString * const DFPlayableKey                  = @"playable";
/**PlayerItem KEY*/
//NSString * const DFRateKey                      = @"rate";
NSString * const DFStatusKey                    = @"status";
NSString * const DFLoadedTimeRangesKey          = @"loadedTimeRanges";
NSString * const DFPlaybackBufferEmptyKey       = @"playbackBufferEmpty";
NSString * const DFPlaybackLikelyToKeepUpKey    = @"playbackLikelyToKeepUp";

#define DFPlayerHighGlobalQueue dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)
#define DFPlayerDefaultGlobalQueue dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)
@interface DFPlayer()<DFPlayerResourceLoaderDelegate>
{
    BOOL _isOthetPlaying; // 其他应用是否正在播放
    BOOL _isBackground; // 是否进入后台
    BOOL _isCached; // 当前音频是否缓存
    BOOL _isPlaying; // 是否正在播放
    BOOL _isDraged; // 是否拖拽进度条
    BOOL _isSeekWaiting; // seek 等待
    BOOL _isNaturalToEndTime; // 是否是自然结束
    BOOL _isSettingPreviousAudioModel; // 配置历史音频信息标记
    dispatch_group_t _netGroupQueue; // 组队列-网络
    dispatch_group_t _dataGroupQueue; // 组队列-数据
    NSInteger _currentAudioId; // 当前正在播放的音频Id
    NSInteger _randomIndex; // 随机数组元素index
    NSInteger _playIndex1; // 播放顺序标识
    NSInteger _playIndex2; // 播放顺序标识
    CGFloat _seekValue; // seek value
}
/**player*/
@property (nonatomic, strong) AVPlayer          *player;
/**playerItem*/
@property (nonatomic, strong) AVPlayerItem      *playerItem;
/**播放进度监测*/
@property (nonatomic, strong) id                timeObserver;
/**随机数组*/
@property (nonatomic, strong) NSMutableArray    *randomIndexArray;
/**音频信息model*/
@property (nonatomic, strong) DFPlayerInfoModel                 *currentAudioInfoModel;
/**历史model*/
@property (nonatomic, strong) DFPlayerPreviousAudioModel        *previousAudioModel;
/**资源下载器*/
@property (nonatomic, strong) DFPlayerResourceLoader            *resourceLoader;
/**model数据数组*/
@property (nonatomic, strong) NSMutableArray<DFPlayerModel *>   *playerModelArray;

@end

@implementation DFPlayer

#pragma mark - 初始化
+ (DFPlayer *)shareInstance {
    static DFPlayer *instance = nil;
    static dispatch_once_t predicate;
    dispatch_once(&predicate, ^{
        instance = [[[self class] alloc] init];
    });
    return instance;
}
- (void)dealloc{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 初始化播放器
- (void)df_initPlayerWithUserId:(NSString *)userId{
    //记录用户
    [self initPlayerCachePathWithUserId:userId];

    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategorySoloAmbient error:nil];
    
    _isOthetPlaying = [AVAudioSession sharedInstance].otherAudioPlaying;
    
    NSInteger user_playerMode = [[NSUserDefaults standardUserDefaults] integerForKey:DFPlayerModeKey];
    self.playMode = user_playerMode?user_playerMode:DFPlayerModeSingleCycle;
    self.state = DFPlayerStateStopped;
    self.isObserveProgress          = YES;
    self.isObserveBufferProgress    = YES;
    self.isNeedCache                = YES;
    self.isRemoteControl            = YES;
    self.isManualToPlay             = YES;
    self.isObserveFileModifiedTime  = NO;
    self.isHeadPhoneAutoPlay        = NO;
    self.isObserveWWAN              = NO;
    _randomIndex    = -1;
    _playIndex2     = 0;
    _isCached       = NO;
    _isBackground   = NO;

    //添加观察者
    [self addPlayerObserver];
}

#pragma mark - 监测网络 监听播放结束 耳机插拔 播放器被打断
- (void)addPlayerObserver{
    _netGroupQueue      = dispatch_group_create();
    _dataGroupQueue     = dispatch_group_create();
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_group_enter(self->_netGroupQueue);
    });
    dispatch_group_async(_netGroupQueue, DFPlayerDefaultGlobalQueue, ^{
        [[DFPlayerTool sharedTool] startMonitoringNetworkStatus:^{
            static dispatch_once_t onceToken1;
            dispatch_once(&onceToken1, ^{
                dispatch_group_leave(self->_netGroupQueue);
            });
        }];
    });
    
    //将要进入后台
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    [notificationCenter addObserver:self
                           selector:@selector(df_playerWillResignActive)
                               name:UIApplicationWillResignActiveNotification
                             object:nil];
    //已经进入前台
    [notificationCenter addObserver:self
                           selector:@selector(df_playerDidEnterForeground)
                               name:UIApplicationDidBecomeActiveNotification
                             object:nil];
    //监测耳机
    [notificationCenter addObserver:self
                           selector:@selector(df_playerAudioRouteChange:)
                               name:AVAudioSessionRouteChangeNotification
                             object:nil];
    //监听播放器被打断（别的软件播放音乐，来电话）
    [notificationCenter addObserver:self
                           selector:@selector(df_playerAudioBeInterrupted:)
                               name:AVAudioSessionInterruptionNotification
                             object:[AVAudioSession sharedInstance]];
    //监测其他app是否占据AudioSession
    [notificationCenter addObserver:self
                           selector:@selector(df_playerSecondaryAudioHint:)
                               name:AVAudioSessionSilenceSecondaryAudioHintNotification
                             object:nil];
    //播放
     [notificationCenter addObserver:self
                            selector:@selector(audioPrePlayToLoadPreviousAudio)
                                name:DFPlayerCurrentAudioInfoModelPlayNotiKey
                              object:nil];
}
- (void)df_playerDidEnterForeground{ _isBackground = NO; }
- (void)df_playerWillResignActive{ _isBackground = YES; }

- (void)df_playerAudioRouteChange:(NSNotification *)notification {
    NSInteger routeChangeReason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] integerValue];
    switch (routeChangeReason) {
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable://耳机插入
            if (self.delegate && [self.delegate respondsToSelector:@selector(df_player:isHeadphone:)]) {
                [self.delegate df_player:self isHeadphone:YES];
            }else{
                if (self.isHeadPhoneAutoPlay && self.currentAudioModel) {
                    [self df_audioPlay];
                }
            }
            break;
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable://耳机拔出，停止播放操作
            if (self.delegate && [self.delegate respondsToSelector:@selector(df_player:isHeadphone:)]) {
                [self.delegate df_player:self isHeadphone:NO];
            }else{
                [self df_audioPause];
            }
            break;
        case AVAudioSessionRouteChangeReasonCategoryChange:
            //
            break;
        default:
            break;
    }
}

- (void)df_playerAudioBeInterrupted:(NSNotification *)notification {
    NSDictionary *dic = notification.userInfo;
    if ([dic[AVAudioSessionInterruptionTypeKey] integerValue] == 1) {//打断开始
        NSLog(@"-- DFPlayer： 音频被打断开始，并记录了播放信息");
        [self df_setPreviousAudioModel];//打断时也要记录信息
        if (self.delegate && [self.delegate respondsToSelector:@selector(df_player:isInterrupted:)]) {
            [self.delegate df_player:self isInterrupted:YES];
        }else{
            [self df_audioPause];
        }
    }else {//打断结束
        NSLog(@"-- DFPlayer： 音频被打断结束");
        if (self.delegate && [self.delegate respondsToSelector:@selector(df_player:isInterrupted:)]) {
            [self.delegate df_player:self isInterrupted:NO];
        }else{
            if ([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] == 1) {
                NSLog(@"-- DFPlayer： 能够恢复播放");
                [self df_audioPlay];
            }
        }
    }
}

- (void)df_playerSecondaryAudioHint:(NSNotification *)notification{
    NSInteger type = [notification.userInfo[AVAudioSessionSilenceSecondaryAudioHintTypeKey] integerValue];
    if (type == 1) {//开始被其他音频占据
        NSLog(@"-- DFPlayer： 其他音频占据开始");
    }else{//占据结束
        NSLog(@"-- DFPlayer： 其他音频占据结束");
    }
}

-(void)df_playerDidPlayToEndTime:(NSNotification *)notification{
    _isNaturalToEndTime = YES;
    [self df_audioNext];
    if (self.delegate && [self.delegate respondsToSelector:@selector(df_playerDidPlayToEndTime:)]) {
        [self.delegate df_playerDidPlayToEndTime:self];
    }
}


#pragma mark - 记录播放信息 和 配置播放器
- (BOOL)df_setPreviousAudioModel{
    BOOL isSuccess = NO;
    if (self.currentAudioModel) {
        isSuccess =
        [DFPlayerArchiverManager df_archiveInfoModelWithAudioUrl:self.currentAudioModel.audioUrl
                                                    currentTime:self.currentTime
                                                      totalTime:self.totalTime
                                                       progress:self.progress];
    }
    NSLog(@"-- DFPlayer： 播放信息保存%@",isSuccess ? @"成功" : @"失败");
    return isSuccess;
}
/** 用previousAudioModel配置播放器数据*/
- (BOOL)df_setPlayerWithPreviousAudioModel{
    self.previousAudioModel = [[DFPlayerPreviousAudioModel alloc] init];
    if (self.previousAudioModel.audioUrlAbsoluteString) {
        __block BOOL isHave = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        dispatch_group_notify(_dataGroupQueue, DFPlayerHighGlobalQueue, ^{
            isHave = [self setPlayerWithPreviousAudioModel];
            dispatch_semaphore_signal(semaphore);
        });
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        if (!isHave) {
            NSLog(@"-- DFPlayer： 当前数据源中不存在此数据，无法配置");
            [self df_playerStatusWithStatusCode:DFPlayerStatus_SetPreviousAudioModelError];
        }
        return isHave ? YES : NO;
    }else{
        NSLog(@"-- DFPlayer： 无可配置的历史音频url");
        [self df_playerStatusWithStatusCode:DFPlayerStatus_SetPreviousAudioModelError];
        return NO;
    }
}

/**配置历史音频信息*/
- (BOOL)setPlayerWithPreviousAudioModel{
    __block BOOL isHave = NO;
    [self.playerModelArray enumerateObjectsWithOptions:(NSEnumerationConcurrent) usingBlock:^(DFPlayerModel * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        //判断数据源中是否有previousAudioModel中的url
        NSString *audioUrlString = self.previousAudioModel.audioUrlAbsoluteString;
        NSURL *audioUrl = [NSURL URLWithString:audioUrlString];
        if ([DFPlayerTool isLocalAudio:audioUrl]) {
            if ([audioUrlString isEqualToString:obj.audioUrl.absoluteString.lastPathComponent]) {
                audioUrlString = [audioUrlString stringByRemovingPercentEncoding];
                NSString *path = [[NSBundle mainBundle] pathForResource:audioUrlString ofType:@""];
                if (path) {
                    isHave = YES;
                    NSURL *url = [NSURL fileURLWithPath:path];
                    [self setCurrentAudioModelWithPreviousAudioModelUrl:url audioId:idx];
                }
                *stop = YES;
            }
        }else{
            if ([audioUrlString isEqualToString:obj.audioUrl.absoluteString]) {
                isHave = YES;
                NSURL *url = [NSURL URLWithString:audioUrlString];
                [self setCurrentAudioModelWithPreviousAudioModelUrl:url audioId:idx];
                *stop = YES;
            }
        }
    }];
    return isHave;
}

- (void)setCurrentAudioModelWithPreviousAudioModelUrl:(NSURL *)audioUrl audioId:(NSUInteger)audioId{
    _isSettingPreviousAudioModel = YES;
    self.currentAudioModel          = [[DFPlayerModel alloc] init];
    self.currentAudioModel.audioUrl = audioUrl;
    self.currentAudioModel.audioId  = audioId;
    _currentAudioId            = audioId;
    self.totalTime                  = self.previousAudioModel.totalTime;
    NSString *cacheFilePath = [DFPlayerFileManager df_isCachedWithAudioUrl:audioUrl];
    if (cacheFilePath || [DFPlayerTool isLocalAudio:audioUrl]) {
        self.progress = self.previousAudioModel.progress;
        self.currentTime = self.previousAudioModel.currentTime;
        self.bufferProgress = 1;
    }else{
        self.progress = self.bufferProgress = self.currentTime = .0f;
    }
    
    //获取音频信息
    [self audioPrePlayToResetAudio];
}

/**配置历史音频进度*/
- (void)setPlayerSeekTotimeWithPreviousAudioModel{
    if (_isSettingPreviousAudioModel) {
        _isSettingPreviousAudioModel = NO;
        WeakSelf
        [self.player seekToTime:CMTimeMake(floorf(self.totalTime * self.progress), 1)
                toleranceBefore:(CMTimeMake(1, 1))
                 toleranceAfter:(CMTimeMake(1, 1))
              completionHandler:^(BOOL finished) {
                  StrongSelf
                  if (finished) {
                      strongSelf->_isDraged = NO;
                  }
              }];
    }
}
#pragma mark - 数据源准备数据
/**刷新数据源数据*/
- (void)df_reloadData{
    if (self.dataSource && [self.dataSource respondsToSelector:@selector(df_playerModelArray)]) {
        if (!self.playerModelArray) {
            self.playerModelArray = [NSMutableArray array];
        }
        if (self.playerModelArray.count != 0) {
            [self.playerModelArray removeAllObjects];
        }
        WeakSelf
        dispatch_group_enter(_dataGroupQueue);
        dispatch_group_async(_dataGroupQueue, DFPlayerHighGlobalQueue, ^{
            dispatch_async(DFPlayerHighGlobalQueue, ^{
                StrongSelf
                [strongSelf.playerModelArray addObjectsFromArray:[strongSelf.dataSource df_playerModelArray]];

                //更新数据时更新audioId
                if (strongSelf.currentAudioModel.audioUrl) {
                    [strongSelf.playerModelArray enumerateObjectsWithOptions:(NSEnumerationConcurrent) usingBlock:^(DFPlayerModel * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                        if ([obj.audioUrl.absoluteString isEqualToString:self.currentAudioModel.audioUrl.absoluteString]) {
                            strongSelf.currentAudioModel.audioId = idx;
                            strongSelf->_currentAudioId = idx;
                            *stop = YES;
                        }
                    }];
                    //更新随机数组
                    [self updateRandomIndexArray];
                }
                dispatch_group_leave(strongSelf->_dataGroupQueue);
            });
        });
    }else{
        NSLog(@"-- DFPlayer：请实现df_playerModelArray数据源方法");
    }
}

/**选择audioId对应的音频开始播放*/
- (void)df_playerPlayWithAudioId:(NSUInteger)audioId{
    WeakSelf
    dispatch_group_notify(_dataGroupQueue, DFPlayerHighGlobalQueue, ^{
        StrongSelf
        if (strongSelf.playerModelArray.count > audioId) {
            strongSelf.currentAudioModel = strongSelf.playerModelArray[audioId];
            NSLog(@"-- DFPlayer： 点击了音频Id:%ld",(unsigned long)strongSelf.currentAudioModel.audioId);
            strongSelf->_currentAudioId = audioId;
            [strongSelf audioPrePlay];
        }else{
            [strongSelf df_playerStatusWithStatusCode:DFPlayerStatus_DataError];
        }
    });
}
#pragma mark - DFPlayerResourceLoaderDelegate
/**下载出错*/
- (void)loader:(DFPlayerResourceLoader *)loader requestError:(NSInteger)errorCode{
    if (errorCode == NSURLErrorTimedOut) {
        [self df_playerStatusWithStatusCode:DFPlayerStatus_RequestTimeOut];
    }else if ([DFPlayerTool sharedTool].networkStatus == DFPlayerNetworkStatusNotReachable) {
        [self df_playerStatusWithStatusCode:DFPlayerStatus_NetworkUnavailable];
    }
}
/**是否完成缓存*/
- (void)loader:(DFPlayerResourceLoader *)loader isCached:(BOOL)isCached{
    _isCached = isCached;
    NSUInteger status = isCached ? DFPlayerStatus_CacheSuccess : DFPlayerStatus_CacheFailure;
    [self df_playerStatusWithStatusCode:status];
}

#pragma mark - DFPLayer -资源准备 IMPORTANT
- (void)audioPrePlayToLoadPreviousAudio{
    if (_isSettingPreviousAudioModel) {
        [self audioPrePlayToLoadAudio];
    }
}
/**预播放*/
- (void)audioPrePlay{
    //移除进度观察者
    if (self.timeObserver) {
        [self.player removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
    //重置
    self.progress = self.bufferProgress = self.currentTime = self.totalTime = .0f;
    _isSeekWaiting  = NO;
    _isSettingPreviousAudioModel = NO;

    [self audioPrePlayToResetAudio];
    [self audioPrePlayToLoadAudio];
}
/**重置音频信息*/
- (void)audioPrePlayToResetAudio{
    //暂停播放
    if (_isPlaying) {
        [self df_audioPause];
    }
    //移除进度观察者
    if (self.timeObserver) {
        [self.player removeTimeObserver:self.timeObserver];
        self.timeObserver = nil;
    }
    //请求音频信息
    if (self.dataSource && [self.dataSource respondsToSelector:@selector(df_playerAudioInfoModel:)]) {
        self.currentAudioInfoModel = [self.dataSource df_playerAudioInfoModel:self];
    }
    //音频将要加入播放队列
    if (self.delegate && [self.delegate respondsToSelector:@selector(df_playerAudioWillAddToPlayQueue:)]) {
        [self.delegate df_playerAudioWillAddToPlayQueue:self];
    }
}

/**加载音频*/
- (void)audioPrePlayToLoadAudio{
    //音频地址安全性判断
    if (![self.currentAudioModel.audioUrl isKindOfClass:[NSURL class]]) {
        NSLog(@"-- DFPlayer:请传入NSURL类型音频地址");
        return;
    }
    
    if ([DFPlayerTool isLocalAudio:self.currentAudioModel.audioUrl]) {
        NSLog(@"-- DFPlayer： 播放本地音频");
        _isCached = YES;
        [self loadPlayerItemWithUrl:self.currentAudioModel.audioUrl];
    }else{
        NSString *cacheFilePath = [DFPlayerFileManager df_isCachedWithAudioUrl:self.currentAudioModel.audioUrl];
        NSLog(@"-- DFPlayer： 播放网络音频，是否有缓存：%@",cacheFilePath?@"有":@"无");
        _isCached = cacheFilePath ? YES : NO;
        [self loadPlayerItemWithUrl:self.currentAudioModel.audioUrl
                      cacheFilePath:cacheFilePath];
    }
}

- (void)loadPlayerItemWithUrl:(NSURL *)currentAudioUrl
                cacheFilePath:(NSString *)cacheFilePath{
    dispatch_group_notify(_netGroupQueue, DFPlayerDefaultGlobalQueue, ^{
        //如果监听WWAN，本地无缓存，网络状态是WWAN，三种情况同时存在时发起代理8
        DFPlayerTool *tool = [DFPlayerTool sharedTool];
        if (self.isObserveWWAN && !cacheFilePath &&
            tool.networkStatus == DFPlayerNetworkStatusReachableViaWWAN){
            [self df_playerStatusWithStatusCode:DFPlayerStatus_NetworkViaWWAN];
        }else{
            //加载音频
            if (tool.networkStatus == DFPlayerNetworkStatusUnknown ||
                tool.networkStatus == DFPlayerNetworkStatusNotReachable)
            {//无网络
                if (cacheFilePath){//无网络 有缓存，播放缓存
                    [self loadPlayerItemWithUrl:[NSURL fileURLWithPath:cacheFilePath]];
                }else{//无网络 无缓存，提示联网
                    [self df_playerStatusWithStatusCode:DFPlayerStatus_NetworkUnavailable];
                }
            }else{//有网络
                if (!self.isNeedCache){//不需要缓存
                    [self loadPlayerItemWithUrl:currentAudioUrl];
                }else{//需要缓存
                    if (cacheFilePath && !self.isObserveFileModifiedTime) {//有缓存且不监听改变时间，直接播放缓存
                        [self loadPlayerItemWithUrl:[NSURL fileURLWithPath:cacheFilePath]];
                    }else{//无缓存 或 需要兼听
                        [self loadNetAudioWithUrl:currentAudioUrl
                                    cacheFilePath:cacheFilePath];
                    }
                }
            }
        }
    });
}

- (void)loadNetAudioWithUrl:(NSURL *)currentAudioUrl cacheFilePath:(NSString *)cacheFilePath{
    if (self.resourceLoader) {
        [self.resourceLoader stopLoading];
    }
    self.resourceLoader = [[DFPlayerResourceLoader alloc] init];
    self.resourceLoader.delegate = self;
    NSURL *customUrl = [DFPlayerTool customUrlWithUrl:currentAudioUrl];
    if (!customUrl) {
        [self df_playerStatusWithStatusCode:DFPlayerStatus_UnavailableURL];return;
    }
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:customUrl options:nil];
    [asset.resourceLoader setDelegate:self.resourceLoader queue:dispatch_get_main_queue()];
    [asset loadValuesAsynchronouslyForKeys:@[DFPlayableKey] completionHandler:^{
        dispatch_async( dispatch_get_main_queue(),^{
            if (!asset.playable) {
                [self.resourceLoader stopLoading];
                self.state = DFPlayerStateFailed;
                [asset cancelLoading];
            }
        });
    }];
    self.resourceLoader.isHaveCache = _isCached;
    self.resourceLoader.isObserveFileModifiedTime = self.isObserveFileModifiedTime;
    
    WeakSelf
    self.resourceLoader.checkStatusBlock = ^(NSInteger statusCode){
        StrongSelf
        if (statusCode == 200) {
            strongSelf.bufferProgress = 0;
            [strongSelf loadPlayerItemWithAsset:asset];
        }else if (statusCode == 304) {
            NSLog(@"-- DFPlayer： 服务器音频资源未更新，播放本地");
            [strongSelf loadPlayerItemWithUrl:[NSURL fileURLWithPath:cacheFilePath]];
        }else if(statusCode == 206){
            
        }else{
            strongSelf.progress =
            strongSelf.bufferProgress =
            strongSelf.currentTime =
            strongSelf.totalTime = .0f;
            
            if (strongSelf.player) {
                strongSelf.player = nil;
            }
            [strongSelf.player.currentItem cancelPendingSeeks];
            [strongSelf.player.currentItem.asset cancelLoading];
            [strongSelf df_playerStatusWithStatusCode:DFPlayerStatus_UnavailableData];
        }
    };
}

/**加载 AVPlayerItem*/
- (void)loadPlayerItemWithAsset:(AVURLAsset *)asset{
    self.playerItem = [AVPlayerItem playerItemWithAsset:asset];
    [self loadPlayer];
}
- (void)loadPlayerItemWithUrl:(NSURL *)url{
    self.playerItem = [[AVPlayerItem alloc] initWithURL:url];
    [self loadPlayer];
}
/**加载 AVPlayer*/
- (void)loadPlayer{
    self.player = [[AVPlayer alloc] initWithPlayerItem:self.playerItem];
    
    [self addPlayProgressTimeObserver];

    [self addInformationOfLockScreen];
    
    [self df_audioPlay];
}

#pragma mark - KVO
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context{
    if (object == self.player.currentItem) {
        if ([keyPath isEqualToString:DFStatusKey]) {
            AVPlayerStatus status = [[change objectForKey:NSKeyValueChangeNewKey] integerValue];
            switch (status) {
                case AVPlayerItemStatusUnknown: //未知错误
                    self.state = DFPlayerStateFailed;
                    _isSettingPreviousAudioModel = NO;
                    [self df_playerStatusWithStatusCode:DFPlayerStatus_UnknownError];
                    break;
                case AVPlayerItemStatusReadyToPlay://准备播放
                    [self setPlayerSeekTotimeWithPreviousAudioModel];
                    if (self.delegate && [self.delegate respondsToSelector:@selector(df_playerReadyToPlay:)]) {
                        [self.delegate df_playerReadyToPlay:self];
                    }
                    break;
                case AVPlayerItemStatusFailed://准备失败.
                    self.state = DFPlayerStateFailed;
                    _isSettingPreviousAudioModel = NO;
                    [self df_playerStatusWithStatusCode:DFPlayerStatus_PlayError];
                    break;
                default:
                    break;
            }
        }else if ([keyPath isEqualToString:DFLoadedTimeRangesKey]) {
            self.totalTime = CMTimeGetSeconds(self.playerItem.duration);
            [self addBufferProgressObserver];
         
        }else if ([keyPath isEqualToString:DFPlaybackBufferEmptyKey]) {
            if (self.playerItem.playbackBufferEmpty) {//当缓冲是空的时候
                self.state = DFPlayerStateBuffering;
            }
        }else if ([keyPath isEqualToString:DFPlaybackLikelyToKeepUpKey]) {
            NSLog(@"-- DFPlayer： 缓冲达到可播放");
        }
    }else{
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - 缓冲进度 播放进度 歌曲锁屏信息 音频跳转 远程线控
/**缓冲进度*/
- (void)addBufferProgressObserver{
    if (!self.isObserveBufferProgress) {return;}
    CMTimeRange timeRange   = [self.playerItem.loadedTimeRanges.firstObject CMTimeRangeValue];
    CGFloat startSeconds    = CMTimeGetSeconds(timeRange.start);
    CGFloat durationSeconds = CMTimeGetSeconds(timeRange.duration);
    if (self.totalTime != 0) {//避免出现inf
        self.bufferProgress = (startSeconds + durationSeconds) / self.totalTime;
    }
    if (self.delegate && [self.delegate respondsToSelector:@selector(df_player:bufferProgress:totalTime:)]) {
        [self.delegate df_player:self
                  bufferProgress:self.bufferProgress
                       totalTime:self.totalTime];
    }
    
    if (_isSeekWaiting) {
        if (self.bufferProgress > _seekValue) {
            _isSeekWaiting = NO;
            [self didSeekToTimeWithValue:_seekValue];
        }
    }
}

/**播放进度*/
- (void)addPlayProgressTimeObserver{
    if (!self.isObserveProgress) {return;}
    WeakSelf
    self.timeObserver = [self.player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(1, 1) queue:nil usingBlock:^(CMTime time){
        StrongSelf
        AVPlayerItem *currentItem = strongSelf.playerItem;
        NSArray *loadedRanges = currentItem.seekableTimeRanges;
        if (loadedRanges.count > 0 && currentItem.duration.timescale != 0){
            CGFloat currentT = (CGFloat)CMTimeGetSeconds(time);
            if (!strongSelf->_isDraged) {
                strongSelf.currentTime = currentT;
            }
            if (strongSelf.totalTime != 0) {//避免出现inf
                strongSelf.progress = CMTimeGetSeconds([currentItem currentTime]) / strongSelf.totalTime;
            }
            if (strongSelf.delegate && [strongSelf.delegate respondsToSelector:@selector(df_player:progress:currentTime:totalTime:)]) {
                [weakSelf.delegate df_player:strongSelf
                                    progress:strongSelf.progress
                                 currentTime:currentT
                                   totalTime:strongSelf.totalTime];
            }
            
            [strongSelf updatePlayingCenterInfo];
        }
    }];
}

/**锁屏、后台模式信息*/
- (void)addInformationOfLockScreen{
    if (!self.currentAudioInfoModel.audioName &&
        !self.currentAudioInfoModel.audioAlbum &&
        !self.currentAudioInfoModel.audioSinger &&
        !self.currentAudioInfoModel.audioImage) {
        return;
    }
    MPNowPlayingInfoCenter *playInfoCenter = [MPNowPlayingInfoCenter defaultCenter];
    NSMutableDictionary *dic = [NSMutableDictionary dictionary];
    if (self.currentAudioInfoModel.audioName) {
        dic[MPMediaItemPropertyTitle] = self.currentAudioInfoModel.audioName;
    }
    if (self.currentAudioInfoModel.audioAlbum) {
        dic[MPMediaItemPropertyAlbumTitle] = self.currentAudioInfoModel.audioAlbum;
    }
    if (self.currentAudioInfoModel.audioSinger) {
        dic[MPMediaItemPropertyArtist] = self.currentAudioInfoModel.audioSinger;
    }
    dic[MPNowPlayingInfoPropertyPlaybackRate] = [NSNumber numberWithFloat:1.0];
    if ([self.currentAudioInfoModel.audioImage isKindOfClass:[UIImage class]] && self.currentAudioInfoModel.audioImage) {
        MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithImage:self.currentAudioInfoModel.audioImage];
        dic[MPMediaItemPropertyArtwork] = artwork;
    }
    playInfoCenter.nowPlayingInfo = dic;
}

- (void)updatePlayingCenterInfo{
    if (!_isBackground) {return;}
    NSDictionary *info=[[MPNowPlayingInfoCenter defaultCenter] nowPlayingInfo];
    NSMutableDictionary *dic = [NSMutableDictionary dictionaryWithDictionary:info];
    dic[MPNowPlayingInfoPropertyElapsedPlaybackTime] = [NSNumber numberWithDouble:CMTimeGetSeconds(self.playerItem.currentTime)];
    dic[MPMediaItemPropertyPlaybackDuration] = [NSNumber numberWithDouble:CMTimeGetSeconds(self.playerItem.duration)];
    [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:dic];
}

/**音频跳转*/
- (void)df_seekToTimeWithValue:(CGFloat)value{
    _isDraged = YES;
    // 先暂停
    [self df_audioPause];
    if (self.bufferProgress < value) {
        _isSeekWaiting = YES;
        _seekValue = value;
        if (_isSettingPreviousAudioModel) {
            [self audioPrePlayToLoadPreviousAudio];
            self.progress = value;
        }
    }else{
        _isSeekWaiting = NO;
        [self didSeekToTimeWithValue:value];
    }
}

- (void)didSeekToTimeWithValue:(CGFloat)value{
    if (self.state == DFPlayerStatePlaying || self.state == DFPlayerStatePause) {
        // 跳转
        WeakSelf
        [self.player seekToTime:CMTimeMake(floorf(self.totalTime * value), 1)
                toleranceBefore:CMTimeMake(1,1)
                 toleranceAfter:CMTimeMake(1,1)
              completionHandler:^(BOOL finished) {
                  StrongSelf
                  if (finished) {
                      [strongSelf df_audioPlay];
                      strongSelf->_isDraged = NO;
                  }
              }];
    }else if (self.state == DFPlayerStateStopped){
        [self audioPrePlayToLoadPreviousAudio];
        self.progress = value;
    }
}

/**远程线控*/
- (NSString *)df_remoteControlClass{
    return NSStringFromClass([DFPlayerRemoteApplication class]);
}
/**释放播放器*/
- (void)df_deallocPlayer{
    [self df_audioPause];
    //解除激活,并还原其他应用播放器声音
    if (self.resourceLoader) {
        [self.resourceLoader stopLoading];
    }
    if (_isOthetPlaying) {
        [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }else{
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
    }
    if (self.player) {
        self.player = nil;
    }
    [self.player.currentItem cancelPendingSeeks];
    [self.player.currentItem.asset cancelLoading];
}
#pragma mark - 播放 暂停 下一首 上一首
/**播放*/
-(void)df_audioPlay{
    if (!_isPlaying) {
        _isPlaying = YES;
        self.state = DFPlayerStatePlaying;
    }
    [self.player play];
}

/**暂停*/
-(void)df_audioPause{
    if (_isPlaying) {
        _isPlaying = NO;
        self.state = DFPlayerStatePause;
    }
    [self.player pause];
}

/**停止*/
-(void)df_audioStop{
    _isPlaying = NO;
    self.state = DFPlayerStateStopped;
    [self.player pause];
    [self df_deallocPlayer];
}

/**下一首*/
- (void)df_audioNext{
    switch (self.playMode) {
        case DFPlayerModeOnlyOnce:
            if (_isNaturalToEndTime) {
                _isNaturalToEndTime = NO;
                [self df_audioPause];
            }else{
                if (self.isManualToPlay) {
                    [self audioNextOrderCycle];
                }
            }
            break;
        case DFPlayerModeSingleCycle:
            /**解释：单曲循环模式下，如果是自动播放结束，则单曲循环。
             如果手动控制播放下一首或上一首，则根据isManualToPlay的设置判断播放下一首还是重新播放*/
            if (_isNaturalToEndTime) {
                _isNaturalToEndTime = NO;
                [self audioPrePlay];
            }else{
                if (self.isManualToPlay) {
                    [self audioNextOrderCycle];
                }else{
                    [self audioPrePlay];
                }
            }
            break;
        case DFPlayerModeOrderCycle:
            [self audioNextOrderCycle];
            break;
        case DFPlayerModeShuffleCycle:{
            _playIndex2++;
            NSInteger tag = [self audioNextShuffleCycleIndex];
            //去重 避免随机到当前正在播放的音频
            if (tag == _currentAudioId) {
                tag = [self audioNextShuffleCycleIndex];
            }
            _currentAudioId = tag;
            self.currentAudioModel = self.playerModelArray[_currentAudioId];
            [self audioPrePlay];
            break;
        }
        default:
            break;
    }
}

/**上一首*/
- (void)df_audioLast{
    switch (self.playMode) {
        case DFPlayerModeOnlyOnce:
            if (self.isManualToPlay) {
                [self audioLastOrderCycle];
            }else{
                [self df_audioPause];
            }
            break;
        case DFPlayerModeSingleCycle:
            if (self.isManualToPlay) {
                [self audioLastOrderCycle];
            }else{
                [self audioPrePlay];
            }
            break;
        case DFPlayerModeOrderCycle:
            [self audioLastOrderCycle];
            break;
        case DFPlayerModeShuffleCycle:{
            if (_playIndex2 == 1) {
                _playIndex2 = 0;
                self.currentAudioModel = self.playerModelArray[_playIndex1];
            }else{
                NSInteger tag = [self audioLastShuffleCycleIndex];
                //去重 避免随机到当前正在播放的音频
                if (tag == _currentAudioId) {
                    tag = [self audioLastShuffleCycleIndex];
                }
                _currentAudioId = tag;
                self.currentAudioModel = self.playerModelArray[_currentAudioId];
            }
            [self audioPrePlay];
            break;
        }
        default:
            break;
    }
}

- (void)audioNextOrderCycle{
    _currentAudioId++;
    if (_currentAudioId < 0 || _currentAudioId >= self.playerModelArray.count) {
        _currentAudioId = 0;
    }
    _playIndex1 = _currentAudioId;
    _playIndex2 = 0;
    self.currentAudioModel = self.playerModelArray[_currentAudioId];
    [self audioPrePlay];
}
- (void)audioLastOrderCycle{
    _currentAudioId--;
    if (_currentAudioId < 0) {
        _currentAudioId = self.playerModelArray.count-1;
    }
    self.currentAudioModel = self.playerModelArray[_currentAudioId];
    [self audioPrePlay];
}

#pragma mark - 随机播放数组
- (NSMutableArray *)randomIndexArray{
    if (!_randomIndexArray) {
        _randomIndexArray = [NSMutableArray arrayWithArray:[self getRandomPlayerModelIndexArray]];
    }
    return _randomIndexArray;
}

/**更新随机播放数组*/
- (void)updateRandomIndexArray{
    if (self.randomIndexArray.count != 0) {
        [self.randomIndexArray removeAllObjects];
        self.randomIndexArray = [NSMutableArray arrayWithArray:[self getRandomPlayerModelIndexArray]];
    }
}

//下一首随机index
- (NSInteger)audioNextShuffleCycleIndex{
    _randomIndex++;
    if (_randomIndex >= self.randomIndexArray.count) {
        _randomIndex = 0;
    }
    NSInteger tag = [self.randomIndexArray[_randomIndex] integerValue];
    return tag;
}
//上一首随机index
- (NSInteger)audioLastShuffleCycleIndex{
    _randomIndex--;
    if (_randomIndex < 0) {
        _randomIndex = self.randomIndexArray.count-1;
    }
    NSInteger tag = [self.randomIndexArray[_randomIndex] integerValue];
    return tag;
}

- (NSMutableArray*)getRandomPlayerModelIndexArray{
    NSInteger startIndex = 0;
    NSInteger length = self.playerModelArray.count;
    NSInteger endIndex = startIndex+length;
    NSMutableArray *arr = [NSMutableArray arrayWithCapacity:length];
    NSMutableArray *arr1 = [NSMutableArray arrayWithCapacity:length];
    @autoreleasepool{
        for (NSInteger i = startIndex; i < endIndex; i++) {
            [arr1 addObject:[NSString stringWithFormat:@"%ld",(long)i]];
        }
        for (NSInteger i = startIndex; i < endIndex; i++) {
            int index = arc4random()%arr1.count;
            int radom = [arr1[index] intValue];
            NSNumber *num = [NSNumber numberWithInt:radom];
            [arr addObject:num];
            [arr1 removeObjectAtIndex:index];
        }
    }
    return arr;
}

#pragma mark - setter
- (void)setPlayerItem:(AVPlayerItem *)playerItem{
    if (_playerItem == playerItem) {return;}
    if (_playerItem) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [_playerItem removeObserver:self forKeyPath:DFStatusKey];
        [_playerItem removeObserver:self forKeyPath:DFLoadedTimeRangesKey];
        [_playerItem removeObserver:self forKeyPath:DFPlaybackBufferEmptyKey];
        [_playerItem removeObserver:self forKeyPath:DFPlaybackLikelyToKeepUpKey];
    }
    _playerItem = playerItem;
    if (playerItem) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(df_playerDidPlayToEndTime:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
        [playerItem addObserver:self forKeyPath:DFStatusKey options:NSKeyValueObservingOptionNew context:nil];
        [playerItem addObserver:self forKeyPath:DFLoadedTimeRangesKey options:NSKeyValueObservingOptionNew context:nil];
        [playerItem addObserver:self forKeyPath:DFPlaybackBufferEmptyKey options:NSKeyValueObservingOptionNew context:nil];
        [playerItem addObserver:self forKeyPath:DFPlaybackLikelyToKeepUpKey options:NSKeyValueObservingOptionNew context:nil];
    }
}
- (void)setCategory:(DFPlayerAudioSessionCategory)category{
    _category = category;
    switch (category) {
        case DFPlayerAudioSessionCategoryAmbient:
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient error:nil];
            break;
        case DFPlayerAudioSessionCategorySoloAmbient:
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategorySoloAmbient error:nil];
            break;
        case DFPlayerAudioSessionCategoryPlayback:
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
            break;
//        case DFPlayerAudioSessionCategoryRecord:
//            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:nil];
//            break;
        case DFPlayerAudioSessionCategoryPlayAndRecord:
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategorySoloAmbient error:nil];
            break;
        case DFPlayerAudioSessionCategoryMultiRoute:
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategorySoloAmbient error:nil];
            break;
        default:
            break;
    }
}
- (void)setPlayMode:(DFPlayerMode)playMode{
    _playMode = playMode;
    [[NSUserDefaults standardUserDefaults] setInteger:playMode forKey:DFPlayerModeKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
- (void)setIsRemoteControl:(BOOL)isRemoteControl{
    _isRemoteControl = isRemoteControl;
    if (_isRemoteControl) {
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
    }else{
        [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
    }
}
- (void)setState:(DFPlayerState)state{_state = state;}
- (void)setCurrentAudioModel:(DFPlayerModel *)currentAudioModel{_currentAudioModel = currentAudioModel;}
- (void)setBufferProgress:(CGFloat)bufferProgress{_bufferProgress = bufferProgress;}
- (void)setProgress:(CGFloat)progress{_progress = progress;}
- (void)setCurrentTime:(NSInteger)currentTime{_currentTime = currentTime;}
- (void)setTotalTime:(CGFloat)totalTime{_totalTime = totalTime;}

#pragma mark - 缓存相关
- (void)initPlayerCachePathWithUserId:(NSString *)userId{
    [DFPlayerFileManager df_playerCreateCachePathWithId:userId];
}

/**检查当前链接是否缓存*/
+ (NSString *)df_playerCheckIsCachedWithAudioUrl:(NSURL *)url{
    if (![url isKindOfClass:[NSURL class]]) {return nil;}
    if ([url.scheme isEqualToString:@"file"]) {return nil;}
    if (url) {
        NSString *cacheFilePath = [DFPlayerFileManager df_isCachedWithAudioUrl:url];
        if (cacheFilePath) {return cacheFilePath;}
    }
    return nil;
}

/**清除url对应的本地缓存*/
+ (void)df_playerClearCacheWithAudioUrl:(NSURL *)url
                                  block:(void(^)(BOOL isSuccess, NSError *error))block{
    [DFPlayerFileManager df_playerClearCacheWithUrl:url block:^(BOOL isSuccess, NSError *error) {
        if (block) {
            block(isSuccess,error);
        }
    }];
}

/**清除缓存 */
+ (void)df_playerClearCacheForCurrentUser:(BOOL)isClearCurrentUser
                                    block:(void(^)(BOOL isSuccess, NSError *error))block{
    [DFPlayerFileManager df_clearCacheForCurrentUser:isClearCurrentUser block:^(BOOL isSuccess, NSError *error) {
        if (block) {
            block(isSuccess,error);
        }
    }];
}

/**计算DFPlayer缓存大小*/
+ (CGFloat)df_playerCountCacheSizeForCurrentUser:(BOOL)isCurrentUser{
    return [DFPlayerFileManager df_countCacheSizeForCurrentUser:isCurrentUser];
}

/**计算系统磁盘空间 剩余可用空间*/
+ (void)df_countSystemSizeBlock:(void(^)(CGFloat totalSize,CGFloat freeSize))block{
    [DFPlayerFileManager df_countSystemSizeBlock:^(CGFloat totalSize, CGFloat freeSize) {
        if (block) {
            block(totalSize,freeSize);
        }
    }];
}

#pragma mark - 统一状态代理
- (void)df_playerStatusWithStatusCode:(NSUInteger)statusCode{
    NSLog(@"-- DFPlayer： 状态码:%lu",(unsigned long)statusCode);
    if (self.delegate && [self.delegate respondsToSelector:@selector(df_player:didGetStatusCode:)]) {
        [self.delegate df_player:self didGetStatusCode:statusCode];
    }
}

@end



