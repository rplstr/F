//! Thin Xlib bindings.
const builtin = @import("builtin");

pub const Display = opaque {};
/// XID type (unsigned long).
pub const Window = usize;

/// Replace existing property data.
pub const PropModeReplace: c_int = 0;
/// X11 Atom type constant (XA_ATOM = 4).
pub const XA_ATOM: c_ulong = 4;

pub const Atom = c_ulong;

pub const KeySym = c_ulong;

pub const KeyPress: c_int = 2;
pub const KeyRelease: c_int = 3;
pub const ButtonPress: c_int = 4;
pub const ButtonRelease: c_int = 5;
pub const MotionNotify: c_int = 6;

pub const ClientMessage: c_int = 33;

pub const PMinSize: c_long = 1 << 4;
pub const PMaxSize: c_long = 1 << 5;

pub extern "X11" fn XDefaultRootWindow(display: *Display) Window;
pub extern "X11" fn XDefaultScreen(display: *Display) c_int;
pub extern "X11" fn XBlackPixel(display: *Display, screen: c_int) c_ulong;
pub extern "X11" fn XWhitePixel(display: *Display, screen: c_int) c_ulong;
pub extern "X11" fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
pub extern "X11" fn XCreateSimpleWindow(
    display: *Display,
    parent: Window,
    x: c_int,
    y: c_int,
    width: c_uint,
    height: c_uint,
    border_width: c_uint,
    border: c_ulong,
    background: c_ulong,
) Window;
pub extern "X11" fn XMapWindow(display: *Display, window: Window) c_int;
pub extern "X11" fn XDestroyWindow(display: *Display, window: Window) c_int;
pub extern "X11" fn XCloseDisplay(display: *Display) c_int;

pub const KeyPressMask: c_long = 1 << 0;
pub const KeyReleaseMask: c_long = 1 << 1;
pub const ButtonPressMask: c_long = 1 << 2;
pub const ButtonReleaseMask: c_long = 1 << 3;
pub const PointerMotionMask: c_long = 1 << 6;

pub extern "X11" fn XSelectInput(display: *Display, w: Window, event_mask: c_long) c_int;

pub extern "X11" fn XDisplayWidth(display: *Display, screen_number: c_int) c_int;
pub extern "X11" fn XDisplayHeight(display: *Display, screen_number: c_int) c_int;

pub extern "X11" fn XInternAtom(display: *Display, name: [*:0]const u8, only_if_exists: c_int) c_ulong;
pub extern "X11" fn XChangeProperty(
    display: *Display,
    w: Window,
    property: c_ulong,
    type: c_ulong,
    format: c_int,
    mode: c_int,
    data: [*]const u8,
    nelements: c_int,
) c_int;
pub extern "X11" fn XFlush(display: *Display) c_int;

pub extern "X11" fn XLookupKeysym(event: *XKeyEvent, index: c_int) KeySym;

pub extern "X11" fn XPending(display: *Display) c_int;
pub extern "X11" fn XNextEvent(display: *Display, event_return: *XEvent) c_int;

pub extern "X11" fn XSetWMProtocols(display: *Display, w: Window, protocols: *Atom, count: c_int) c_int;
pub extern "X11" fn XSetWMNormalHints(display: *Display, w: Window, hints: *XSizeHints) c_int;

pub const XSizeHints = extern struct {
    flags: c_long,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    min_width: c_int,
    min_height: c_int,
    max_width: c_int,
    max_height: c_int,
    width_inc: c_int,
    height_inc: c_int,
    min_aspect_x: c_int,
    min_aspect_y: c_int,
    max_aspect_x: c_int,
    max_aspect_y: c_int,
    base_width: c_int,
    base_height: c_int,
    win_gravity: c_int,
};

pub const XClientMessageEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: extern union {
        b: [20]u8,
        s: [10]c_short,
        l: [5]c_long,
    },
};

pub const XKeyEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

pub const XButtonEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};

pub const XMotionEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: c_int,
};

pub const XEvent = extern union {
    type: c_int,
    xclient: XClientMessageEvent,
    _pad: [192]u8,
};
