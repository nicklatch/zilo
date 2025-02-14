const std = @import("std");
const posix = std.posix;
const TermiosSetError = std.posix.TermiosSetError;
const TermiosGetError = std.posix.TermiosGetError;

const stdout = std.io.getStdOut();
const stdin = std.io.getStdIn();

const TCSA = posix.TCSA;
const VMIN = 6;
const VTIME = 5;

/// For containing state of the terminal and editor
const EditorState = struct {
    screenRows: usize,
    screenColumns: usize,
    originalTermios: posix.termios,
};

inline fn ctrlKey(key: u8) u8 {
    return key & 0x1f;
}

/// Sets termios to the state passed in by `orginalTermios`.
fn disableRawMode(termiosPtr: *posix.termios) TermiosSetError!void {
    try posix.tcsetattr(posix.STDIN_FILENO, TCSA.FLUSH, termiosPtr.*);
}

/// Sets various flags in the Termios struct to
/// switch from canonical mode to raw (cooked) mode.
fn enableRawMode(termiosPtr: *posix.termios) TermiosSetError!void {
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
    return stdin.reader().readByte() catch 0;
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

    try stdout.writer().print("\r\nrows: {any}\r\ncols: {any}\r\n", .{ rows, cols });

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
        std.process.cleanExit();
    }
}

fn editorDrawRows(editorState: *EditorState) !void {
    for (0..editorState.screenRows) |row| {
        _ = try stdout.write("~");
        if (row < editorState.screenRows - 1) {
            _ = try stdout.write("\r\n");
        }
    }
}

fn editorRefreshScreen(editorState: *EditorState) !void {
    _ = try stdout.write("\x1b[2J"); // Clear the entire screen
    _ = try stdout.write("\x1b[H"); // Positoion cursor at row 1, col 1

    try editorDrawRows(editorState);

    _ = try stdout.write("\x1b[H");
}

fn initEditor(editorState: *EditorState) !void {
    try getWindowSize(&editorState.screenRows, &editorState.screenColumns);
}

pub fn main() !void {
    // TODO: Handle error for invalid input
    var E: EditorState = .{
        .screenRows = 0,
        .screenColumns = 0,
        .originalTermios = undefined,
    };

    try enableRawMode(&E.originalTermios);
    try initEditor(&E);

    while (true) {
        try editorRefreshScreen(&E);
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
