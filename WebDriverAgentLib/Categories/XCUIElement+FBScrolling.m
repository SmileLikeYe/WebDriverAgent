/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "XCUIElement+FBScrolling.h"

#import "FBErrorBuilder.h"
#import "FBRunLoopSpinner.h"
#import "FBLogger.h"
#import "FBMacros.h"
#import "XCElementSnapshot+FBHelpers.h"
#import "XCElementSnapshot.h"
#import "XCEventGenerator.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"
#import "XCTestDriver.h"
#import "XCUIApplication.h"
#import "XCUICoordinate.h"
#import "XCUIElement+FBIsVisible.h"
#import "XCUIElement.h"
#import "XCUIElement+FBWebDriverAttributes.h"

#define FBPointFuzzyEqualToPoint(point1, point2, threshold) ((fabs(point1.x - point2.x) < threshold) && (fabs(point1.y - point2.y) < threshold))

const CGFloat FBFuzzyPointThreshold = 20.f; //Smallest determined value that is not interpreted as touch
const CGFloat FBFullscreenNormalizedDistance = 1.0f;
const CGFloat FBScrollToVisibleNormalizedDistance = .5f;
const CGFloat FBScrollVelocity = 200.f;
const CGFloat FBScrollBoundingVelocityPadding = 0.0f;
const CGFloat FBScrollTouchProportion = 0.75f;
const CGFloat FBScrollCoolOffTime = 1.f;
const CGFloat FBMinimumTouchEventDelay = 0.1f;

@interface XCElementSnapshot (FBScrolling)

- (void)fb_scrollUpByNormalizedDistance:(CGFloat)distance;
- (void)fb_scrollDownByNormalizedDistance:(CGFloat)distance;
- (void)fb_scrollLeftByNormalizedDistance:(CGFloat)distance;
- (void)fb_scrollRightByNormalizedDistance:(CGFloat)distance;
- (BOOL)fb_scrollByNormalizedVector:(CGVector)normalizedScrollVector;
- (BOOL)fb_scrollByVector:(CGVector)vector error:(NSError **)error;

@end

@implementation XCUIElement (FBScrolling)

- (void)fb_scrollUp
{
  [self.lastSnapshot fb_scrollUpByNormalizedDistance:FBFullscreenNormalizedDistance];
}

- (void)fb_scrollDown
{
  [self.lastSnapshot fb_scrollDownByNormalizedDistance:FBFullscreenNormalizedDistance];
}

- (void)fb_scrollLeft
{
  [self.lastSnapshot fb_scrollLeftByNormalizedDistance:FBFullscreenNormalizedDistance];
}

- (void)fb_scrollRight
{
  [self.lastSnapshot fb_scrollRightByNormalizedDistance:FBFullscreenNormalizedDistance];
}

- (BOOL)fb_scrollToVisibleWithError:(NSError **)error
{
  return [self fb_scrollToVisibleWithNormalizedScrollDistance:FBScrollToVisibleNormalizedDistance error:error];
}

- (BOOL)fb_scrollToVisibleWithNormalizedScrollDistance:(CGFloat)normalizedScrollDistance error:(NSError **)error
{
  return [self fb_scrollToVisibleWithNormalizedScrollDistance:normalizedScrollDistance
                                              scrollDirection:FBXCUIElementScrollDirectionUnknown
                                                        error:error];
}

- (BOOL)fb_scrollToVisibleWithNormalizedScrollDistance:(CGFloat)normalizedScrollDistance scrollDirection:(FBXCUIElementScrollDirection)scrollDirection error:(NSError **)error
{
  [self resolve];
  if (self.fb_isVisible) {
    return YES;
  }
  __block NSArray<XCElementSnapshot *> *cellSnapshots, *visibleCellSnapshots;
    
  NSArray *acceptedParents = @[
                               @(XCUIElementTypeScrollView),
                               @(XCUIElementTypeCollectionView),
                               @(XCUIElementTypeTable),
                               ];
    
  XCElementSnapshot *scrollView = [self.lastSnapshot fb_parentMatchingOneOfTypes:acceptedParents
      filter:^(XCElementSnapshot *snapshot) {
          
         if (![snapshot isWDVisible]) {
           return NO;
         }
          
         cellSnapshots = [snapshot fb_descendantsCellSnapshots];
              
         visibleCellSnapshots = [cellSnapshots filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == YES", FBStringify(XCUIElement, fb_isVisible)]];
              
         if (visibleCellSnapshots.count > 1) {
           return YES;
         }
         return NO;
      }];
    
  if (scrollView == nil) {
    return
    [[[FBErrorBuilder builder]
      withDescriptionFormat:@"Failed to find scrollable visible parent with 2 visible children"]
     buildError:error];
  }

  XCElementSnapshot *targetCellSnapshot = [self.lastSnapshot fb_parentCellSnapshot];

  XCElementSnapshot *lastSnapshot = visibleCellSnapshots.lastObject;
  // Can't just do indexOfObject, because targetCellSnapshot may represent the same object represented by a member of cellSnapshots, yet be a different object
  // than that member. This reflects the fact that targetCellSnapshot came out of self.fb_parentCellSnapshot, not out of cellSnapshots directly.
  // If the result is NSNotFound, we'll just proceed by scrolling downward/rightward, since NSNotFound will always be larger than the current index.
  NSUInteger targetCellIndex = [cellSnapshots indexOfObjectPassingTest:^BOOL(XCElementSnapshot * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
    return [obj _matchesElement:targetCellSnapshot];
  }];
  NSUInteger visibleCellIndex = [cellSnapshots indexOfObject:lastSnapshot];

  if (scrollDirection == FBXCUIElementScrollDirectionUnknown) {
    // Try to determine the scroll direction by determining the vector between the first and last visible cells
    XCElementSnapshot *firstVisibleCell = visibleCellSnapshots.firstObject;
    XCElementSnapshot *lastVisibleCell = visibleCellSnapshots.lastObject;
    CGVector cellGrowthVector = CGVectorMake(firstVisibleCell.frame.origin.x - lastVisibleCell.frame.origin.x,
                                             firstVisibleCell.frame.origin.y - lastVisibleCell.frame.origin.y
                                             );
    if (ABS(cellGrowthVector.dy) > ABS(cellGrowthVector.dx)) {
      scrollDirection = FBXCUIElementScrollDirectionVertical;
    } else {
      scrollDirection = FBXCUIElementScrollDirectionHorizontal;
    }
  }

  const NSUInteger maxScrollCount = 25;
  NSUInteger scrollCount = 0;

  XCElementSnapshot *prescrollSnapshot = self.lastSnapshot;
  // Scrolling till cell is visible and get current value of frames
  while (![self fb_isEquivalentElementSnapshotVisible:prescrollSnapshot] && scrollCount < maxScrollCount) {
    if (targetCellIndex < visibleCellIndex) {
      scrollDirection == FBXCUIElementScrollDirectionVertical ? [scrollView fb_scrollUpByNormalizedDistance:normalizedScrollDistance] :
      [scrollView fb_scrollLeftByNormalizedDistance:normalizedScrollDistance];
    }
    else {
      scrollDirection == FBXCUIElementScrollDirectionVertical ? [scrollView fb_scrollDownByNormalizedDistance:normalizedScrollDistance] :
      [scrollView fb_scrollRightByNormalizedDistance:normalizedScrollDistance];
    }
    [self resolve]; // Resolve is needed for correct visibility
    scrollCount++;
  }

  if (scrollCount >= maxScrollCount) {
    return
    [[[FBErrorBuilder builder]
      withDescriptionFormat:@"Failed to perform scroll with visible cell due to max scroll count reached"]
     buildError:error];
  }

  // Cell is now visible, but it might be only partialy visible, scrolling till whole frame is visible
  targetCellSnapshot = [self.lastSnapshot fb_parentCellSnapshot];
  CGVector scrollVector = CGVectorMake(targetCellSnapshot.visibleFrame.size.width - targetCellSnapshot.frame.size.width,
                                       targetCellSnapshot.visibleFrame.size.height - targetCellSnapshot.frame.size.height
                                       );
  if (![scrollView fb_scrollByVector:scrollVector error:error]) {
    return NO;
  }
  return YES;
}

- (BOOL)fb_isEquivalentElementSnapshotVisible:(XCElementSnapshot *)snapshot
{
  if (self.fb_isVisible) {
    return YES;
  }
  [self.application resolve];
  for (XCElementSnapshot *elementSnapshot in self.application.lastSnapshot._allDescendants.copy) {
    // We are comparing pre-scroll snapshot so frames are irrelevant.
    if ([snapshot fb_framelessFuzzyMatchesElement:elementSnapshot] && elementSnapshot.fb_isVisible) {
      return YES;
    }
  }
  return NO;
}

@end


@implementation XCElementSnapshot (FBScrolling)

- (void)fb_scrollUpByNormalizedDistance:(CGFloat)distance
{
  [self fb_scrollByNormalizedVector:CGVectorMake(0.0, distance)];
}

- (void)fb_scrollDownByNormalizedDistance:(CGFloat)distance
{
  [self fb_scrollByNormalizedVector:CGVectorMake(0.0, -distance)];
}

- (void)fb_scrollLeftByNormalizedDistance:(CGFloat)distance
{
  [self fb_scrollByNormalizedVector:CGVectorMake(distance, 0.0)];
}

- (void)fb_scrollRightByNormalizedDistance:(CGFloat)distance
{
  [self fb_scrollByNormalizedVector:CGVectorMake(-distance, 0.0)];
}

- (BOOL)fb_scrollByNormalizedVector:(CGVector)normalizedScrollVector
{
  CGVector scrollVector = CGVectorMake(CGRectGetWidth(self.frame) * normalizedScrollVector.dx,
                                       CGRectGetHeight(self.frame) * normalizedScrollVector.dy
                                       );
  return [self fb_scrollByVector:scrollVector error:nil];
}

- (BOOL)fb_scrollByVector:(CGVector)vector error:(NSError **)error
{
  CGVector scrollBoundingVector = CGVectorMake(CGRectGetWidth(self.frame) * FBScrollTouchProportion - FBScrollBoundingVelocityPadding,
                                               CGRectGetHeight(self.frame)* FBScrollTouchProportion - FBScrollBoundingVelocityPadding
                                               );
  scrollBoundingVector.dx = (CGFloat)copysign(scrollBoundingVector.dx, vector.dx);
  scrollBoundingVector.dy = (CGFloat)copysign(scrollBoundingVector.dy, vector.dy);

  NSUInteger scrollLimit = 100;
  BOOL shouldFinishScrolling = NO;
  while (!shouldFinishScrolling) {
    CGVector scrollVector = CGVectorMake(0, 0);
    scrollVector.dx = fabs(vector.dx) > fabs(scrollBoundingVector.dx) ? scrollBoundingVector.dx : vector.dx;
    scrollVector.dy = fabs(vector.dy) > fabs(scrollBoundingVector.dy) ? scrollBoundingVector.dy : vector.dy;
    vector = CGVectorMake(vector.dx - scrollVector.dx, vector.dy - scrollVector.dy);
    shouldFinishScrolling = (vector.dx == 0.0 & vector.dy == 0.0 || --scrollLimit == 0);
    if (![self fb_scrollAncestorScrollViewByVectorWithinScrollViewFrame:scrollVector error:error]){
      return NO;
    }
  }
  return YES;
}

- (CGVector)fb_hitPointOffsetForScrollingVector:(CGVector)scrollingVector
{
  return
    CGVectorMake(
      CGRectGetMinX(self.frame) + CGRectGetWidth(self.frame) * (scrollingVector.dx < 0.0f ? FBScrollTouchProportion : (1 - FBScrollTouchProportion)),
      CGRectGetMinY(self.frame) + CGRectGetHeight(self.frame) * (scrollingVector.dy < 0.0f ? FBScrollTouchProportion : (1 - FBScrollTouchProportion))
    );
}

- (BOOL)fb_scrollAncestorScrollViewByVectorWithinScrollViewFrame:(CGVector)vector error:(NSError **)error
{
  CGVector hitpointOffset = [self fb_hitPointOffsetForScrollingVector:vector];

  XCUICoordinate *appCoordinate = [[XCUICoordinate alloc] initWithElement:self.application normalizedOffset:CGVectorMake(0.0, 0.0)];
  XCUICoordinate *startCoordinate = [[XCUICoordinate alloc] initWithCoordinate:appCoordinate pointsOffset:hitpointOffset];
  XCUICoordinate *endCoordinate = [[XCUICoordinate alloc] initWithCoordinate:startCoordinate pointsOffset:vector];

  if (FBPointFuzzyEqualToPoint(startCoordinate.screenPoint, endCoordinate.screenPoint, FBFuzzyPointThreshold)) {
    return YES;
  }

  double offset = 0.3; // Waiting before scrolling helps to make it more stable
  double scrollingTime = MAX(fabs(vector.dx), fabs(vector.dy))/FBScrollVelocity;
  XCPointerEventPath *touchPath = [[XCPointerEventPath alloc] initForTouchAtPoint:startCoordinate.screenPoint offset:offset];
  offset += MAX(scrollingTime, FBMinimumTouchEventDelay); // Setting Minimum scrolling time to avoid testmanager complaining about timing
  [touchPath moveToPoint:endCoordinate.screenPoint atOffset:offset];
  offset += FBMinimumTouchEventDelay;
  [touchPath liftUpAtOffset:offset];

  XCSynthesizedEventRecord *event = [[XCSynthesizedEventRecord alloc] initWithName:@"FBScroll" interfaceOrientation:self.application.interfaceOrientation];
  [event addPointerEventPath:touchPath];

  __block BOOL didSucceed = NO;
  __block NSError *innerError;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)()){
    [[XCTestDriver sharedTestDriver].managerProxy _XCT_synthesizeEvent:event completion:^(NSError *scrollingError) {
      innerError = scrollingError;
      didSucceed = (scrollingError == nil);
      completion();
    }];
  }];
  if (error) {
    *error = innerError;
  }
  // Tapping cells immediately after scrolling may fail due to way UIKit is handling touches.
  // We should wait till scroll view cools off, before continuing
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:FBScrollCoolOffTime]];
  return didSucceed;
}

@end
