// mayhem/fuzz — ADDITIVE cargo-fuzz targets (do not touch upstream's own
// honggfuzz-based fuzz/ crate; that crate cannot be built with cargo-fuzz's
// libfuzzer-sys harness, so we port its API surface here instead).
//
// GenericDialect: the dialect-agnostic parse path (keyword set is the union
// of all dialects' reserved words; most statement grammar lives here).
#![no_main]

use libfuzzer_sys::fuzz_target;
use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;

fuzz_target!(|data: &[u8]| {
    // Lossy UTF-8 conversion (not a UTF-8-valid check-and-skip) so every byte
    // sequence libFuzzer generates exercises the tokenizer, not just the
    // valid-UTF-8 subset.
    let sql = String::from_utf8_lossy(data);
    let dialect = GenericDialect {};
    let _ = Parser::parse_sql(&dialect, &sql);
});
