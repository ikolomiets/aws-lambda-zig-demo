//! Build wiring places this facade beside a symlink to the active dependency's
//! sources. Runtime and Tester must share a module because upstream's root tests
//! also import Tester. No upstream source is copied or modified.
const upstream = @import("upstream/root.zig");
pub const Tester = @import("upstream/debug/Tester.zig");

pub const Stream = upstream.Stream;
pub const Options = upstream.Options;
pub const Context = upstream.Context;
pub const ResponseWriter = upstream.ResponseWriter;
pub const handle = upstream.handle;
pub const handleAsync = upstream.handleAsync;
pub const handleWriter = upstream.handleWriter;
pub const handleStream = upstream.handleStream;
pub const url = upstream.url;
pub const sqs = upstream.sqs;
pub const KeyVal = upstream.KeyVal;
pub const log = upstream.log;
