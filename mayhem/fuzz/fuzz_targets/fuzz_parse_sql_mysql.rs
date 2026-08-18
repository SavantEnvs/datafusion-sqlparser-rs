// MySqlDialect: distinct parse paths from Generic/Postgres (e.g. backtick
// identifiers, `#`/`-- ` line comments, `LIMIT a,b`, MySQL-specific DDL).
#![no_main]

use libfuzzer_sys::fuzz_target;
use sqlparser::dialect::MySqlDialect;
use sqlparser::parser::Parser;

fuzz_target!(|data: &[u8]| {
    let sql = String::from_utf8_lossy(data);
    let dialect = MySqlDialect {};
    let _ = Parser::parse_sql(&dialect, &sql);
});
