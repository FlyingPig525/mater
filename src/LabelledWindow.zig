const vaxis = @import("vaxis");
const Color = vaxis.Color;
const BorderOptions = vaxis.Window.BorderOptions;
const Cell = vaxis.Cell;

const single_rounded: [6][]const u8 = .{ "╭", "─", "╮", "│", "╯", "╰" };
const single_square: [6][]const u8 = .{ "┌", "─", "┐", "│", "┘", "└" };

pub fn init(label: []const u8, color: Color, parent: vaxis.Window, opts: vaxis.Window.ChildOptions) vaxis.Window {
    var result = initChild(parent, opts.x_off, opts.y_off, opts.width, opts.height);

    const glyphs = switch (opts.border.glyphs) {
        .single_rounded => single_rounded,
        .single_square => single_square,
        .custom => |custom| custom,
    };

    const top_left: Cell.Character = .{ .grapheme = glyphs[0], .width = 1 };
    const horizontal: Cell.Character = .{ .grapheme = glyphs[1], .width = 1 };
    const top_right: Cell.Character = .{ .grapheme = glyphs[2], .width = 1 };
    const vertical: Cell.Character = .{ .grapheme = glyphs[3], .width = 1 };
    const bottom_right: Cell.Character = .{ .grapheme = glyphs[4], .width = 1 };
    const bottom_left: Cell.Character = .{ .grapheme = glyphs[5], .width = 1 };
    const style = opts.border.style;

    const h = result.height;
    const w = result.width;

    const loc: BorderOptions.Locations = switch (opts.border.where) {
        .none => return result,
        .all => .{ .top = true, .bottom = true, .right = true, .left = true },
        .bottom => .{ .bottom = true },
        .right => .{ .right = true },
        .left => .{ .left = true },
        .top => .{ .top = true },
        .other => |loc| loc,
    };
    if (loc.top) {
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            result.writeCell(i, 0, .{ .char = horizontal, .style = style });
        }
    }
    if (loc.bottom) {
        var i: u16 = 0;
        while (i < w) : (i += 1) {
            result.writeCell(i, h -| 1, .{ .char = horizontal, .style = style });
        }
    }
    if (loc.left) {
        var i: u16 = 0;
        while (i < h) : (i += 1) {
            result.writeCell(0, i, .{ .char = vertical, .style = style });
        }
    }
    if (loc.right) {
        var i: u16 = 0;
        while (i < h) : (i += 1) {
            result.writeCell(w -| 1, i, .{ .char = vertical, .style = style });
        }
    }
    // draw corners
    if (loc.top and loc.left)
        result.writeCell(0, 0, .{ .char = top_left, .style = style });
    if (loc.top and loc.right)
        result.writeCell(w -| 1, 0, .{ .char = top_right, .style = style });
    if (loc.bottom and loc.left)
        result.writeCell(0, h -| 1, .{ .char = bottom_left, .style = style });
    if (loc.bottom and loc.right)
        result.writeCell(w -| 1, h -| 1, .{ .char = bottom_right, .style = style });

    // draw label
    _ = result.printSegment(.{ .text = label[0..@min(label.len, @as(usize, @intCast(result.width - 2)))], .style = .{ .fg = color } }, .{ .col_offset = 1, .row_offset = 0 });

    const x_off: u16 = if (loc.left) 1 else 0;
    const y_off: u16 = if (loc.top) 1 else 0;
    const h_delt: u16 = if (loc.bottom) 1 else 0;
    const w_delt: u16 = if (loc.right) 1 else 0;
    const h_ch: u16 = h -| y_off -| h_delt;
    const w_ch: u16 = w -| x_off -| w_delt;
    return initChild(result, x_off, y_off, w_ch, h_ch);
}

fn initChild(self: vaxis.Window, x_off: i17, y_off: i17, maybe_width: ?u16, maybe_height: ?u16) vaxis.Window {
    const max_height = @max(self.height - y_off, 0);
    const max_width = @max(self.width - x_off, 0);
    const width: u16 = maybe_width orelse max_width;
    const height: u16 = maybe_height orelse max_height;

    return .{
        .x_off = x_off + self.x_off,
        .y_off = y_off + self.y_off,
        .parent_x_off = @min(self.parent_x_off + x_off, 0),
        .parent_y_off = @min(self.parent_y_off + y_off, 0),
        .width = @min(width, max_width),
        .height = @min(height, max_height),
        .screen = self.screen,
    };
}
