const std = @import("std");

/// Documentation.
pub const Point = struct {
    x: i32 = 0,
    y: f64 = 1.5e3,

    pub fn norm(self: Point) f64 {
        // A comment
        return @sqrt(self.y * self.y) + @as(f64, @floatFromInt(self.x));
    }
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var list = [_]u8{ 'a', 0x1F, 3 };
    if (list.len > 0 and true) {
        try stdout.print("Hello, {s}!\n", .{"world"});
    }
    errdefer unreachable;
}
