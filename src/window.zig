const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const c = @import("c");
pub const InitFlags = c.RGFW_initFlags;
pub const Flags = c.RGFW_windowFlags;
pub const WindowNoBorder = c.RGFW_windowNoBorder;
pub const WindowNoResize = c.RGFW_windowNoResize;
pub const WindowAllowDND = c.RGFW_windowAllowDND;
pub const WindowHideMouse = c.RGFW_windowHideMouse;
pub const WindowFullScreen = c.RGFW_windowFullscreen;
pub const WindowTranslucent = c.RGFW_windowTranslucent;
pub const WindowCenter = c.RGFW_windowCenter;
pub const WindowRawMouse = c.RGFW_windowRawMouse;
pub const WindowScaleToMonitor = c.RGFW_windowScaleToMonitor;
pub const WindowHide = c.RGFW_windowHide;
pub const WindowMaximize = c.RGFW_windowMaximize;
pub const WindowCenterCurosr = c.RGFW_windowCenterCursor;
pub const WindowFloating = c.RGFW_windowFloating;
pub const WindowFocusOnShow = c.RGFW_windowFocusOnShow;
pub const WindowMinimize = c.RGFW_windowMinimize;
pub const WindowFocus = c.RGFW_windowFocus;
pub const WindowCaptureMouse = c.RGFW_windowCaptureMouse;
pub const WindowOpenGL = c.RGFW_windowOpenGL;
pub const WindowEGL = c.RGFW_windowEGL;

pub fn init(className: [*c]const u8, flags: InitFlags) !void {
    if (!builtin.is_test) {
        const status = c.RGFW_init(className, flags);
        if (status != 0) return error.RGFWInitError;
        c.RGFW_setQueueEvents(c.RGFW_TRUE);
    }
}

pub fn deinit() void {
    if (!builtin.is_test) {
        c.RGFW_deinit();
    }
}

pub fn pollEvents() void {
    c.RGFW_pollEvents();
}

pub fn setEventCallback(flag: EventKind, comptime function: *const fn (event: Event) void) void {
    const TypeErased = struct {
        fn callback(raw_event: [*c]const c.RGFW_event) callconv(.c) void {
            const event = Event.convert(raw_event.*);

            @call(.always_inline, function, .{event});
        }
    };
    _ = c.RGFW_setEventCallback(@intFromEnum(flag), TypeErased.callback);
}

pub const Options = struct {
    pub const default: Options = .{
        .name = "Odyssey",
        .x = 0,
        .y = 0,
        .width = 600,
        .height = 800,
        .flags = WindowCenter | WindowFocus,
    };

    name: [:0]const u8,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    flags: Flags,
};

pub const Monitor = monitor: {
    break :monitor struct {
        ptr: ?*c.struct_RGFW_monitor,

        pub fn scale(self: *@This()) [2]f32 {
            var x: f32 = 0;
            var y: f32 = 0;

            _ = c.RGFW_monitor_getScale(self.ptr, &x, &y);

            return .{ x, y };
        }
    };
};

pub const Window = window: {
    if (!builtin.is_test) break :window struct {
        ptr: ?*c.struct_RGFW_window,

        pub fn init(
            self: *@This(),
            opts: Options,
        ) !void {
            self.* = .{
                .ptr = undefined,
            };

            self.ptr = c.RGFW_createWindow(
                opts.name,
                opts.x,
                opts.y,
                opts.width,
                opts.height,
                opts.flags,
            ) orelse return error.RGFWCreation;
        }

        pub fn deinit(self: *const @This()) void {
            c.RGFW_window_close(self.ptr);
        }

        pub fn setUserdata(self: *const @This(), ud: ?*anyopaque) void {
            c.RGFW_window_setUserPtr(self.ptr, ud);
        }

        pub fn userdata(self: *const @This()) ?*anyopaque {
            return c.RGFW_window_getUserPtr(self.ptr);
        }

        pub fn popEvent(self: *const @This()) ?Event {
            var ptr: c.RGFW_event = undefined;
            if (c.RGFW_window_checkQueuedEvent(self.ptr, &ptr) == c.RGFW_TRUE) {
                return Event.convert(ptr);
            } else {
                return null;
            }
        }

        pub fn shouldClose(self: *const @This()) bool {
            return c.RGFW_window_shouldClose(self.ptr) == c.RGFW_TRUE;
        }

        pub fn osWindow(self: *const @This()) ?*anyopaque {
            return c.RGFW_window_getWindow_OSX(self.ptr);
        }

        pub fn osView(self: *const @This()) ?*anyopaque {
            return c.RGFW_window_getView_OSX(self.ptr);
        }

        pub fn size(self: *const @This()) !struct { w: f32, h: f32 } {
            var w: i32 = 0;
            var h: i32 = 0;

            if (c.RGFW_window_getSize(self.ptr, &w, &h) == c.RGFW_TRUE) {
                return .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
            } else {
                return error.GetSizeError;
            }
        }

        pub fn monitor(self: *const @This()) !Monitor {
            const ptr = c.RGFW_window_getMonitor(self.ptr);

            return .{ .ptr = ptr };
        }

        pub fn mouse(self: *const @This()) !struct { x: f32, y: f32 } {
            var x: i32 = 0;
            var y: i32 = 0;

            if (c.RGFW_window_getMouse(self.ptr, &x, &y) == c.RGFW_TRUE) {
                return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
            } else {
                return error.GetMouseError;
            }
        }
    };

    break :window struct {
        pub fn init(
            _: *@This(),
            _: Options,
        ) !void {}

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn size(_: *const @This()) !struct { w: f32, h: f32 } {
            return .{ .w = 600, .h = 800 };
        }

        pub fn mouse(_: *const @This()) !struct { x: f32, y: f32 } {
            return .{ .x = 0, .y = 0 };
        }
    };
};

const EventKind = enum(u8) {
    none = c.RGFW_eventNone,
    key_pressed = c.RGFW_keyPressed,
    key_released = c.RGFW_keyReleased,
    key_char = c.RGFW_keyChar,
    mouse_button_pressed = c.RGFW_mouseButtonPressed,
    mouse_button_released = c.RGFW_mouseButtonReleased,
    mouse_scroll = c.RGFW_mouseScroll,
    mouse_motion = c.RGFW_mouseMotion,
    mouse_raw_motion = c.RGFW_mouseRawMotion,
    mouse_enter = c.RGFW_mouseEnter,
    mouse_leave = c.RGFW_mouseLeave,
    window_moved = c.RGFW_windowMoved,
    window_resized = c.RGFW_windowResized,
    window_focus_in = c.RGFW_windowFocusIn,
    window_focus_out = c.RGFW_windowFocusOut,
    window_refresh = c.RGFW_windowRefresh,
    window_close = c.RGFW_windowClose,
    window_maximized = c.RGFW_windowMaximized,
    window_minimized = c.RGFW_windowMinimized,
    window_restored = c.RGFW_windowRestored,
    data_drop = c.RGFW_dataDrop,
    data_drag = c.RGFW_dataDrag,
    scale_updated = c.RGFW_scaleUpdated,
    monitor_connected = c.RGFW_monitorConnected,
    monitor_disconnected = c.RGFW_monitorDisconnected,
};

fn activeMod(mod: c.RGFW_keymod, flag: c.RGFW_keymod) bool {
    return mod & flag != 0;
}

pub const EventType = union(enum) {
    none,
    key: Key,
    key_char: u32,
    mouse_motion: MouseMotion,
    mouse_button: MouseButton,
    mouse_scroll: MouseScroll,
    window_update: WindowUpdate,
    focus_in,
    focus_out,
    //I don't handle this events yet
    data_drop,
    data_drag,
    scale,
    monitor,
};

pub const Event = struct {
    win: Window,
    type: EventType,

    pub fn convert(ptr: c.RGFW_event) Event {
        return .{
            .win = .{ .ptr = ptr.common.win },
            .type = switch (@as(EventKind, @enumFromInt(ptr.type))) {
                .none => .none,
                .window_focus_in => .focus_in,
                .window_focus_out => .focus_out,
                .key_char => .{ .key_char = ptr.keyChar.value },
                .key_released, .key_pressed => .{
                    .key = .{
                        .type = @enumFromInt(ptr.type),
                        .modifiers = .{
                            .caps_lock = activeMod(ptr.key.mod, c.RGFW_modCapsLock),
                            .num_lock = activeMod(ptr.key.mod, c.RGFW_modNumLock),
                            .control = activeMod(ptr.key.mod, c.RGFW_modControl),
                            .alt = activeMod(ptr.key.mod, c.RGFW_modAlt),
                            .shift = activeMod(ptr.key.mod, c.RGFW_modShift),
                            .super = activeMod(ptr.key.mod, c.RGFW_modSuper),
                            .scroll_lock = activeMod(ptr.key.mod, c.RGFW_modScrollLock),
                        },
                        .value = ptr.key.value,
                        .repeat = ptr.key.repeat == c.RGFW_TRUE,
                    },
                },
                .mouse_raw_motion => .{
                    .mouse_motion = .{
                        .inside = ptr.mouse.inWindow == c.RGFW_TRUE,
                        .x = ptr.delta.x,
                        .y = ptr.delta.y,
                        .type = @enumFromInt(ptr.type),
                    },
                },
                .mouse_motion, .mouse_enter, .mouse_leave => .{
                    .mouse_motion = .{
                        .inside = ptr.mouse.inWindow == c.RGFW_TRUE,
                        .x = @floatFromInt(ptr.mouse.x),
                        .y = @floatFromInt(ptr.mouse.y),
                        .type = @enumFromInt(ptr.type),
                    },
                },
                .mouse_button_released, .mouse_button_pressed => .{
                    .mouse_button = .{
                        .button = @enumFromInt(ptr.button.value),
                        .type = @enumFromInt(ptr.type),
                    },
                },
                .mouse_scroll => .{
                    .mouse_scroll = .{ .x = ptr.delta.x, .y = ptr.delta.y },
                },
                .window_moved,
                .window_resized,
                .window_refresh,
                .window_close,
                .window_maximized,
                .window_minimized,
                .window_restored,
                => .{
                    .window_update = .{
                        .x = @floatFromInt(ptr.update.x),
                        .y = @floatFromInt(ptr.update.y),
                        .width = @floatFromInt(ptr.update.w),
                        .height = @floatFromInt(ptr.update.h),
                        .type = @enumFromInt(ptr.type),
                    },
                },
                .data_drop => .data_drop,
                .data_drag => .data_drag,
                .scale_updated => .scale,
                .monitor_connected => .monitor,
                .monitor_disconnected => .monitor,
            },
        };
    }
};

pub const MouseMotion = struct {
    x: f32,
    y: f32,
    inside: bool,
    type: enum(u8) {
        mouse_motion = c.RGFW_mouseMotion,
        mouse_raw_motion = c.RGFW_mouseRawMotion,
        mouse_enter = c.RGFW_mouseEnter,
        mouse_leave = c.RGFW_mouseLeave,
    },
};

pub const WindowUpdate = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    type: enum(u8) {
        window_moved = c.RGFW_windowMoved,
        window_resized = c.RGFW_windowResized,
        window_refresh = c.RGFW_windowRefresh,
        window_close = c.RGFW_windowClose,
        window_maximized = c.RGFW_windowMaximized,
        window_minimized = c.RGFW_windowMinimized,
        window_restored = c.RGFW_windowRestored,
    },
};

pub const Button = enum(u8) {
    left = c.RGFW_mouseLeft,
    middle = c.RGFW_mouseMiddle,
    right = c.RGFW_mouseRight,
    misc1 = c.RGFW_mouseMisc1,
    misc2 = c.RGFW_mouseMisc2,
    misc3 = c.RGFW_mouseMisc3,
    misc4 = c.RGFW_mouseMisc4,
    misc5 = c.RGFW_mouseMisc5,
    final = c.RGFW_mouseFinal,
};

pub const MouseButton = struct {
    button: Button,
    type: enum(u8) {
        mouse_button_pressed = c.RGFW_mouseButtonPressed,
        mouse_button_released = c.RGFW_mouseButtonReleased,
    },
};

pub const MouseScroll = struct {
    x: f32,
    y: f32,
};

pub const Key = struct {
    type: enum(u8) {
        pressed = c.RGFW_keyPressed,
        released = c.RGFW_keyReleased,
    },
    value: u16,
    modifiers: Modifiers,
    repeat: bool,
};

pub const Modifiers = packed struct {
    caps_lock: bool = false,
    num_lock: bool = false,
    control: bool = false,
    alt: bool = false,
    shift: bool = false,
    super: bool = false,
    scroll_lock: bool = false,
};
