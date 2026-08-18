// Deeper surface than a plain parse: parse -> Statement::to_string() ->
// re-parse, and assert the two ASTs agree. A mismatch (or a re-parse error
// on the parser's own output) is a genuine bug class this project cares
// about — the pretty-printer must be a faithful round-trip of what it
// accepted, not just "didn't crash". `Statement` derives `PartialEq`, so the
// comparison is a plain assert_eq!, which panics (and libFuzzer reports it
// as a crash) on divergence.
#![no_main]

use libfuzzer_sys::fuzz_target;
use sqlparser::dialect::GenericDialect;
use sqlparser::parser::Parser;

fuzz_target!(|data: &[u8]| {
    let sql = String::from_utf8_lossy(data);
    let dialect = GenericDialect {};

    let Ok(stmts) = Parser::parse_sql(&dialect, &sql) else {
        return;
    };

    for stmt in &stmts {
        let rendered = stmt.to_string();
        match Parser::parse_sql(&dialect, &rendered) {
            Ok(reparsed) => {
                assert_eq!(
                    reparsed.len(),
                    1,
                    "round-trip changed statement count\noriginal: {stmt:?}\nrendered: {rendered}\nreparsed: {reparsed:?}"
                );
                assert_eq!(
                    &reparsed[0], stmt,
                    "round-trip AST mismatch\noriginal: {stmt:?}\nrendered: {rendered}\nreparsed: {:?}",
                    reparsed[0]
                );
            }
            Err(e) => {
                panic!(
                    "round-trip re-parse of the parser's own output failed: {e:?}\noriginal: {stmt:?}\nrendered: {rendered}"
                );
            }
        }
    }
});
