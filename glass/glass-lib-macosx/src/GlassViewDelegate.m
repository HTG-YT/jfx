/*
 * Copyright (c) 2011, 2013, Oracle and/or its affiliates. All rights reserved.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  Oracle designates this
 * particular file as subject to the "Classpath" exception as provided
 * by Oracle in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 *
 * You should have received a copy of the GNU General Public License version
 * 2 along with this work; if not, write to the Free Software Foundation,
 * Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301 USA.
 *
 * Please contact Oracle, 500 Oracle Parkway, Redwood Shores, CA 94065 USA
 * or visit www.oracle.com if you need additional information or have any
 * questions.
 */

#import "common.h"
#import "com_sun_glass_events_ViewEvent.h"
#import "com_sun_glass_events_MouseEvent.h"
#import "com_sun_glass_events_KeyEvent.h"
#import "com_sun_glass_events_DndEvent.h"
#import "com_sun_glass_events_SwipeGesture.h"
#import "com_sun_glass_ui_Clipboard.h"
#import "com_sun_glass_ui_mac_MacGestureSupport.h"

#import "GlassMacros.h"
#import "GlassViewDelegate.h"
#import "GlassKey.h"
#import "GlassScreen.h"
#import "GlassWindow.h"
#import "GlassApplication.h"
#import "GlassLayer3D.h"
#import "GlassNSEvent.h"
#import "GlassPasteboard.h"
#import "GlassHelper.h"
#import "GlassStatics.h"

//#define VERBOSE
#ifndef VERBOSE
    #define LOG(MSG, ...)
#else
    #define LOG(MSG, ...) GLASS_LOG(MSG, ## __VA_ARGS__);
#endif

//#define DNDVERBOSE
#ifndef DNDVERBOSE
    #define DNDLOG(MSG, ...)
#else
    #define DNDLOG(MSG, ...) GLASS_LOG(MSG, ## __VA_ARGS__);
#endif

// used Safari as a reference while dragging large images
#define MAX_DRAG_SIZE 400

// explicitly set image size
#define DEFAULT_DRAG_SIZE 64

// Tracks pressed modifier keys
static NSUInteger s_modifierFlags = 0;

// The last processed key event
static NSEvent* s_lastKeyEvent = nil;

// Extracted from class-dump utility output for NSEvent class
@interface NSEvent (hidden)

- (long long)_scrollPhase;
- (unsigned long long)momentumPhase;
@end


static jboolean isInertialScroll(NSEvent *theEvent)
{
    enum 
    {
        SelectorNotSet,
        MomentumPhaseSelector,
        ScrollPhaseSelector,
        SelectorNotAvailable
    };

    static int selector = SelectorNotSet;

    switch (selector) 
    {
        case SelectorNotSet:
            if ([theEvent respondsToSelector:@selector(momentumPhase)])
            {   // Available from OS X 10.7
                selector = MomentumPhaseSelector;
            }
            else if ([theEvent respondsToSelector:@selector(_scrollPhase)])
            {   // Available in OS X 10.6 and earlier. Deprecated in OS X 10.7
                selector = ScrollPhaseSelector;
            }
            else
            {
                selector = SelectorNotAvailable;
            }
            return isInertialScroll(theEvent);

        case MomentumPhaseSelector:
            return ([theEvent momentumPhase] != 0);

        case ScrollPhaseSelector:
            return ([theEvent _scrollPhase] != 0);
    }

    return JNI_FALSE;
}


static jint getSwipeDirFromEvent(NSEvent *theEvent)
{
    if ([theEvent deltaX] < 0) {
        return com_sun_glass_events_SwipeGesture_DIR_RIGHT;
    }
    if ([theEvent deltaX] > 0) {
        return com_sun_glass_events_SwipeGesture_DIR_LEFT;
    }
    if ([theEvent deltaY] > 0) {
        return com_sun_glass_events_SwipeGesture_DIR_UP;
    }
    if ([theEvent deltaY] < 0) {
        return com_sun_glass_events_SwipeGesture_DIR_DOWN;
    }
    return 0;
}


@implementation GlassViewDelegate

- (id)initWithView:(NSView*)view withJview:(jobject)jview
{
    self = [super init];
    if (self != nil)
    {
        GET_MAIN_JENV;
        
        self->nsView = view;
        self->jView = (*env)->NewGlobalRef(env, jview);
        self->mouseIsOver = NO;

        self->gestureInProgress = NO;

        self->nativeFullScreenModeWindow = nil;

        // optimization
        [self->nsView allocateGState];

                // register for drag and drop
                [self->nsView registerForDraggedTypes:[NSArray arrayWithObjects:        NSPasteboardTypeString,
                                                                                NSPasteboardTypeTIFF,
                                                                                   NSPasteboardTypeRTF,
                                                                                   NSPasteboardTypeTabularText,
                                                                                   NSPasteboardTypeFont,
                                                                                   NSPasteboardTypeRuler,
                                                                                   NSPasteboardTypeColor,
                                                                                   NSPasteboardTypeRTFD,
                                                                                   NSPasteboardTypeHTML,
                                                                                   NSPasteboardTypePDF,
                                                                                   NSPasteboardTypeMultipleTextSelection,
                                                                                   (NSString*)kUTTypeURL,
                                                                                   (NSString*)kUTTypeFileURL,
                                                                                   (NSString*)@"placeholder.custom.bytes",
                                                                            nil]];
    }
    return self;
}

- (void)dealloc
{
    [self->lastEvent release];
    self->lastEvent = nil;
    
    [self->parentHost release];
    self->parentHost = nil;
    
    [self->parentWindow release];
    self->parentWindow = nil;
    
    [self->fullscreenWindow release];
    self->fullscreenWindow = nil;
    
    GET_MAIN_JENV;
    if (env != NULL)
    {
        (*env)->DeleteGlobalRef(env, self->jView);
    }
    self->jView = NULL;

    [super dealloc];
}

- (jobject)jView
{
    return self->jView;
}

- (void)viewDidMoveToWindow
{
    //        NSLog(@"viewDidMoveToWindow");
    //        NSLog(@"        self: %@", self);
    //        NSLog(@"        [self superview]: %@", [self superview]);
    GET_MAIN_JENV;
    if ([self->nsView window] != nil)
    {
        if (self->parentHost == nil)
        {
            self->parentHost = (GlassHostView*)[[self->nsView superview] retain];
        }
        if (self->parentWindow == nil)
        {
            self->parentWindow = [[self->nsView window] retain];
        }
        
        [[self->nsView window] setAcceptsMouseMovedEvents:YES];
        (*env)->CallVoidMethod(env, self->jView, jViewNotifyEvent, com_sun_glass_events_ViewEvent_ADD);
    }
    else
    {
        if (self->parentWindow != nil)
        {
            [self->parentWindow release];
            self->parentWindow = nil;
        }
        (*env)->CallVoidMethod(env, self->jView, jViewNotifyEvent, com_sun_glass_events_ViewEvent_REMOVE);
    }
}

- (void)setFrameOrigin:(NSPoint)newOrigin
{
    
}

- (void)setFrameSize:(NSSize)newSize
{
    LOG("GlassViewDelegate setFrameSize %fx%f", newSize.width, newSize.height);
    
    //NSLog(@"GlassViewDelegate setFrameSize: %dx%d", (int)newSize.width, (int)newSize.height);
    // TODO: listen for resize view's notifications
    GET_MAIN_JENV;
    (*env)->CallVoidMethod(env, self->jView, jViewNotifyResize, (int)newSize.width, (int)newSize.height);
    GLASS_CHECK_EXCEPTION(env);
    
    [self->nsView removeTrackingRect:self->trackingRect];
    self->trackingRect = [self->nsView addTrackingRect:[self->nsView bounds] owner:self->nsView userData:nil assumeInside:NO];
}

- (void)setFrame:(NSRect)frameRect
{
    LOG("GlassViewDelegate setFrame %fx%f", frameRect.size.width, frameRect.size.height);
    
    //NSLog(@"GlassViewDelegate setFrame: %d,%d %dx%d", (int)frameRect.origin.x, (int)frameRect.origin.y, (int)frameRect.size.width, (int)frameRect.size.height);
    // TODO: listen for resize view's notifications
    GET_MAIN_JENV;
    (*env)->CallVoidMethod(env, self->jView, jViewNotifyResize, (int)frameRect.size.width, (int)frameRect.size.height);
    GLASS_CHECK_EXCEPTION(env);
    
    [self->nsView removeTrackingRect:self->trackingRect];
    self->trackingRect = [self->nsView addTrackingRect:[self->nsView bounds] owner:self->nsView userData:nil assumeInside:NO];
}

- (void)updateTrackingAreas
{
    [self->nsView removeTrackingRect:self->trackingRect];
    self->trackingRect = [self->nsView addTrackingRect:[self->nsView bounds] owner:self->nsView userData:nil assumeInside:NO];
}

- (void)drawRect:(NSRect)dirtyRect
{
    //NSLog(@"BEGIN View:drawRect %@: ", self);
    //NSLog(@"        [self frame]: %f,%f %fx%f", [self->nsView frame].origin.x, [self->nsView frame].origin.y, [self->nsView frame].size.width, [self->nsView frame].size.height);
    GET_MAIN_JENV;
    jint x = (jint)[self->nsView frame].origin.x;
    jint y = (jint)[self->nsView frame].origin.y;
    jint w = (jint)[self->nsView frame].size.width;
    jint h = (jint)[self->nsView frame].size.height;
    (*env)->CallVoidMethod(env, self->jView, jViewNotifyRepaint, x, y, w, h);
    GLASS_CHECK_EXCEPTION(env);
    //NSLog(@"END drawRect");
}

- (void)sendJavaMenuEvent:(NSEvent *)theEvent
{
//    NSLog(@"sendJavaMenuEvent");
    NSWindow * nswindow = [nsView window];
    if (nswindow && [[nswindow delegate] isKindOfClass: [GlassWindow class]]) {
        GlassWindow *window = (GlassWindow*)[nswindow delegate];
        if (!window->isEnabled) {
            return;
        }
    }
    NSPoint viewPoint = [nsView convertPoint:[theEvent locationInWindow] fromView:nil]; // convert from window coordinates to view coordinates
    CGPoint basePoint = CGEventGetLocation([theEvent CGEvent]);

    GET_MAIN_JENV;
    jboolean isKeyboardTrigger = JNI_FALSE;
    (*env)->CallVoidMethod(env, self->jView, jViewNotifyMenu, 
                            (jint)viewPoint.x, (jint)viewPoint.y, (jint)basePoint.x, (jint)basePoint.y, isKeyboardTrigger);
    GLASS_CHECK_EXCEPTION(env);
}

- (void)sendJavaMouseEvent:(NSEvent *)theEvent
{
    NSWindow * nswindow = [nsView window];
    if (nswindow && [[nswindow delegate] isKindOfClass: [GlassWindow class]]) {
        GlassWindow *window = (GlassWindow*)[nswindow delegate];
        if (!window->isEnabled) {
            return;
        }
    }

    int type = 0;
    int button = com_sun_glass_events_MouseEvent_BUTTON_NONE;
    switch ([theEvent type])
    {
        case NSLeftMouseDown:
            type = com_sun_glass_events_MouseEvent_DOWN;
            button = com_sun_glass_events_MouseEvent_BUTTON_LEFT;
            break;
        case NSRightMouseDown:
            type = com_sun_glass_events_MouseEvent_DOWN;
            button = com_sun_glass_events_MouseEvent_BUTTON_RIGHT;
            break;
        case NSOtherMouseDown:
            type = com_sun_glass_events_MouseEvent_DOWN;
            button = com_sun_glass_events_MouseEvent_BUTTON_OTHER;
            break;
            
        case NSLeftMouseUp:
            type = com_sun_glass_events_MouseEvent_UP;
            button = com_sun_glass_events_MouseEvent_BUTTON_LEFT;
            break;
        case NSRightMouseUp:
            type = com_sun_glass_events_MouseEvent_UP;
            button = com_sun_glass_events_MouseEvent_BUTTON_RIGHT;
            break;
        case NSOtherMouseUp:
            type = com_sun_glass_events_MouseEvent_UP;
            button = com_sun_glass_events_MouseEvent_BUTTON_OTHER;
            break;
            
        case NSLeftMouseDragged:
            type = com_sun_glass_events_MouseEvent_DRAG;
            button = com_sun_glass_events_MouseEvent_BUTTON_LEFT;
            break;
        case NSRightMouseDragged:
            type = com_sun_glass_events_MouseEvent_DRAG;
            button = com_sun_glass_events_MouseEvent_BUTTON_RIGHT;
            break;
        case NSOtherMouseDragged:
            type = com_sun_glass_events_MouseEvent_DRAG;
            button = com_sun_glass_events_MouseEvent_BUTTON_OTHER;
            break;
            
        case NSMouseMoved:
            type = com_sun_glass_events_MouseEvent_MOVE;
            break;
            
        case NSMouseEntered:
            type = com_sun_glass_events_MouseEvent_ENTER;
            self->lastTrackingNumber = [theEvent trackingNumber];
            break;
            
        case NSMouseExited:
            type = com_sun_glass_events_MouseEvent_EXIT;
            self->lastTrackingNumber = [theEvent trackingNumber];
            break;
            
        case NSScrollWheel:
            type = com_sun_glass_events_MouseEvent_WHEEL;
            break;
    }
    
    NSPoint viewPoint = [nsView convertPoint:[theEvent locationInWindow] fromView:nil]; // convert from window coordinates to view coordinates
    CGPoint basePoint = CGEventGetLocation([theEvent CGEvent]);

    if (type == com_sun_glass_events_MouseEvent_MOVE)
    {
        NSRect frame = [nsView frame];

        if (viewPoint.x < 0 || viewPoint.y < 0 ||
                viewPoint.x >= frame.size.width ||
                viewPoint.y >= frame.size.height)
        {
            // The MOVE events happening outside of the view must be ignored
            return;
        }

        // Check if the event is a duplicate
        if (self->lastEvent)
        {
            CGPoint oldBasePoint = CGEventGetLocation([self->lastEvent CGEvent]);

            if (basePoint.x == oldBasePoint.x && basePoint.y == oldBasePoint.y)
            {
                return;
            }
        }
    }
    
        //    NSLog(@"Event location: in window %@, in view %@, in base coordinates %d,%d",
        //          NSStringFromPoint([theEvent locationInWindow]),
        //          NSStringFromPoint(viewPoint),
        //          (jint)basePoint.x, (jint)basePoint.y);
        
    jdouble rotationX = 0.0;
    jdouble rotationY = 0.0;
    if (type == com_sun_glass_events_MouseEvent_WHEEL)
    {
        rotationX = (jdouble)[theEvent deltaX];
        rotationY = (jdouble)[theEvent deltaY];

        //XXX: check for equality for doubles???
        if (rotationX == 0.0 && rotationY == 0.0)
        {
            return;
        }

        // The rotation values start from 0.1 because by default Mac divides
        // the values to a constant value of 10 (see CGEventSource.h and
        // CGEventSourceGetPixelsPerLine). So we multiply them to get scroll
        // amounts in pixels.
        rotationX *= 10.0;
        rotationY *= 10.0;
    }
    
    BOOL block = NO;
    {
        // RT-5892
        if ((type == com_sun_glass_events_MouseEvent_ENTER) || (type == com_sun_glass_events_MouseEvent_EXIT))
        {
            // userData indicates if this is a synthesized EXIT event that MUST pass through
            // Note: userData is only valid for ENTER/EXIT events!
            if (self->mouseIsDown == YES && [theEvent userData] != self)
            {
                block = [self suppressMouseEnterExitOnMouseDown];
            }
        }
        else
        {
            // for the mouse supression we can not look at the mouse down state during ENTER/EXIT events
            // as they always report mouse up regardless of the actual state, so we need to store it
            // based on the events other than ENTER/EXIT
            self->mouseIsDown = (button != com_sun_glass_events_MouseEvent_BUTTON_NONE);
        }
    }
    if (block == NO)
    {
        if (!self->mouseIsOver &&
                type != com_sun_glass_events_MouseEvent_ENTER &&
                type != com_sun_glass_events_MouseEvent_EXIT)
        {
            // OS X didn't send mouseEnter. Synthesize it here.
            NSEvent *eeEvent = [NSEvent enterExitEventWithType:NSMouseEntered
                                                      location:[theEvent locationInWindow]
                                                 modifierFlags:[theEvent modifierFlags]
                                                     timestamp:[theEvent timestamp]
                                                  windowNumber:[theEvent windowNumber]
                                                       context:[theEvent context]
                                                   eventNumber:0
                                                trackingNumber:self->lastTrackingNumber
                                                      userData:self];
            [self sendJavaMouseEvent:eeEvent];
        }

        jint modifiers = GetJavaModifiers(theEvent);
        if (type != com_sun_glass_events_MouseEvent_UP)
        {
            switch (button)
            {
                case com_sun_glass_events_MouseEvent_BUTTON_LEFT:
                    modifiers |= com_sun_glass_events_KeyEvent_MODIFIER_BUTTON_PRIMARY;
                    break;
                case com_sun_glass_events_MouseEvent_BUTTON_RIGHT:
                    modifiers |= com_sun_glass_events_KeyEvent_MODIFIER_BUTTON_SECONDARY;
                    break;
                case com_sun_glass_events_MouseEvent_BUTTON_OTHER:
                    modifiers |= com_sun_glass_events_KeyEvent_MODIFIER_BUTTON_MIDDLE;
                    break;
            }
        }
        
        jboolean isSynthesized = JNI_FALSE;
        
        jboolean isPopupTrigger = JNI_FALSE;
        if (type == com_sun_glass_events_MouseEvent_DOWN) {
            if (button == com_sun_glass_events_MouseEvent_BUTTON_RIGHT) {
                isPopupTrigger = JNI_TRUE;
            }
            if (button == com_sun_glass_events_MouseEvent_BUTTON_LEFT &&
                (modifiers & com_sun_glass_events_KeyEvent_MODIFIER_CONTROL))
            {
                isPopupTrigger = JNI_TRUE;
            }
        }
        
        [self->lastEvent release];
        self->lastEvent = nil;
        switch (type) {
            // prepare GlassDragSource for possible drag,
            case com_sun_glass_events_MouseEvent_DOWN:
            case com_sun_glass_events_MouseEvent_DRAG:
                [GlassDragSource setDelegate:self];
                // fall through to save the lastEvent
            // or for filtering out duplicate MOVE events
            case com_sun_glass_events_MouseEvent_MOVE:
                self->lastEvent = [theEvent retain];
                break;


            // Track whether the mouse is over the view
            case com_sun_glass_events_MouseEvent_ENTER:
                self->mouseIsOver = YES;
                break;
            case com_sun_glass_events_MouseEvent_EXIT:
                self->mouseIsOver = NO;
                break;
        }
        
        GET_MAIN_JENV;
        if (type == com_sun_glass_events_MouseEvent_WHEEL) {
            // Detect mouse wheel event sender. 
            // Can be inertia from scroll gesture, 
            // scroll gesture or mouse wheel itself
            //
            // RT-22388
            jint sender = com_sun_glass_ui_mac_MacGestureSupport_SCROLL_SRC_WHEEL;
            if (self->gestureInProgress == YES) {
                if (isInertialScroll(theEvent)) {
                   sender = com_sun_glass_ui_mac_MacGestureSupport_SCROLL_SRC_INERTIA;
                }
                else {
                    sender = com_sun_glass_ui_mac_MacGestureSupport_SCROLL_SRC_GESTURE;
                }
            }
            
            const jclass jGestureSupportClass = [GlassHelper ClassForName:"com.sun.glass.ui.mac.MacGestureSupport"
                                                                  withEnv:env];
            if (jGestureSupportClass)
            {
                (*env)->CallStaticVoidMethod(env, jGestureSupportClass,
                                             javaIDs.GestureSupport.scrollGesturePerformed,
                                             self->jView, modifiers, sender,
                                             (jint)viewPoint.x, (jint)viewPoint.y,
                                             (jint)basePoint.x, (jint)basePoint.y,
                                             rotationX, rotationY);
            }
        } else {
            (*env)->CallVoidMethod(env, self->jView, jViewNotifyMouse, type, button, 
                    (jint)viewPoint.x, (jint)viewPoint.y, (jint)basePoint.x, (jint)basePoint.y, 
                    modifiers, isPopupTrigger, isSynthesized);
        }
        GLASS_CHECK_EXCEPTION(env);
    }
}

- (void)resetMouseTracking
{
    if (self->mouseIsOver) {
        // Nothing of the parameters really matters for the EXIT event, except userData
        NSEvent* theEvent = [NSEvent
            enterExitEventWithType:NSMouseExited
                          location:[NSEvent mouseLocation]
                     modifierFlags:0
                         timestamp:[NSDate timeIntervalSinceReferenceDate]
                      windowNumber:[[self->nsView window] windowNumber]
                           context:[NSGraphicsContext currentContext]
                       eventNumber:0
                    trackingNumber:self->lastTrackingNumber
                          userData:self]; // indicates that this is a synthesized event

        [self sendJavaMouseEvent:theEvent];
    }
}

// RT-11707: zero out the keycode for TYPED events
#define SEND_KEY_EVENT(type) \
    (*env)->CallVoidMethod(env, self->jView, jViewNotifyKey, (type), \
            (type) == com_sun_glass_events_KeyEvent_TYPED ? 0 : jKeyCode, \
            jKeyChars, jModifiers); \
    GLASS_CHECK_EXCEPTION(env);

- (void)sendJavaKeyEvent:(NSEvent *)theEvent isDown:(BOOL)isDown
{
    if (theEvent == s_lastKeyEvent) {
        // this must be a keyDown: generated by performKeyEquivalent: which returns NO by design
        return;
    }
    [s_lastKeyEvent release];
    s_lastKeyEvent = [theEvent retain];

    GET_MAIN_JENV;

    jint jKeyCode = GetJavaKeyCode(theEvent);
    jcharArray jKeyChars = GetJavaKeyChars(env, theEvent);
    jint jModifiers = GetJavaModifiers(theEvent);

    // Short circuit here: If this is a synthetic key-typed from a text event
    // post it and return.
    if ([theEvent isKindOfClass:[GlassNSEvent class]]) {
        if ([(GlassNSEvent *)theEvent isSyntheticKeyTyped]) {
            SEND_KEY_EVENT(com_sun_glass_events_KeyEvent_TYPED);
            (*env)->DeleteLocalRef(env, jKeyChars);
            return;
        }
    }

    if (!isDown)
    {
        SEND_KEY_EVENT(com_sun_glass_events_KeyEvent_RELEASE);
    }
    else
    {
        SEND_KEY_EVENT(com_sun_glass_events_KeyEvent_PRESS);

        // In the applet case, FireFox always sends a text input event after every
        // key-pressed, which gets turned into a TYPED event for simple key strokes.
        // The NPAPI support code will send a boolean to let us know if we need to
        // generate the TYPED, or if we should expect the input method support to do it.
        BOOL sendKeyTyped = YES;

        if ([theEvent isKindOfClass:[GlassNSEvent class]]) {
            sendKeyTyped = [(GlassNSEvent *)theEvent needsKeyTyped];
        }

        // TYPED events should only be sent for printable characters. Thus we avoid
        // sending them for navigation keys. Perhaps this logic could be enhanced.
        if (sendKeyTyped) {
            if (jKeyCode < com_sun_glass_events_KeyEvent_VK_PAGE_UP ||
                jKeyCode > com_sun_glass_events_KeyEvent_VK_DOWN)
            {
                SEND_KEY_EVENT(com_sun_glass_events_KeyEvent_TYPED);
            }

            // Quirk in Firefox: If we have to generate a key-typed and this
            // event is a repeat we will also need to generate a fake RELEASE event
            // because we won't see a key-release.
            if ([theEvent isARepeat]) {
                SEND_KEY_EVENT(com_sun_glass_events_KeyEvent_RELEASE);
            }
        }

        // Mac doesn't send keyUp for Cmd+<> key combinations (including Shift+Cmd+<>, etc.)
        // So we synthesize the event
        if (jModifiers & com_sun_glass_events_KeyEvent_MODIFIER_COMMAND)
        {
            SEND_KEY_EVENT(com_sun_glass_events_KeyEvent_RELEASE);
        }
    }

    (*env)->DeleteLocalRef(env, jKeyChars);
    GLASS_CHECK_EXCEPTION(env);
}

#define SEND_MODIFIER_KEY_EVENT_WITH_TYPE(type, vkCode) \
        (*env)->CallVoidMethod(env, self->jView, jViewNotifyKey, \
                (type), \
                (vkCode), \
                jKeyChars, jModifiers);

#define SEND_MODIFIER_KEY_EVENT(mask, vkCode) \
    if (changedFlags & (mask)) { \
        SEND_MODIFIER_KEY_EVENT_WITH_TYPE(currentFlags & (mask) ? com_sun_glass_events_KeyEvent_PRESS : com_sun_glass_events_KeyEvent_RELEASE, vkCode); \
        GLASS_CHECK_EXCEPTION(env); \
    }

- (void)sendJavaModifierKeyEvent:(NSEvent *)theEvent
{
    NSUInteger currentFlags = [theEvent modifierFlags] & NSDeviceIndependentModifierFlagsMask;
    NSUInteger changedFlags = currentFlags ^ s_modifierFlags;

    jint jModifiers = GetJavaModifiers(theEvent);

    GET_MAIN_JENV;
    jcharArray jKeyChars = (*env)->NewCharArray(env, 0);

    SEND_MODIFIER_KEY_EVENT(NSShiftKeyMask,       com_sun_glass_events_KeyEvent_VK_SHIFT);
    SEND_MODIFIER_KEY_EVENT(NSControlKeyMask,     com_sun_glass_events_KeyEvent_VK_CONTROL);
    SEND_MODIFIER_KEY_EVENT(NSAlternateKeyMask,   com_sun_glass_events_KeyEvent_VK_ALT);
    SEND_MODIFIER_KEY_EVENT(NSCommandKeyMask,     com_sun_glass_events_KeyEvent_VK_COMMAND);

    // For CapsLock both PRESS and RELEASE should be synthesized each time
    if (changedFlags & NSAlphaShiftKeyMask) {
        SEND_MODIFIER_KEY_EVENT_WITH_TYPE(com_sun_glass_events_KeyEvent_PRESS, com_sun_glass_events_KeyEvent_VK_CAPS_LOCK);
        SEND_MODIFIER_KEY_EVENT_WITH_TYPE(com_sun_glass_events_KeyEvent_RELEASE, com_sun_glass_events_KeyEvent_VK_CAPS_LOCK);
    }

    (*env)->DeleteLocalRef(env, jKeyChars);
    GLASS_CHECK_EXCEPTION(env);

    s_modifierFlags = currentFlags;
}

- (void)sendJavaGestureEvent:(NSEvent *)theEvent type:(int)type
{
    NSPoint viewPoint = [nsView convertPoint:[theEvent locationInWindow] fromView:nil]; // convert from window coordinates to view coordinates
    CGPoint basePoint = CGEventGetLocation([theEvent CGEvent]);

    jint modifiers = GetJavaModifiers(theEvent);

    GET_MAIN_JENV;
    const jclass jGestureSupportClass = [GlassHelper ClassForName:"com.sun.glass.ui.mac.MacGestureSupport"
                                                          withEnv:env];
    if (jGestureSupportClass)
    {
        switch (type)
        {
            case com_sun_glass_ui_mac_MacGestureSupport_GESTURE_ROTATE:
                (*env)->CallStaticVoidMethod(env, jGestureSupportClass,
                                             javaIDs.GestureSupport.rotateGesturePerformed,
                                             self->jView, modifiers,
                                             (jint)viewPoint.x, (jint)viewPoint.y,
                                             (jint)basePoint.x, (jint)basePoint.y,
                                             (jfloat)[theEvent rotation]);
                break;
            case com_sun_glass_ui_mac_MacGestureSupport_GESTURE_SWIPE:
                (*env)->CallStaticVoidMethod(env, jGestureSupportClass,
                                             javaIDs.GestureSupport.swipeGesturePerformed,
                                             self->jView, modifiers,
                                             getSwipeDirFromEvent(theEvent),
                                             (jint)viewPoint.x, (jint)viewPoint.y,
                                             (jint)basePoint.x, (jint)basePoint.y);
                break;
            case com_sun_glass_ui_mac_MacGestureSupport_GESTURE_MAGNIFY:
                (*env)->CallStaticVoidMethod(env, jGestureSupportClass,
                                             javaIDs.GestureSupport.magnifyGesturePerformed,
                                             self->jView, modifiers,
                                             (jint)viewPoint.x, (jint)viewPoint.y,
                                             (jint)basePoint.x, (jint)basePoint.y,
                                             (jfloat)[theEvent magnification]);
                break;
        }
    }
    GLASS_CHECK_EXCEPTION(env);
}

- (void)sendJavaGestureBeginEvent:(NSEvent *)theEvent
{
    self->gestureInProgress = YES;
}

- (void)sendJavaGestureEndEvent:(NSEvent *)theEvent
{
    self->gestureInProgress = NO;

    NSPoint viewPoint = [nsView convertPoint:[theEvent locationInWindow] fromView:nil]; // convert from window coordinates to view coordinates
    CGPoint basePoint = CGEventGetLocation([theEvent CGEvent]);

    jint modifiers = GetJavaModifiers(theEvent);

    GET_MAIN_JENV;
    const jclass jGestureSupportClass = [GlassHelper ClassForName:"com.sun.glass.ui.mac.MacGestureSupport"
                                                          withEnv:env];
    if (jGestureSupportClass)
    {
        (*env)->CallStaticVoidMethod(env, jGestureSupportClass,
                                     javaIDs.GestureSupport.gestureFinished,
                                     self->jView, modifiers,
                                     (jint)viewPoint.x, (jint)viewPoint.y,
                                     (jint)basePoint.x, (jint)basePoint.y);

    }
    GLASS_CHECK_EXCEPTION(env);
}

- (NSDragOperation)sendJavaDndEvent:(id <NSDraggingInfo>)info type:(jint)type
{
    GET_MAIN_JENV;
    
    NSPoint draggingLocation = [nsView convertPoint:[info draggingLocation] fromView:nil];
    int x = (int)draggingLocation.x;
    int y = (int)draggingLocation.y;
    int xAbs = (int)(x + [self->nsView window].frame.origin.x + [self->nsView frame].origin.x);
    int yAbs = (int)(y + [self->nsView window].frame.origin.y + [self->nsView frame].origin.y);
    int mask;
    
    NSDragOperation operation = [info draggingSourceOperationMask];
    jint recommendedAction = [GlassDragSource mapNsOperationToJavaMask:operation];
    [GlassDragSource setMask:recommendedAction];
    switch (type)
    {
        case com_sun_glass_events_DndEvent_ENTER:
            DNDLOG("com_sun_glass_events_DndEvent_ENTER");
            mask = (*env)->CallIntMethod(env, self->jView, jViewNotifyDragEnter, x, y, xAbs, yAbs, recommendedAction);
            [GlassDragSource setMask:mask];
            break;
        case com_sun_glass_events_DndEvent_UPDATE:
            DNDLOG("com_sun_glass_events_DndEvent_UPDATE");
            mask = (*env)->CallIntMethod(env, self->jView, jViewNotifyDragOver, x, y, xAbs, yAbs, recommendedAction);
            [GlassDragSource setMask:mask];
            break;
        case com_sun_glass_events_DndEvent_PERFORM:
            DNDLOG("com_sun_glass_events_DndEvent_PERFORM");
            mask = (*env)->CallIntMethod(env, self->jView, jViewNotifyDragDrop, x, y, xAbs, yAbs, recommendedAction);
            [GlassDragSource setMask:mask];
            break;
        case com_sun_glass_events_DndEvent_END:
            //TODO: this doesn't belong here. END is for drag source.
            DNDLOG("com_sun_glass_events_DndEvent_END");
            (*env)->CallVoidMethod(env, self->jView, jViewNotifyDragEnd, recommendedAction);
            [GlassDragSource setMask:com_sun_glass_ui_Clipboard_ACTION_NONE];
            break;
        case com_sun_glass_events_DndEvent_EXIT:
            DNDLOG("com_sun_glass_events_DndEvent_EXIT");
            (*env)->CallVoidMethod(env, self->jView, jViewNotifyDragLeave);
            [GlassDragSource setMask:com_sun_glass_ui_Clipboard_ACTION_NONE];
            break;
        default:
            [GlassDragSource setMask:com_sun_glass_ui_Clipboard_ACTION_NONE];
            break;
    }
    
    GLASS_CHECK_EXCEPTION(env);
    
    return [GlassDragSource mapJavaMaskToNsOperation:[GlassDragSource getMask]];
}

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    return self->dragOperation;
}

// called from Java layer drag handler, triggered by DnD Pasteboard flush
- (void)startDrag:(NSDragOperation)operation
{
    DNDLOG("startDrag");
    self->dragOperation = operation;
    {
        NSPoint dragPoint = [self->nsView convertPoint:[self->lastEvent locationInWindow] fromView:nil];
        NSPasteboard *pasteboard = [NSPasteboard pasteboardWithName:NSDragPboard];
        NSImage *image = nil;

        if ([[pasteboard types] containsObject:DRAG_IMAGE_MIME]) {
            //Try to init with drag image specified by the user
            image = [[NSImage alloc] initWithData:[pasteboard dataForType:DRAG_IMAGE_MIME]];
        }
        
        if (image == nil && [NSImage canInitWithPasteboard:pasteboard] == YES)
        {
            // ask the Pasteboard for ist own image representation of its contents
            image = [[NSImage alloc] initWithPasteboard:pasteboard];
        }

        if (image != nil)
        {
            // check the drag image size and scale it down as needed using Safari behavior (sizes) as reference
            CGFloat width = [image size].width;
            CGFloat height = [image size].height;
            if ((width > MAX_DRAG_SIZE) || (height > MAX_DRAG_SIZE))
            {
                if (width >= height)
                {
                    CGFloat ratio = height/width;
                    width = MIN(width, MAX_DRAG_SIZE);
                    height = ratio * width;
                    [image setSize:NSMakeSize(width, height)];
                }
                else
                {
                    CGFloat ratio = width/height;
                    height = MIN(height, MAX_DRAG_SIZE);
                    width = ratio * height;
                    [image setSize:NSMakeSize(width, height)];
                }
            }
        } else {
            NSArray *items = [pasteboard pasteboardItems];
            // NOTE:  There is always a placeholder item on the pasteboard, subtract it
            if ([items count] - 1 == 1)
            {
                image = [[NSImage alloc] initWithContentsOfFile:@"/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"];
            }
            
            if (image == nil)
            {
                image = [[NSImage imageNamed:NSImageNameMultipleDocuments] retain];
            }
            
            [image setSize:NSMakeSize(DEFAULT_DRAG_SIZE, DEFAULT_DRAG_SIZE)];
        }
        
        if (image != nil)
        {
            // select the center of the image as the drag origin
            // TODO http://javafx-jira.kenai.com/browse/RT-17629
            // would be nice to get this info from the Java layer,
            // so that we could adjust the drag image origin based on where in the src it was clicked on       
            dragPoint.x -= ([image size].width/2.0f);
            dragPoint.y += ([image size].height/2.0f);
            
            NSString *offsetString = [pasteboard stringForType:DRAG_IMAGE_OFFSET];
            if (offsetString != nil) {
                NSPoint offset = NSPointFromString(offsetString);
                //Adjust offset to the image size
                float imageHalfX = [image size].width/2.0f;
                float imageHalfY = [image size].height/2.0f;

                if (offset.x > imageHalfX || offset.x < -imageHalfX) {
                    offset.x = imageHalfX * (offset.x > 0 ? 1 : -1);
                }
                if (offset.y > imageHalfY || offset.y < -imageHalfY) {
                    offset.y = imageHalfY * (offset.y > 0 ? 1 : -1);
                }
                
                dragPoint.x += offset.x;
                dragPoint.y -= offset.y;
            }
        }
        else
        {
            // last resource: "empty" image
            image = [[NSImage alloc] initWithSize:NSMakeSize(1.0f, 1.0f)];
        }
        [self->nsView dragImage:image at:dragPoint offset:NSZeroSize event:self->lastEvent pasteboard:pasteboard source:self->nsView slideBack:YES];
        
        // main thread blocked here until drag completes
        
        [GlassDragSource setDelegate:nil];
        
        [image release];
    }
    self->dragOperation = NSDragOperationNone;
}

- (BOOL)suppressMouseEnterExitOnMouseDown
{
    return YES;
}

- (void)notifyInputMethod:(id) aString attr:(int)attr length:(int)length cursor:(int)cursor
{
    if ([NSThread isMainThread] == YES)
    {
        GET_MAIN_JENV;
        jstring jStr = (*env)->NewStringUTF(env, [aString UTF8String]);
        (*env)->CallVoidMethod(env, self->jView, jViewNotifyInputMethodMac, jStr, attr, length, cursor);
        GLASS_CHECK_EXCEPTION(env);
    }
}

- (NSRect)getInputMethodCandidatePosRequest:(int)pos
{
    NSRect retVal = NSMakeRect(0.0, 0.0, 0.0, 0.0);
    if ([NSThread isMainThread] == YES)
    {
        // TODO: For some reason result is not always converted to the screen coordinates,
        // and when we call this method before we set text to updated we get the 
        // IndexOutOfBoundsException
        // In this case we return an empty rectangle so suggestion window is shown at the 
        // bottom left corner of the main screen.
        GET_MAIN_JENV;
        jdoubleArray theArray = 
            (jdoubleArray) (*env)->CallObjectMethod(env, 
                                                    self->jView, 
                                                    jViewNotifyInputMethodCandidatePosRequest, 
                                                    pos);
        if (theArray != NULL) {
            jint n = (*env)->GetArrayLength(env, theArray);
            if (n == 2) {
                jboolean isCopy;
                jdouble *elems = (*env)->GetDoubleArrayElements(env, theArray, &isCopy);
                // We get the screen coordinates of the cursor, to make some room
                // to avoid suggestion window overlapping the next symbol we
                // create rectangle 20x20 pixels as a placeholder for the next glyph.
                retVal = NSMakeRect((CGFloat)elems[0], (CGFloat)elems[1], 20.0, 20.0);
                (*env)->ReleaseDoubleArrayElements(env, theArray, elems, 0);
                (*env)->DeleteLocalRef(env, theArray);
            }
        }
        GLASS_CHECK_EXCEPTION(env);
    }
    return retVal;
}

- (void)sendJavaFullScreenEvent:(BOOL)entered withNativeWidget:(BOOL)isNative
{
    if (isNative) {
        // Must be done before sending the event to Java since the event handler
        // may re-request the operation.
        if (entered) {
            self->nativeFullScreenModeWindow = [[self->nsView window] retain];
        } else {
            [self->nativeFullScreenModeWindow release];
            self->nativeFullScreenModeWindow = nil;
        }
    }

    GET_MAIN_JENV;
    (*env)->CallVoidMethod(env, self->jView, jViewNotifyEvent,
            entered ? com_sun_glass_events_ViewEvent_FULLSCREEN_ENTER : com_sun_glass_events_ViewEvent_FULLSCREEN_EXIT);
    GLASS_CHECK_EXCEPTION(env);
}

/*
 The hierarchy for our view is view -> superview (host) -> window
 
 1. create superview (new host) for our view
 2. create fullscreen window with the new superview
 3. create the background window (for fading out the desktop)
 4. remove our view from the window superview and insert it into the fullscreen window superview
 5. show our fullscreen window (and hide the original window)
 6. attach to it our background window (which will show it as well)
 7. zoom out our fullscreen window and at the same time animate the background window transparency
 8. enter fullscreen
 */
- (void)enterFullscreenWithAnimate:(BOOL)animate withKeepRatio:(BOOL)keepRatio withHideCursor:(BOOL)hideCursor
{
    LOG("GlassViewDelegate enterFullscreenWithAnimate:%d withKeepRatio:%d withHideCursor:%d", animate, keepRatio, hideCursor);
    
    NSScreen *screen = [[self->nsView window] screen];
    
    NSRect frame = [self->nsView bounds];
    NSPoint pointInWindowCoordinates = [self->nsView convertPoint:frame.origin toView:nil];
    // ensure that view's bounds is in unflipped coordinates
    pointInWindowCoordinates.y -= frame.size.height;
    NSPoint pointInScreenCoords = [self->parentWindow convertBaseToScreen:pointInWindowCoordinates];
    frame.origin = pointInScreenCoords;
    //NSLog(@"pointInScreenCoords: %.2f,%.2f", pointInScreenCoords.x, pointInScreenCoords.y);
    
    @try
    {
        // 0. Retain the view while it's in the FS mode
        [self->nsView retain];

        // 1.
        self->fullscreenHost = [[GlassHostView alloc] initWithFrame:[self->nsView bounds]];
        [self->fullscreenHost setAutoresizesSubviews:YES];
        
        // 2.
        self->fullscreenWindow = [[GlassFullscreenWindow alloc] initWithContentRect:frame withHostView:self->fullscreenHost withView:self->nsView withScreen:screen withPoint:pointInScreenCoords];
        
        // 3.
        self->backgroundWindow = [[GlassBackgroundWindow alloc] initWithWindow:self->fullscreenWindow];
        
        [self->parentWindow disableFlushWindow];
        {
            // handle plugin case
            if ([[self->nsView window] isKindOfClass:[GlassEmbeddedWindow class]] == YES)
            {
                GlassEmbeddedWindow *window = (GlassEmbeddedWindow*)self->parentWindow;
                [window setFullscreenWindow:self->fullscreenWindow];
            }
            
            // 4.
            [self->nsView retain];
            {
                [self->nsView removeFromSuperviewWithoutNeedingDisplay];
                [self->fullscreenHost addSubview:self->nsView];
            }
            [self->nsView release];
            
            if ([[self->parentWindow delegate] isKindOfClass:[GlassWindow class]] == YES)
            {
                GlassWindow *window = (GlassWindow*)[self->parentWindow delegate];
                [window setFullscreenWindow:self->fullscreenWindow];
            }
            
            // 5.
            [self->fullscreenWindow setInitialFirstResponder:self->nsView];
            [self->fullscreenWindow makeFirstResponder:self->nsView];
            [self->fullscreenWindow makeKeyAndOrderFront:self->nsView];
            [self->fullscreenWindow makeMainWindow];
        }
        
        // 6.
        [self->fullscreenWindow addChildWindow:self->backgroundWindow ordered:NSWindowBelow];
        
        NSRect screenFrame = [screen frame];
        NSRect fullscreenFrame = [screen frame];
        if (keepRatio == YES)
        {
            CGFloat ratioWidth = (frame.size.width/screenFrame.size.width);
            CGFloat ratioHeight = (frame.size.height/screenFrame.size.height);
            if (ratioWidth > ratioHeight)
            {
                CGFloat ratio = (frame.size.width/frame.size.height);
                fullscreenFrame.size.height = fullscreenFrame.size.width / ratio;
                fullscreenFrame.origin.y = (screenFrame.size.height - fullscreenFrame.size.height) / 2.0f;
            }
            else
            {
                CGFloat ratio = (frame.size.height/frame.size.width);
                fullscreenFrame.size.width = fullscreenFrame.size.height / ratio;
                fullscreenFrame.origin.x = (screenFrame.size.width - fullscreenFrame.size.width) / 2.0f;
            }
        }
        
        // 7.
        //[self->fullscreenWindow setBackgroundColor:[NSColor whiteColor]]; // debug
        [self->fullscreenWindow setFrame:fullscreenFrame display:YES animate:animate];
        
        // 8.
        //[self enterFullScreenMode:[self->fullscreenWindow screen] withOptions:nil];
        self->fullscreenWindow->displayID = [screen enterFullscreenAndHideCursor:hideCursor];
    }
    @catch (NSException *e)
    {
        NSLog(@"enterFullscreenWithAnimate caught exception: %@", e);
    }

    [self sendJavaFullScreenEvent:YES withNativeWidget:NO];
}

- (void)exitFullscreenWithAnimate:(BOOL)animate
{
    LOG("GlassViewDelegate exitFullscreenWithAnimate");
    
    @try
    {
        if (self->nativeFullScreenModeWindow)
        {
            [self->nativeFullScreenModeWindow performSelector:@selector(toggleFullScreen:) withObject:nil];
            // wait until the operation is complete
            [GlassApplication enterFullScreenExitingLoop];
            return;
        }
        
        [[self->fullscreenWindow screen] exitFullscreen:self->fullscreenWindow->displayID];
        
        NSRect frame = [self->parentHost bounds];
        frame.origin = [self->fullscreenWindow point];
        [self->fullscreenWindow setFrame:frame display:YES animate:animate];
        
        [self->fullscreenWindow disableFlushWindow];
        {
            [self->nsView retain];
            {
                [self->nsView removeFromSuperviewWithoutNeedingDisplay];
                [self->parentHost addSubview:self->nsView];
            }
            [self->nsView release];
            
            // handle plugin case
            if ([[self->nsView window] isKindOfClass:[GlassEmbeddedWindow class]] == YES)
            {
                GlassEmbeddedWindow *window = (GlassEmbeddedWindow*)[self->nsView window];
                [window setFullscreenWindow:nil];
            }
            
            [self->parentWindow setInitialFirstResponder:self->nsView];
            [self->parentWindow makeFirstResponder:self->nsView];
            
            if ([[self->parentWindow delegate] isKindOfClass:[GlassWindow class]])
            {
                GlassWindow *window = (GlassWindow*)[self->parentWindow delegate];
                [window setFullscreenWindow: nil];
            }
        }
        [self->fullscreenWindow enableFlushWindow];
        [self->parentWindow enableFlushWindow];
        
        [self->fullscreenWindow orderOut:nil];
        [self->fullscreenWindow close];
        self->fullscreenWindow = nil;
        
        [self->backgroundWindow orderOut:nil];
        [self->backgroundWindow close];
        self->backgroundWindow = nil;

        // It was retained upon entering the FS mode
        [self->nsView release];
    }
    @catch (NSException *e)
    {
        NSLog(@"exitFullscreenWithAnimate caught exception: %@", e);
    }
    
    [self sendJavaFullScreenEvent:NO withNativeWidget:NO];
}

@end