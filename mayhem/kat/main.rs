// mayhem/kat — known-answer-test probe for mayhem/test.sh.
//
// WHY A SEPARATE BINARY (SPEC §6.3 anti-reward-hacking):
// `cargo test` links a test-harness binary that is not a clean, unconditional
// known-answer assertion — the sabotage check needs a small, purpose-built
// probe whose entire job is to parse fixed SQL and print exact values, so a
// neutered (or logic-stubbed) parser is caught by a plain string comparison
// in test.sh, not by interpreting test-harness output. This crate is a
// normal `cargo build` binary on the gnu target (dynamically linked against
// libc by default — no cgo-style trick needed, unlike Go); mayhem/build.sh
// still asserts `file /mayhem/kat | grep 'dynamically linked'` so a future
// static-link change (e.g. a musl target) can't silently weaken the oracle.
//
// It asserts VALUES parsed out of three fixed SQL statements spanning three
// distinct dialect-parse paths (Generic DDL, Generic DML, Postgres/MySQL
// pretty-printing), so a patch that stubs the parser to dodge a crash cannot
// reproduce these exact strings/counts.
//
// Prints, matched EXACTLY by test.sh:
//   KAT_PROJECTION_COUNT=<n>   — SELECT list length (GenericDialect)
//   KAT_TABLE_NAME=<name>      — CREATE TABLE name (GenericDialect)
//   KAT_ROUNDTRIP=<sql>        — normalized to_string() of a messily-formatted
//                                 SELECT, parsed under PostgreSqlDialect
use sqlparser::ast::{SetExpr, Statement};
use sqlparser::dialect::{GenericDialect, PostgreSqlDialect};
use sqlparser::parser::Parser;

fn main() {
    // 1) projection count from a plain multi-column SELECT.
    let sql1 = "SELECT a, b, c FROM t WHERE a > 1";
    let stmts1 = Parser::parse_sql(&GenericDialect {}, sql1).unwrap_or_else(|e| {
        eprintln!("kat: parse #1 failed: {e}");
        std::process::exit(1);
    });
    let projection_count = match stmts1.as_slice() {
        [Statement::Query(q)] => match q.body.as_ref() {
            SetExpr::Select(s) => s.projection.len(),
            other => {
                eprintln!("kat: expected SetExpr::Select, got {other:?}");
                std::process::exit(1);
            }
        },
        other => {
            eprintln!("kat: expected a single Query statement, got {other:?}");
            std::process::exit(1);
        }
    };
    println!("KAT_PROJECTION_COUNT={projection_count}");

    // 2) table name resolved out of a CREATE TABLE statement.
    let sql2 = "CREATE TABLE orders (id INT, name TEXT, total DOUBLE)";
    let stmts2 = Parser::parse_sql(&GenericDialect {}, sql2).unwrap_or_else(|e| {
        eprintln!("kat: parse #2 failed: {e}");
        std::process::exit(1);
    });
    let table_name = match stmts2.as_slice() {
        [Statement::CreateTable(ct)] => ct.name.to_string(),
        other => {
            eprintln!("kat: expected a single CreateTable statement, got {other:?}");
            std::process::exit(1);
        }
    };
    println!("KAT_TABLE_NAME={table_name}");

    // 3) normalized round-trip string of a deliberately messily-formatted
    //    query, parsed under PostgreSqlDialect (exercises pretty-printing,
    //    not just tokenizing/parsing).
    let sql3 = "select   1+2   as   x   from    dual";
    let stmts3 = Parser::parse_sql(&PostgreSqlDialect {}, sql3).unwrap_or_else(|e| {
        eprintln!("kat: parse #3 failed: {e}");
        std::process::exit(1);
    });
    if stmts3.len() != 1 {
        eprintln!("kat: expected a single statement from sql3, got {}", stmts3.len());
        std::process::exit(1);
    }
    println!("KAT_ROUNDTRIP={}", stmts3[0]);
}
