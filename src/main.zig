const std = @import("std");
const posix = std.posix;

const TCSA = posix.TCSA;

/// Sets termios to the state passed in as the `orginalTermios` arg and
/// exits the process successfully.
///
/// Ideally it should be the original state before the editor was started
/// and will return it back to canonical mode.
fn disableRawMode(originalTermios: posix.termios, status: u8) posix.TermiosSetError!void {
    try posix.tcsetattr(posix.STDIN_FILENO, TCSA.FLUSH, originalTermios);
    std.process.exit(status);
}

/// Correctly sets various flags in the Termios struct
/// to switch from canonical mode to raw (cooked) mode.
fn enableRawMode(originalTermios: posix.termios) !void {
    var raw = originalTermios;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;

    try posix.tcsetattr(posix.STDIN_FILENO, TCSA.FLUSH, raw);
}

pub fn main() !void {
    // Make a copy of the original termios state so we
    // can restor terminal state after leaving the editor
    const originalTermios: posix.termios = try posix.tcgetattr(posix.STDIN_FILENO);
    const stdin = std.io.getStdIn().reader();

    try enableRawMode(originalTermios);

    var buf: [100]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(&buf, 'q')) |input| {
        _ = input;
    }

    try disableRawMode(originalTermios, 0);
}
