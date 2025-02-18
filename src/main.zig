const std = @import("std");
const posix = std.posix;
const TermiosSetError = std.posix.TermiosSetError;
const TermiosGetError = std.posix.TermiosGetError;

const stdout = std.io.getStdOut();
const stdin = std.io.getStdIn();

const TCSA = posix.TCSA;
const VMIN = 6;
const VTIME = 5;

const kiloVersion = "0.0.1";

/// Contains state for the terminal and editor
const EditorState = struct {
    cursorX: usize,
    cursorY: usize,
    screenRows: usize,
    screenColumns: usize,
    originalTermios: posix.termios,
};

/// Sets bits 5 and 6 to zero, masking the given key to a control sequence.
///
/// Arguments:
///     `key`: The decimal value (`u8`) of an ansii character reprsenting a keypress
/// Returns:
///     A u8 representing the `key` masked to a control seqence (1..31, 127)
inline fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

/// Sets termios to orginial state
///
/// Arguments:
///     `termiosPtr`: A pointer to a `std.posix.termios` struct
/// Returns:
///     Either a `TermiosSetError` or nothing (`void`)
fn disableRawMode(termiosPtr: *posix.termios) TermiosSetError!void {
    try posix.tcsetattr(posix.STDIN_FILENO, TCSA.FLUSH, termiosPtr.*);
}

const TermiosErr = TermiosGetError || TermiosSetError;

/// Sets various flags in the Termios struct to
/// switch from canonical (cooked) mode to raw mode.
///
/// Arguments:
///     `termiosPtr`: A pointer to a `std.posix.termios` struct
/// Returns:
///     Either a `TermiosGetErr`, `TermiosSetErr`, or nothing (`void`)
fn enableRawMode(termiosPtr: *posix.termios) TermiosErr!void {
    termiosPtr.* = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = termiosPtr.*;

    // Input Flags
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false; // Disables Ctrl-M
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false; // Disable Ctrl-S and Ctrl-Q

    // Output Flags
    raw.oflag.OPOST = false; // Disable output-processing

    // Control Flags
    raw.cflag.CSIZE = posix.CSIZE.CS8;

    // Local Flags
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false; // Disable canonical mode (read by-byte instead of by-line)
    raw.lflag.IEXTEN = false; // Disable Ctrl-V
    raw.lflag.ISIG = false; // Disable Ctrl-C and Ctrl-Z

    raw.cc[VMIN] = 0;
    raw.cc[VTIME] = 1;

    // Persist changes
    try posix.tcsetattr(posix.STDIN_FILENO, TCSA.FLUSH, raw);
}

fn editorReadKey() u8 {
    var read = stdin.reader().readByte() catch 0;
    if (read == 0) {
        read = stdin.reader().readByte() catch 0;
    }

    return read;
}

/// Converts a `[]const u8` containing decimal representations of ascii chars
/// to their literal char value.
///
/// Example:
/// ```zig
/// test charSliceToNumber {
///     const rows = [_]u8{ 53, 57 }; // {'5', '9'}
///     const expected = 59;
///     const actual = charSliceToNumber(rows[0..]);
///     try std.testing.expectEqual(expected, actual);
/// }
/// ```
fn charSliceToNumber(charSlice: []const u8) usize {
    if (charSlice.len == 1) return charSlice[0] - '0';

    var result: usize = 0;
    var multiplier = std.math.pow(usize, 10, charSlice.len - 1);
    for (charSlice) |char| {
        const toNum = char - '0';
        result += (toNum * multiplier);
        multiplier /= 10;
    }
    return result;
}
const CursorPositionError = error{ EscapeSeqErr, LocationParseError };

/// **__WIP__**
/// Right now, it just queries the terminal for its size,
/// parses the out put, and writes it the the row and column
/// pointers of the `editorState` struct
fn getCursorPosition(rows: *usize, cols: *usize) !void {
    // TODO: this should be moved to getWindowSize
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    var semiColonPos: usize = 0;

    _ = try stdout.write("\x1b[6n");
    while (i < @sizeOf(@TypeOf(buf)) - 1) {
        const input = stdin.reader().readByte() catch 0;
        buf[i] = input;
        if (input == ';') semiColonPos = i;
        i += 1;
        if (input == 'R') break;
    }

    if (buf[0] != '\x1b') return CursorPositionError.EscapeSeqErr;
    if (buf[1] != '[') return CursorPositionError.EscapeSeqErr;

    const position: []u8 = buf[0..i];
    rows.* = charSliceToNumber(buf[2..semiColonPos]);
    cols.* = charSliceToNumber(buf[semiColonPos + 1 .. position.len - 1]);

    _ = editorReadKey();
}

fn getWindowSize(rows: *usize, cols: *usize) !void {
    _ = try stdout.write("\x1b[999C\x1b[999B");

    try getCursorPosition(rows, cols);
}

fn editorProcessKeypress(editorState: *EditorState) !void {
    const char = editorReadKey();
    if (char == ctrlKey('q')) {
        try disableRawMode(&editorState.originalTermios);
        _ = try stdout.write("\x1b[2J");
        _ = try stdout.write("\x1b[H");
        std.process.exit(0);
    }
}

fn editorDrawRows(editorState: *EditorState, aBuf: *std.ArrayListAligned(u8, null)) !void {
    for (0..editorState.screenRows) |row| {
        if (row == editorState.screenRows / 3) {
            var msgLen: usize = 16 + kiloVersion.len;
            if (msgLen > editorState.screenColumns) msgLen = editorState.screenColumns;
            var padding = (editorState.screenColumns - msgLen) / 2;

            if (padding > 0) {
                try aBuf.appendSlice("~");
                padding -= 1;
            }

            while (padding > 0) : (padding -= 1) try aBuf.appendSlice(" ");
            try aBuf.appendSlice("Kilo Editor -- v");
            try aBuf.appendSlice(kiloVersion);
        } else {
            try aBuf.appendSlice("~");
        }

        try aBuf.appendSlice("\x1b[K");
        if (row < editorState.screenRows - 1) {
            try aBuf.appendSlice("\r\n");
        }
    }
}

fn editorRefreshScreen(editorState: *EditorState, allocator: std.mem.Allocator) !void {
    var aBuf = std.ArrayList(u8).init(allocator);

    try aBuf.appendSlice("\x1b[?25l");
    try aBuf.appendSlice("\x1b[H"); // Positoion cursor at row 1, col 1

    try editorDrawRows(editorState, &aBuf);

    var printBuf: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&printBuf, "\x1b[{d};{d}H", .{ editorState.cursorY + 1, editorState.cursorX + 1 });
    try aBuf.appendSlice(&printBuf);
    try aBuf.appendSlice("\x1b[?25h");

    _ = try stdout.write(aBuf.items);
    aBuf.clearAndFree();
}

fn initEditor(editorState: *EditorState) !void {
    try getWindowSize(&editorState.screenRows, &editorState.screenColumns);
}

pub fn main() !void {
    // TODO: Handle error for invalid input
    var E: EditorState = .{
        .cursorX = 0,
        .cursorY = 0,
        .screenRows = 0,
        .screenColumns = 0,
        .originalTermios = undefined,
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    try enableRawMode(&E.originalTermios);
    try initEditor(&E);

    while (true) {
        try editorRefreshScreen(&E, allocator);
        try editorProcessKeypress(&E);
    }
    std.process.cleanExit();
}

// ~~~~~~~~~~~~~~TESTS~~~~~~~~~~~~~~ //

test "expect ctrlKey to mask char into control key" {
    try std.testing.expect(ctrlKey('q') == 17);
}

test "charSliceToNumber works correctly with two digit number" {
    const rows = [_]u8{ 53, 57 }; // {5, 9}
    const expected = 59;
    const actual = charSliceToNumber(rows[0..]);
    try std.testing.expectEqual(expected, actual);
}

test "charSlicetoNumber works correctly with three digit number" {
    const cols = [_]u8{ 50, 53, 54 }; // { 2, 5, 6 }
    const expected = 256;
    const actual = charSliceToNumber(cols[0..]);
    try std.testing.expectEqual(expected, actual);
}
