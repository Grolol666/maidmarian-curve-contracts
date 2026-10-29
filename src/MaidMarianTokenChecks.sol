// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

// The name, symbol, logo and profile checks shared by the ETF factory and the curve factory: one copy,
// so a name, a link or a logo one accepts the other accepts. Every byte on an ASCII allowlist, so no
// Unicode look-alike or control character can pass.

// Longest name: `[A-Za-z0-9]`, space, `-`, `.`, `&`, `'`; no space first, last or doubled.
uint256 constant TOKEN_MAX_NAME_BYTES = 64;

// Longest symbol: `[A-Za-z0-9]` only.
uint256 constant TOKEN_MAX_SYMBOL_BYTES = 11;

uint256 constant TOKEN_MAX_LOGO_BYTES = 16_384;

// Largest logo side, in pixels (PNG IHDR).
uint256 constant TOKEN_MAX_LOGO_SIDE = 256;

uint256 constant PROFILE_MAX_DESCRIPTION_BYTES = 280;
uint256 constant PROFILE_MAX_WEBSITE_BYTES = 100;

error BadName();
error BadSymbol();
error BadLogo();
error BadDescription();
error BadX();
error BadTelegram();
error BadWebsite();
error BadDiscord();

function checkTokenName(bytes calldata name_) pure {
    uint256 n = name_.length;
    if (n == 0 || n > TOKEN_MAX_NAME_BYTES || name_[0] == " " || name_[n - 1] == " ") revert BadName();
    for (uint256 i = 0; i < n; i++) {
        bytes1 ch = name_[i];
        if (ch == " ") {
            if (name_[i - 1] == " ") revert BadName();
            continue;
        }
        if (!isAsciiAlnum(ch) && ch != "-" && ch != "." && ch != "&" && ch != "'") revert BadName();
    }
}

function checkTokenSymbol(bytes calldata symbol_) pure {
    uint256 n = symbol_.length;
    if (n == 0 || n > TOKEN_MAX_SYMBOL_BYTES) revert BadSymbol();
    for (uint256 i = 0; i < n; i++) {
        if (!isAsciiAlnum(symbol_[i])) revert BadSymbol();
    }
}

/// Every field optional (empty):
///  - `description`: at most 280 bytes, 0x20 - 0x7E;
///  - `x`: `https://x.com/` and 1 - 15 of `[A-Za-z0-9_]`, nothing after;
///  - `telegram`: `https://t.me/` and 5 - 32 of `[A-Za-z0-9_]`, nothing after;
///  - `website`: `https://`, at most 100 bytes, each byte `[A-Za-z0-9]` or one of `-._~/:?=&%#`,
///    a host of at least one byte before the first `/`, `?` or `#`.
function checkProfileFields(string calldata description, string calldata x, string calldata telegram, string calldata website) pure {
    checkProfileDescription(bytes(description));
    checkProfileHandleUrl(bytes(x), "https://x.com/", 1, 15, BadX.selector);
    checkProfileHandleUrl(bytes(telegram), "https://t.me/", 5, 32, BadTelegram.selector);
    checkProfileWebsite(bytes(website));
}

/// `checkProfileFields` and `discord`: empty, or `https://discord.gg/` / `https://discord.com/invite/` and 2 - 32 of
/// `[A-Za-z0-9-]`, nothing after.
function checkProfile(string calldata description, string calldata x, string calldata telegram, string calldata website, string calldata discord) pure {
    checkProfileFields(description, x, telegram, website);
    checkProfileDiscord(bytes(discord));
}

function checkProfileDiscord(bytes calldata s) pure {
    uint256 n = s.length;
    if (n == 0) return;
    uint256 p = hasPrefix(s, "https://discord.gg/") ? 19 : hasPrefix(s, "https://discord.com/invite/") ? 27 : 0;
    if (p == 0 || n < p + 2 || n > p + 32) revert BadDiscord();
    for (uint256 i = p; i < n; i++) {
        if (!isAsciiAlnum(s[i]) && s[i] != "-") revert BadDiscord();
    }
}

function hasPrefix(bytes calldata s, bytes memory prefix) pure returns (bool) {
    if (s.length < prefix.length) return false;
    for (uint256 i = 0; i < prefix.length; i++) {
        if (s[i] != prefix[i]) return false;
    }
    return true;
}

function checkProfileDescription(bytes calldata s) pure {
    uint256 n = s.length;
    if (n > PROFILE_MAX_DESCRIPTION_BYTES) revert BadDescription();
    for (uint256 i = 0; i < n; i++) {
        if (s[i] < 0x20 || s[i] > 0x7E) revert BadDescription();
    }
}

/// Empty, or exactly `prefix` and `min` - `max` of `[A-Za-z0-9_]`.
function checkProfileHandleUrl(bytes calldata s, bytes memory prefix, uint256 min, uint256 max, bytes4 err) pure {
    uint256 n = s.length;
    if (n == 0) return;
    uint256 p = prefix.length;
    if (n < p + min || n > p + max) revertWithSelector(err);
    for (uint256 i = 0; i < p; i++) {
        if (s[i] != prefix[i]) revertWithSelector(err);
    }
    for (uint256 i = p; i < n; i++) {
        if (!isAsciiAlnum(s[i]) && s[i] != "_") revertWithSelector(err);
    }
}

function checkProfileWebsite(bytes calldata s) pure {
    uint256 n = s.length;
    if (n == 0) return;
    bytes memory prefix = "https://";
    if (n > PROFILE_MAX_WEBSITE_BYTES || n <= prefix.length) revert BadWebsite();
    for (uint256 i = 0; i < prefix.length; i++) {
        if (s[i] != prefix[i]) revert BadWebsite();
    }
    bytes1 first = s[prefix.length];
    if (first == "/" || first == "?" || first == "#") revert BadWebsite();
    for (uint256 i = prefix.length; i < n; i++) {
        bytes1 ch = s[i];
        if (isAsciiAlnum(ch)) continue;
        if (ch != "-" && ch != "." && ch != "_" && ch != "~" && ch != "/" && ch != ":" && ch != "?" && ch != "=" && ch != "&" && ch != "%" && ch != "#") revert BadWebsite();
    }
}

/// Reverts with the bare selector `err`.
function revertWithSelector(bytes4 err) pure {
    assembly ("memory-safe") {
        mstore(0, err)
        revert(0, 4)
    }
}

function isAsciiAlnum(bytes1 ch) pure returns (bool) {
    return (ch >= "0" && ch <= "9") || (ch >= "A" && ch <= "Z") || (ch >= "a" && ch <= "z");
}

/// Checks the PNG signature and the IHDR size only: the bytes are stored, never decoded on chain.
/// A PNG carries no script, unlike an SVG.
function checkPngLogo(bytes calldata png) pure {
    if (png.length == 0) return;
    if (png.length > TOKEN_MAX_LOGO_BYTES || png.length < 33) revert BadLogo();
    if (bytes8(png[0:8]) != bytes8(0x89504E470D0A1A0A)) revert BadLogo();
    // "IHDR" is exactly 4 bytes.
    // forge-lint: disable-next-line(unsafe-typecast)
    if (uint32(bytes4(png[8:12])) != 13 || bytes4(png[12:16]) != bytes4("IHDR")) revert BadLogo();
    uint256 width = uint32(bytes4(png[16:20]));
    uint256 height = uint32(bytes4(png[20:24]));
    if (width == 0 || height == 0 || width > TOKEN_MAX_LOGO_SIDE || height > TOKEN_MAX_LOGO_SIDE) revert BadLogo();
}

/// SSTORE2-style: the logo as a contract's code behind a `0x00` (STOP), so it never runs. The init
/// code returns what follows its 14 bytes.
function storeLogoAsCode(bytes calldata png) returns (address pointer) {
    bytes memory init = abi.encodePacked(hex"63", uint32(png.length + 1), hex"80600e6000396000f3", hex"00", png);
    assembly ("memory-safe") {
        pointer := create(0, add(init, 32), mload(init))
    }
    if (pointer == address(0)) revert BadLogo();
}

/// The logo stored at `pointer` by `storeLogoAsCode`; empty for the zero address.
function readLogoCode(address pointer) view returns (bytes memory out) {
    if (pointer == address(0)) return out;
    uint256 size = pointer.code.length - 1;
    out = new bytes(size);
    assembly ("memory-safe") {
        extcodecopy(pointer, add(out, 32), 1, size)
    }
}
