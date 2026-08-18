// PostgreSqlDialect: distinct parse paths from Generic (e.g. dollar-quoted
// strings, `::` casts, array literals, `RETURNING`, Postgres-specific DDL).
#![no_main]

use libfuzzer_sys::fuzz_target;
use sqlparser::dialect::PostgreSqlDialect;
use sqlparser::parser::Parser;

fuzz_target!(|data: &[u8]| {
    let sql = String::from_utf8_lossy(data);
    let dialect = PostgreSqlDialect {};
    let _ = Parser::parse_sql(&dialect, &sql);
});
