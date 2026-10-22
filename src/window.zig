const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

const rgfw = @import("rgfw");
pub const InitFlags = rgfw.RGFW_initFlags;
pub const Flags = rgfw.RGFW_windowFlags;
pub const WindowNoBorder = rgfw.RGFW_windowNoBorder;
pub const WindowNoResize = rgfw.RGFW_windowNoResize;
pub const WindowAllowDND = rgfw.RGFW_windowAllowDND;
pub const WindowHideMouse = rgfw.RGFW_windowHideMouse;
pub const WindowFullScreen = rgfw.RGFW_windowFullscreen;
pub const WindowTranslucent = rgfw.RGFW_windowTranslucent;
pub const WindowCenter = rgfw.RGFW_windowCenter;
pub const WindowRawMouse = rgfw.RGFW_windowRawMouse;
pub const WindowScaleToMonitor = rgfw.RGFW_windowScaleToMonitor;
pub const WindowHide = rgfw.RGFW_windowHide;
pub const WindowMaximize = rgfw.RGFW_windowMaximize;
pub const WindowCenterCurosr = rgfw.RGFW_windowCenterCursor;
pub const WindowFloating = rgfw.RGFW_windowFloating;
pub const WindowFocusOnShow = rgfw.RGFW_windowFocusOnShow;
pub const WindowMinimize = rgfw.RGFW_windowMinimize;
pub const WindowFocus = rgfw.RGFW_windowFocus;
pub const WindowCaptureMouse = rgfw.RGFW_windowCaptureMouse;
pub const WindowOpenGL = rgfw.RGFW_windowOpenGL;
pub const WindowEGL = rgfw.RGFW_windowEGL;

pub fn init(className: [*c]const u8, flags: InitFlags) !void {
    if (!builtin.is_test) {
        const status = rgfw.RGFW_init(className, flags);
        if (status != 0) return error.RGFWInitError;
        rgfw.RGFW_setQueueEvents(rgfw.RGFW_TRUE);
    }
}

pub fn deinit() void {
    if (!builtin.is_test) {
        rgfw.RGFW_deinit();
    }
}

pub fn pollEvents() void {
    rgfw.RGFW_pollEvents();
}

pub fn setEventCallback(flag: EventKind, comptime function: *const fn (event: Event) void) void {
    const TypeErased = struct {
        fn callback(raw_event: [*c]const rgfw.RGFW_event) callconv(.c) void {
            const event = Event.convert(raw_event.*);

            @call(.always_inline, function, .{event});
        }
    };
    _ = rgfw.RGFW_setEventCallback(@intFromEnum(flag), TypeErased.callback);
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
        ptr: ?*rgfw.struct_RGFW_monitor,

        pub fn scale(self: *@This()) [2]f32 {
            var x: f32 = 0;
            var y: f32 = 0;

            _ = rgfw.RGFW_monitor_getScale(self.ptr, &x, &y);

            return .{ x, y };
        }
    };
};

pub const Window = window: {
    if (!builtin.is_test) break :window struct {
        ptr: ?*rgfw.struct_RGFW_window,

        pub fn init(
            self: *@This(),
            opts: Options,
        ) !void {
            self.* = .{
                .ptr = undefined,
            };

            self.ptr = rgfw.RGFW_createWindow(
                opts.name,
                opts.x,
                opts.y,
                opts.width,
                opts.height,
                opts.flags,
            ) orelse return error.RGFWCreation;
        }

        pub fn deinit(self: *const @This()) void {
            rgfw.RGFW_window_close(self.ptr);
        }

        pub fn setUserdata(self: *const @This(), ud: ?*anyopaque) void {
            rgfw.RGFW_window_setUserPtr(self.ptr, ud);
        }

        pub fn userdata(self: *const @This()) ?*anyopaque {
            return rgfw.RGFW_window_getUserPtr(self.ptr);
        }

        pub fn popEvent(self: *const @This()) ?Event {
            var ptr: rgfw.RGFW_event = undefined;
            if (rgfw.RGFW_window_checkQueuedEvent(self.ptr, &ptr) == rgfw.RGFW_TRUE) {
                return Event.convert(ptr);
            } else {
                return null;
            }
        }

        pub fn shouldClose(self: *const @This()) bool {
            return rgfw.RGFW_window_shouldClose(self.ptr) == rgfw.RGFW_TRUE;
        }

        pub fn osWindow(self: *const @This()) ?*anyopaque {
            return rgfw.RGFW_window_getWindow_OSX(self.ptr);
        }

        pub fn osView(self: *const @This()) ?*anyopaque {
            return rgfw.RGFW_window_getView_OSX(self.ptr);
        }

        pub fn size(self: *const @This()) ![2]f32 {
            var w: i32 = 0;
            var h: i32 = 0;

            if (rgfw.RGFW_window_getSize(self.ptr, &w, &h) == rgfw.RGFW_TRUE) {
                return .{ @floatFromInt(w), @floatFromInt(h) };
            } else {
                return error.GetSizeError;
            }
        }

        pub fn monitor(self: *const @This()) !Monitor {
            const ptr = rgfw.RGFW_window_getMonitor(self.ptr);

            return .{ .ptr = ptr };
        }

        pub fn mouse(self: *const @This()) ![2]f32 {
            var x: i32 = 0;
            var y: i32 = 0;

            if (rgfw.RGFW_window_getMouse(self.ptr, &x, &y) == rgfw.RGFW_TRUE) {
                return .{ @floatFromInt(x), @floatFromInt(y) };
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

        pub fn size(_: *const @This()) ![2]f32 {
            return .{ 600, 800 };
        }

        pub fn mouse(_: *const @This()) ![2]f32 {
            return .{ 0, 0 };
        }
    };
};

const EventKind = enum(u8) {
    none = rgfw.RGFW_eventNone,
    key_pressed = rgfw.RGFW_keyPressed,
    key_released = rgfw.RGFW_keyReleased,
    key_char = rgfw.RGFW_keyChar,
    mouse_button_pressed = rgfw.RGFW_mouseButtonPressed,
    mouse_button_released = rgfw.RGFW_mouseButtonReleased,
    mouse_scroll = rgfw.RGFW_mouseScroll,
    mouse_motion = rgfw.RGFW_mouseMotion,
    mouse_raw_motion = rgfw.RGFW_mouseRawMotion,
    mouse_enter = rgfw.RGFW_mouseEnter,
    mouse_leave = rgfw.RGFW_mouseLeave,
    window_moved = rgfw.RGFW_windowMoved,
    window_resized = rgfw.RGFW_windowResized,
    window_focus_in = rgfw.RGFW_windowFocusIn,
    window_focus_out = rgfw.RGFW_windowFocusOut,
    window_refresh = rgfw.RGFW_windowRefresh,
    window_close = rgfw.RGFW_windowClose,
    window_maximized = rgfw.RGFW_windowMaximized,
    window_minimized = rgfw.RGFW_windowMinimized,
    window_restored = rgfw.RGFW_windowRestored,
    data_drop = rgfw.RGFW_dataDrop,
    data_drag = rgfw.RGFW_dataDrag,
    scale_updated = rgfw.RGFW_scaleUpdated,
    monitor_connected = rgfw.RGFW_monitorConnected,
    monitor_disconnected = rgfw.RGFW_monitorDisconnected,
};

fn activeMod(mod: rgfw.RGFW_keymod, flag: rgfw.RGFW_keymod) bool {
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

    pub fn convert(ptr: rgfw.RGFW_event) Event {
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
                            .caps_lock = activeMod(ptr.key.mod, rgfw.RGFW_modCapsLock),
                            .num_lock = activeMod(ptr.key.mod, rgfw.RGFW_modNumLock),
                            .control = activeMod(ptr.key.mod, rgfw.RGFW_modControl),
                            .alt = activeMod(ptr.key.mod, rgfw.RGFW_modAlt),
                            .shift = activeMod(ptr.key.mod, rgfw.RGFW_modShift),
                            .super = activeMod(ptr.key.mod, rgfw.RGFW_modSuper),
                            .scroll_lock = activeMod(ptr.key.mod, rgfw.RGFW_modScrollLock),
                        },
                        .value = ptr.key.value,
                        .repeat = ptr.key.repeat == rgfw.RGFW_TRUE,
                    },
                },
                .mouse_raw_motion => .{
                    .mouse_motion = .{
                        .inside = ptr.mouse.inWindow == rgfw.RGFW_TRUE,
                        .x = ptr.delta.x,
                        .y = ptr.delta.y,
                        .type = @enumFromInt(ptr.type),
                    },
                },
                .mouse_motion, .mouse_enter, .mouse_leave => .{
                    .mouse_motion = .{
                        .inside = ptr.mouse.inWindow == rgfw.RGFW_TRUE,
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
        mouse_motion = rgfw.RGFW_mouseMotion,
        mouse_raw_motion = rgfw.RGFW_mouseRawMotion,
        mouse_enter = rgfw.RGFW_mouseEnter,
        mouse_leave = rgfw.RGFW_mouseLeave,
    },
};

pub const WindowUpdate = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    type: enum(u8) {
        window_moved = rgfw.RGFW_windowMoved,
        window_resized = rgfw.RGFW_windowResized,
        window_refresh = rgfw.RGFW_windowRefresh,
        window_close = rgfw.RGFW_windowClose,
        window_maximized = rgfw.RGFW_windowMaximized,
        window_minimized = rgfw.RGFW_windowMinimized,
        window_restored = rgfw.RGFW_windowRestored,
    },
};

pub const Button = enum(u8) {
    left = rgfw.RGFW_mouseLeft,
    middle = rgfw.RGFW_mouseMiddle,
    right = rgfw.RGFW_mouseRight,
    misc1 = rgfw.RGFW_mouseMisc1,
    misc2 = rgfw.RGFW_mouseMisc2,
    misc3 = rgfw.RGFW_mouseMisc3,
    misc4 = rgfw.RGFW_mouseMisc4,
    misc5 = rgfw.RGFW_mouseMisc5,
    final = rgfw.RGFW_mouseFinal,
};

pub const MouseButton = struct {
    button: Button,
    type: enum(u8) {
        mouse_button_pressed = rgfw.RGFW_mouseButtonPressed,
        mouse_button_released = rgfw.RGFW_mouseButtonReleased,
    },
};

pub const MouseScroll = struct {
    x: f32,
    y: f32,
};

pub const Key = struct {
    type: enum(u8) {
        pressed = rgfw.RGFW_keyPressed,
        released = rgfw.RGFW_keyReleased,
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
