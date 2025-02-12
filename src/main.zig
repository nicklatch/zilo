const std = @import("std");
const posix = std.posix;
const TermiosSetError = std.posix.TermiosSetError;
const TermiosGetError = std.posix.TermiosGetError;

const TCSA = posix.TCSA;

/// Sets termios to the state passed in as the `orginalTermios` arg and
/// exits the process successfully.
///
/// Ideally it should be the original state before the editor was started
/// and will return it back to canonical mode.
fn disableRawMode(originalTermios: posix.termios, status: u8) TermiosSetError!void {
    try posix.tcsetattr(posix.STDIN_FILENO, TCSA.FLUSH, originalTermios);
    std.process.exit(status);
}

/// Correctly sets various flags in the Termios struct
/// to switch from canonical mode to raw (cooked) mode.
fn enableRawMode(originalTermios: posix.termios) TermiosSetError!void {
    var raw = originalTermios;

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
