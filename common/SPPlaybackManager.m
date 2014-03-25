//
//  SPPlaybackManager.m
//  Guess The Intro
//
//  Created by Daniel Kennett on 06/05/2011.
/*
 Copyright (c) 2011, Spotify AB
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * Neither the name of Spotify AB nor the names of its contributors may 
 be used to endorse or promote products derived from this software 
 without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL SPOTIFY AB BE LIABLE FOR ANY DIRECT, INDIRECT,
 INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, 
 OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SPPlaybackManager.h"
#import "SPCoreAudioController.h"
#import "SPTrack.h"
#import "SPSession.h"
#import "SPErrorExtensions.h"
#import "SPPlaylistItem.h"

@interface SPPlaybackManager ()

@property (nonatomic, readwrite, strong) SPCoreAudioController *audioController;
@property (nonatomic, readwrite, strong) SPCoreAudioController *audioController2;
@property (nonatomic, readwrite, strong) SPTrack *currentTrack;
@property (nonatomic, readwrite, strong) SPSession *playbackSession;

@property (nonatomic, strong) NSTimer *originalTrackTimer;
@property (nonatomic, strong) NSTimer *newerTrackTimer;

@property (readwrite) NSTimeInterval trackPosition;

-(void)informDelegateOfAudioPlaybackStarting;

@end

static void * const kSPPlaybackManagerKVOContext = @"kSPPlaybackManagerKVOContext"; 

@implementation SPPlaybackManager {
	NSMethodSignature *incrementTrackPositionMethodSignature;
	NSInvocation *incrementTrackPositionInvocation;
}

-(void)clearCurrentAudioBuffer;
{
        [self.audioController clearAudioBuffers];
        [self.audioController setVolume:0.0];
    
        [self.audioController2 clearAudioBuffers];
        [self.audioController2 setVolume:0.0];
}

-(id)initWithPlaybackSession:(SPSession *)aSession {
    
    if ((self = [super init])) {
        
        self.playbackSession = aSession;
		self.playbackSession.playbackDelegate = (id)self;
		self.audioController = [[SPCoreAudioController alloc] init];
		self.audioController.delegate = self;
        
        self.playbackSession.audioDeliveryDelegate = self.audioController;
        [self.audioController setVolume:0];
        
        self.audioController2 = [[SPCoreAudioController alloc] init];
        self.audioController2.delegate = self;
        
        [self.audioController2 setVolume:0]; // set the second chanel to 0 to fade in from start
		
		[self addObserver:self
			   forKeyPath:@"playbackSession.playing"
				  options:0
				  context:kSPPlaybackManagerKVOContext];
	}
    return self;
}

-(id)initWithAudioController:(SPCoreAudioController *)aController playbackSession:(SPSession *)aSession {
	
	self = [self initWithPlaybackSession:aSession];
	
	if (self) {
		self.audioController = aController;
		self.audioController.delegate = self;
		self.playbackSession.audioDeliveryDelegate = self.audioController;
	}
	
	return self;
}

-(void)dealloc {
	
	[self removeObserver:self forKeyPath:@"playbackSession.playing"];
	
	self.playbackSession.playbackDelegate = nil;
	self.playbackSession = nil;
	self.currentTrack = nil;
	
	self.audioController.delegate = nil;
	self.audioController = nil;
    
    self.audioController2.delegate = nil;
    self.audioController2 = nil;
}

@synthesize audioController;
@synthesize audioController2;
@synthesize playbackSession;
@synthesize trackPosition;
@synthesize delegate;
@synthesize originalTrackTimer, newerTrackTimer;

+(NSSet *)keyPathsForValuesAffectingVolume {
	return [NSSet setWithObject:@"audioController.volume"];
}

-(double)volume {
	return self.audioController.volume;
}

-(void)setVolume:(double)volume {
	self.audioController.volume = volume;
}

@synthesize currentTrack;

-(void)playTrack:(SPTrack *)aTrack callback:(SPErrorableOperationCallback)block {
    
    self.callbackBlock = block;
	// new
    // if playing song then call crossfade track?
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL crossFade = [defaults boolForKey:@"enableCrossfade"];
    if (crossFade) {
        
        if (aTrack.availability != SP_TRACK_AVAILABILITY_AVAILABLE) {
            if (block) block([NSError spotifyErrorWithCode:SP_ERROR_TRACK_NOT_PLAYABLE]);
            self.currentTrack = nil;
            return;
        }
        
        [self crossfadeTrack:aTrack callback:block];
        return;
    }
    
    //old
	self.playbackSession.playing = NO;
	[self.playbackSession unloadPlayback];
	[self.audioController clearAudioBuffers];
	
	if (aTrack.availability != SP_TRACK_AVAILABILITY_AVAILABLE) {
		if (block) block([NSError spotifyErrorWithCode:SP_ERROR_TRACK_NOT_PLAYABLE]);
		self.currentTrack = nil;
	}
		
	self.currentTrack = aTrack;
	self.trackPosition = 0.0;
	
	[self.playbackSession playTrack:self.currentTrack callback:^(NSError *error) {
		
		if (!error) {
			self.playbackSession.playing = YES;
            if (block) {
                block(nil);
            }
        } else {
			self.currentTrack = nil;
            if (block) {
                block(error);
            }
        }
	}];
}

// call preload track before the song has finished to allow it to load (20 seconds?)
// call this when we want to crossfade (call at 10 seconds?)
// fade between the two
// [self.audioController setVolume:(double)];
//NEED TO PRELOAD THE NEW TRACK SO IT DOESNT JUMP
-(void)crossfadeTrack:(SPTrack *)aTrack callback:(SPErrorableOperationCallback)block;
{
    // switch audiocontroller from current to other
    if ([aTrack isKindOfClass:[SPPlaylistItem class]]) {
        aTrack = [(SPPlaylistItem*)aTrack item];
    }
    
        [SPAsyncLoading waitUntilLoaded:aTrack timeout:kSPAsyncLoadingDefaultTimeout then:^(NSArray *loadedItems, NSArray *notLoadedItems) {
            if ([loadedItems count]>0) {
                SPTrack *newTrack = loadedItems[0];
                if ([newTrack isLoaded]) {
                    
                        if (self.playbackSession.audioDeliveryDelegate == self.audioController)
                        {
                            self.audioController.delegate = nil;
                            
                            // switch to the alternative playback delegate
                            self.audioController2.delegate = self;
                            
                            [self.playbackSession setAudioDeliveryDelegate:self.audioController2];
                        } else if (self.playbackSession.audioDeliveryDelegate == self.audioController2) {
                            
                            self.audioController2.delegate = nil;
                            
                            // switch back to the original playback
                            self.audioController.delegate = self;
                            
                            [self.playbackSession setAudioDeliveryDelegate:self.audioController];
                        }
                        
                        if (aTrack.availability != SP_TRACK_AVAILABILITY_AVAILABLE) {
                            if (block) block([NSError spotifyErrorWithCode:SP_ERROR_TRACK_NOT_PLAYABLE]);
                            self.currentTrack = nil;
                            return;
                        }
                    
                            // after the fade duration so fade the next song correctly
                            // set the track position back to zero for the new song
                            self.currentTrack = newTrack;
                            self.trackPosition = 0.0;
                        
                            [self.playbackSession playTrack:self.currentTrack callback:^(NSError *error) {
                                if (!error) {
                                    // cross fade the new track
                                    // improve loading my delaying playing a second later to allow the track to buffer
                                    
                                    double delayInSeconds = 0.5f;
                                    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
                                    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                                        self.originalTrackTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(fadeOutOriginalTrack:) userInfo:nil repeats:TRUE];
                                        self.newerTrackTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(fadeInNewTrack:) userInfo:nil repeats:TRUE];
                                        self.playbackSession.playing = YES;
                                    });
                                } else {
                                    self.currentTrack = nil;
                                    
                                    [self clearCurrentAudioBuffer];
                                    
                                    if (block) {
                                        block(error);
                                    }
                                }
                            }];
                } else {
                    [self crossfadeTrack:aTrack callback:block];
                }
            } else if ([notLoadedItems count]>0) {
                [self crossfadeTrack:aTrack callback:block];
            }
        }];
}

-(void)fadeOutOriginalTrack:(NSTimer*)timer;
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        float duration = [defaults floatForKey:@"crossfadeDuration"];
        duration = 1/duration; // work out the intervals in seconds to crossfade
        if (self.playbackSession.audioDeliveryDelegate == self.audioController) {
            // fade out the old track
            double volume = self.audioController2.volume;
            NSLog(@"FADE OUT AUDIO VOLUME 2: %f", volume);
            if (volume > 0.1) {
                [self.audioController2 setVolume:volume-(duration/10)];
            } else {
                [self.audioController2 setVolume:0.0];
                // invalidate the timer
                
                [self.originalTrackTimer invalidate];
                self.originalTrackTimer = nil;
            }
        } else if (self.playbackSession.audioDeliveryDelegate == self.audioController2) {
            // fade out the old track
            double volume = self.audioController.volume;
            NSLog(@"FADE OUT AUDIO VOLUME 1: %f", volume);
            if (volume > 0.1) {
                [self.audioController setVolume:volume-(duration/10)];
            } else {
                [self.audioController setVolume:0.0];
                // invalidate the timer
                
                [self.originalTrackTimer invalidate];
                self.originalTrackTimer = nil;
            }
        }
    });
}

-(void)fadeInNewTrack:(NSTimer*)timer;
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        float duration = [defaults floatForKey:@"crossfadeDuration"];
        duration = 1/duration; // work out the intervals in seconds to crossfade
        
        if (self.playbackSession.audioDeliveryDelegate == self.audioController) {
            // fade in the new track
            double volume = self.audioController.volume;
            if (volume < 0.9) {
                NSLog(@"FADE IN AUDIO VOLUME 1 %f", volume);
                [self.audioController setVolume:volume+(duration/10)];
            } else {
                [self.newerTrackTimer invalidate];
                self.newerTrackTimer = nil;
                
                [self.audioController setVolume:1.0];
                [self.audioController2 clearAudioBuffers];
                
                if (self.callbackBlock) {
                    self.callbackBlock(nil);
                }
            }
        } else if (self.playbackSession.audioDeliveryDelegate == self.audioController2) {
            // fade in the new track
            double volume = self.audioController2.volume;
            if (volume < 0.9) {
                NSLog(@"FADE IN AUDIO VOLUME 2 %f", volume);
                [self.audioController2 setVolume:volume+(duration/10)];
            } else {
                [self.newerTrackTimer invalidate];
                self.newerTrackTimer = nil;
                
                [self.audioController2 setVolume:1.0];
                [self.audioController clearAudioBuffers];
                
                if (self.callbackBlock) {
                    self.callbackBlock(nil);
                }
            }
        }
    });
}

-(void)seekToTrackPosition:(NSTimeInterval)newPosition {
	if (newPosition <= self.currentTrack.duration) {
		[self.playbackSession seekPlaybackToOffset:newPosition];
		self.trackPosition = newPosition;
	}	
}

+(NSSet *)keyPathsForValuesAffectingIsPlaying {
	return [NSSet setWithObject:@"playbackSession.playing"];
}

-(BOOL)isPlaying {
	return self.playbackSession.isPlaying;
}

-(void)setIsPlaying:(BOOL)isPlaying {
	self.playbackSession.playing = isPlaying;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    
	if ([keyPath isEqualToString:@"playbackSession.playing"] && context == kSPPlaybackManagerKVOContext) {
        
        self.audioController.audioOutputEnabled = self.playbackSession.isPlaying;
        self.audioController2.audioOutputEnabled = self.playbackSession.isPlaying;
        
	} else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

#pragma mark -
#pragma mark Audio Controller Delegate

-(void)coreAudioController:(SPCoreAudioController *)controller didOutputAudioOfDuration:(NSTimeInterval)audioDuration; {
	
    // ensure we are enabled and have audio playback
    if (!self.playbackSession.isPlaying) {
        [self setIsPlaying:YES];
    }
    
	if (self.trackPosition == 0.0) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate playbackManagerWillStartPlayingAudio:self]; });
    }
	
	self.trackPosition += audioDuration;
}

#pragma mark -
#pragma mark Playback Callbacks

-(void)sessionDidLosePlayToken:(SPSession *)aSession {

	// This delegate is called when playback stops because the Spotify account is being used for playback elsewhere.
	// In practice, playback is only paused and you can call [SPSession -setIsPlaying:YES] to start playback again and 
	// pause the other client.

}

-(void)sessionDidEndPlayback:(SPSession *)aSession {
	
	// This delegate is called when playback stops naturally, at the end of a track.
	
	// Not routing this through to the main thread causes odd locks and crashes.
	[self performSelectorOnMainThread:@selector(sessionDidEndPlaybackOnMainThread:)
						   withObject:aSession
						waitUntilDone:NO];
}

-(void)sessionDidEndPlaybackOnMainThread:(SPSession *)aSession {
	self.currentTrack = nil;	
}


-(void)informDelegateOfAudioPlaybackStarting {
	if (![NSThread isMainThread]) {
		[self performSelectorOnMainThread:_cmd withObject:nil waitUntilDone:NO];
		return;
	}
	[self.delegate playbackManagerWillStartPlayingAudio:self];
}

@end
