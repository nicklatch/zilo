const std = @import("std");
const posix = std.posix;

const TermiosSetError = std.posix.TermiosSetError;
const TermiosGetError = std.posix.TermiosGetError;
const TermiosErr = TermiosGetError || TermiosSetError;

const stdout = std.io.getStdOut();
const stdin = std.io.getStdIn();

const TCSA = posix.TCSA;
const VMIN = 6;
const VTIME = 5;

const welcome_msg = "Zilo Editor -- v";
const ziloVersion = "0.0.1"; //TODO:  Can I get this from build.zig.zon?

const EditorKey = struct {
    pub const arrow_left: usize = 1000;
    pub const arrow_right: usize = 1001;
    pub const arrow_up: usize = 1002;
    pub const arrow_down: usize = 1003;
    pub const delet_key: usize = 1004;
    pub const home_key: usize = 1005;
    pub const end_key: usize = 1006;
    pub const page_up: usize = 1007;
    pub const page_down: usize = 1008;
};

/// Contains state for the terminal and editor
const EditorState = struct {
    cursor_x: usize,
    cursor_y: usize,
    screen_rows: usize,
    screen_columns: usize,
    num_rows: usize,
    row: std.ArrayList([]u8), // left off here -- Step 61
    original_termios: posix.termios,
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
///     `termios_ptr`: A pointer to a `std.posix.termios` struct
/// Returns:
///     Either a `TermiosSetError` or nothing (`void`)
fn disableRawMode(termios_ptr: *posix.termios) TermiosSetError!void {
    try posix.tcsetattr(posix.STDIN_FILENO, TCSA.FLUSH, termios_ptr.*);
}

/// Sets various flags in the Termios struct to
/// switch from canonical (cooked) mode to raw mode.
///
/// __Arguments__:
///     `termios_ptr`: A pointer to a `std.posix.termios` struct
///
/// __Returns__:
///     Either a `TermiosGetErr`, `TermiosSetErr`, or nothing (`void`)
fn enableRawMode(termios_ptr: *posix.termios) TermiosErr!void {
    termios_ptr.* = try posix.tcgetattr(posix.STDIN_FILENO);
    var raw = termios_ptr.*;

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

// NOTE: This will most certainly be the culprit of a keybinding bug at some point
fn editorReadKey() usize {
    // need the double read for now, a while loop hangs the cursor at startup
    var read: u8 = stdin.reader().readByte() catch 0;
    if (read == 0) {
        read = stdin.reader().readByte() catch 0;
    }

    if (read == '\x1b') {
        var seq: [3]u8 = undefined;
        seq[0] = stdin.reader().readByte() catch 0;
        seq[1] = stdin.reader().readByte() catch 0;

        if (seq[0] == 0) return '\x1b';
        if (seq[1] == 0) return '\x1b';

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                seq[2] = stdin.reader().readByte() catch 0;
                if (seq[2] == 0) return '\x1b';
                if (seq[2] == '~') {
                    return switch (seq[1]) {
                        '1', '7' => EditorKey.home_key,
                        '3' => EditorKey.delet_key,
                        '4', '8' => EditorKey.end_key,
                        '5' => EditorKey.page_up,
                        '6' => EditorKey.page_down,
                        else => 0,
                    };
                }
            } else {
                return switch (seq[1]) {
                    'A' => EditorKey.arrow_up,
                    'B' => EditorKey.arrow_down,
                    'C' => EditorKey.arrow_right,
                    'D' => EditorKey.arrow_left,
                    'H' => EditorKey.home_key,
                    'F' => EditorKey.end_key,
                    else => 0,
                };
            }
        } else if (seq[0] == 'O') {
            return switch (seq[1]) {
                'H' => EditorKey.home_key,
                'F' => EditorKey.end_key,
                else => 0,
            };
        }
        return '\x1b';
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
fn charSliceToNumber(char_slice: []const u8) usize {
    if (char_slice.len == 1) return char_slice[0] - '0';

    var result: usize = 0;
    var multiplier = std.math.pow(usize, 10, char_slice.len - 1);
    for (char_slice) |char| {
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
/// pointers of the `editor_state` struct
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

fn editorAppendRow(editor_state: *EditorState, row: []u8) !void {
    try editor_state.row.append(row);
}

fn editorOpen(editor_state: *EditorState, file_name: []const u8, allocator: *std.mem.Allocator) !void {
    const file = std.fs.cwd().openFile(file_name, .{}) catch |err| {
        std.log.err("Failed to open file: {s}", .{@errorName(err)});
        return;
    };
    var line = std.ArrayList(u8).init(allocator.*);
    var line_length: usize = undefined;

    defer {
        line.deinit();
        file.close();
        line.clearAndFree();
    }

    file.reader().streamUntilDelimiter(line.writer(), '\n', std.math.maxInt(usize)) catch |err| {
        std.log.err("Failed to read line: {s}", .{@errorName(err)});
        return;
    };

    line_length = line.items.len;
    while (line_length > 0 and (line.items[line_length - 1] == '\n' or line.items[line_length - 1] == '\r')) {
        line_length -= 1;
    }

    try editorAppendRow(editor_state, line.items);
}

fn editorDrawRows(editor_state: *EditorState, a_buf: *std.ArrayListAligned(u8, null)) !void {
    for (0..editor_state.screen_rows) |row| {
        if (row >= editor_state.num_rows) {
            if (editor_state.num_rows == 0 and row == editor_state.screen_rows / 3) {
                var msgLen: usize = welcome_msg.len + ziloVersion.len;
                if (msgLen > editor_state.screen_columns) msgLen = editor_state.screen_columns;
                var padding = (editor_state.screen_columns - msgLen) / 2;

                if (padding > 0) {
                    try a_buf.appendSlice("~");
                    padding -= 1;
                }

                while (padding > 0) : (padding -= 1) try a_buf.appendSlice(" ");
                try a_buf.appendSlice(welcome_msg);
                try a_buf.appendSlice(ziloVersion);
            } else {
                try a_buf.appendSlice("~");
            }
        } else {
            var length = editor_state.row.items[row].len;
            if (length > editor_state.screen_columns) length = editor_state.screen_columns;
            try a_buf.appendSlice(editor_state.row.items[row]);
        }

        try a_buf.appendSlice("\x1b[K");
        if (row < editor_state.screen_rows - 1) {
            try a_buf.appendSlice("\r\n");
        }
    }
}

fn editorRefreshScreen(editor_state: *EditorState, allocator: *std.mem.Allocator) !void {
    var a_buf = std.ArrayList(u8).init(allocator.*);

    try a_buf.appendSlice("\x1b[?25l");
    try a_buf.appendSlice("\x1b[H"); // Positoion cursor at row 1, col 1

    try editorDrawRows(editor_state, &a_buf);

    var printBuf: [32]u8 = undefined;
    _ = try std.fmt.bufPrint(&printBuf, "\x1b[{d};{d}H", .{
        editor_state.cursor_y + 1,
        editor_state.cursor_x + 1,
    });
    try a_buf.appendSlice(&printBuf);
    try a_buf.appendSlice("\x1b[?25h");

    _ = try stdout.write(a_buf.items);
    a_buf.clearAndFree();
}

fn editorMoveCursor(key: usize, editor_state: *EditorState) !void {
    // Use saturating arithmatic to avoid overflows
    switch (key) {
        EditorKey.arrow_left => editor_state.cursor_x -|= 1,
        EditorKey.arrow_right => editor_state.cursor_x +|= 1,
        EditorKey.arrow_up => editor_state.cursor_y -|= 1,
        EditorKey.arrow_down => editor_state.cursor_y +|= 1,
        else => {},
    }
}

fn editorProcessKeypress(editor_state: *EditorState) !void {
    const char = editorReadKey();
    switch (char) {
        // TODO: move this to `EditorKey` as `quit` and change this accordingly
        ctrlKey('q') => {
            try disableRawMode(&editor_state.original_termios);
            _ = try stdout.write("\x1b[2J");
            _ = try stdout.write("\x1b[H");
            std.process.exit(0);
        },
        EditorKey.home_key => editor_state.cursor_x = 0,
        EditorKey.end_key => editor_state.cursor_x = editor_state.screen_columns - 1,
        EditorKey.page_up, EditorKey.page_down => {
            var times = editor_state.screen_rows;
            while (times > 0) : (times -= 1) {
                const upOrDown = if (char == EditorKey.page_up) EditorKey.arrow_up else EditorKey.arrow_down;
                try editorMoveCursor(upOrDown, editor_state);
            }
        },
        EditorKey.arrow_up, EditorKey.arrow_down, EditorKey.arrow_right, EditorKey.arrow_left => {
            try editorMoveCursor(char, editor_state);
        },
        else => {},
    }
}

fn initEditor(editor_state: *EditorState) !void {
    try getWindowSize(&editor_state.screen_rows, &editor_state.screen_columns);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const argv = try std.process.argsAlloc(allocator);

    defer {
        std.process.argsFree(allocator, argv);
        _ = gpa.deinit();
    }

    var E: EditorState = .{
        .cursor_x = 0,
        .cursor_y = 0,
        .screen_rows = 0,
        .screen_columns = 0,
        .num_rows = 0,
        .row = std.ArrayList([]u8).init(allocator),
        .original_termios = undefined,
    };

    defer {
        _ = E.row.deinit();
    }

    try enableRawMode(&E.original_termios);
    try initEditor(&E);

    if (argv.len >= 2) try editorOpen(&E, argv[1], &allocator);

    while (true) {
        try editorRefreshScreen(&E, &allocator);
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
