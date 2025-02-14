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



    while (true) {
        const input = stdin.readByte() catch 0;

        if (std.ascii.isControl(input)) {
            std.debug.print("{d}\r\n", .{input});
        } else {
            std.debug.print("{d}", .{input});
            std.debug.print(":('{c}')\r\n", .{input});
        }

        if (input == ctrlKey('q')) {
            break;
fn editorProcessKeypress(editorState: *EditorState) !void {
    const char = editorReadKey();
    if (char == ctrlKey('q')) {
        try disableRawMode(&editorState.originalTermios);
        _ = try stdout.write("\x1b[2J");
        _ = try stdout.write("\x1b[H");
        std.process.cleanExit();
    }
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

// TODO: Write more tests !

test "expect ctrlKey to mask char into control key" {
    try std.testing.expect(ctrlKey('q') == 17);
}

// NOTE:
// ~~~~~~
//  - Because we have disable output processing, all newlines
//    must be an explicit `\r\n`, just using `\n` will cause
//    walking.
