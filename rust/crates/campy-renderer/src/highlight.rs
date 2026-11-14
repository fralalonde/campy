//! Gleam syntax highlighting for the code editor, via tree-sitter. The
//! tokenizer runs on the UI thread when the buffer changes; it produces the
//! per-line token model the shell's highlight layer renders underneath the
//! (transparent) editing surface, so both layers share one font engine.

use crate::sessions::PropValue;
use tree_sitter::{Parser, Query, QueryCursor, StreamingIterator};

// The default name color for text outside any capture.
pub const PLAIN: &str = "name";

pub fn highlight(source: &str) -> Vec<PropValue> {
    let spans = match highlight_spans(source) {
        Some(spans) => spans,
        None => return plain_lines(source),
    };
    let mut offset = 0usize;
    let mut lines = Vec::new();
    for (index, line) in source.split('\n').enumerate() {
        let start = offset;
        let end = start + line.len();
        offset = end + 1; // the '\n'
        let mut tokens = Vec::new();
        let mut cursor = start;
        let mut overlapping: Vec<&(usize, usize, &'static str)> = spans
            .iter()
            .filter(|(s, e, _)| *s < end && *e > start)
            .collect();
        overlapping.sort_by_key(|(s, e, _)| (*s, std::cmp::Reverse(e - s)));
        let mut position = 0usize; // byte offset inside the line
        for (span_start, span_end, kind) in overlapping {
            let span_start = (*span_start).max(start);
            let span_end = (*span_end).min(end);
            let local_start = span_start - start;
            let local_end = span_end - start;
            if local_end <= position {
                continue; // covered by a higher-priority span
            }
            if local_start > position {
                // Unhighlighted text before the capture (byte-safe: capture
                // edges from tree-sitter always land on char boundaries).
                let text = line[position..local_start].to_string();
                push_token(&mut tokens, &mut cursor, &text, PLAIN);
            }
            let text = line[local_start..local_end].to_string();
            push_token(&mut tokens, &mut cursor, &text, kind);
            position = local_end;
        }
        if position < line.len() {
            let text = line[position..].to_string();
            push_token(&mut tokens, &mut cursor, &text, PLAIN);
        }
        lines.push(PropValue::Struct(vec![
            ("index".into(), PropValue::Int(index as i64)),
            ("tokens".into(), PropValue::List(tokens)),
        ]));
    }
    lines
}

// Append a token, merging into the previous one when the kind matches so a
// line renders as few Text elements as possible.
fn push_token(tokens: &mut Vec<PropValue>, cursor: &mut usize, text: &str, kind: &'static str) {
    if text.is_empty() {
        return;
    }
    let start = *cursor;
    *cursor += text.len();
    match tokens.last_mut() {
        Some(PropValue::Struct(fields)) if matches!(fields.get(2), Some((_, PropValue::Text(existing))) if existing == kind) => {
            if let Some((_, PropValue::Text(existing))) = fields.get_mut(1) {
                existing.push_str(text);
            }
        }
        _ => tokens.push(PropValue::Struct(vec![
            ("text".into(), PropValue::Text(text.to_string())),
            ("kind".into(), PropValue::Text(kind.to_string())),
            ("start".into(), PropValue::Int(start as i64)),
        ])),
    }
}

fn plain_lines(source: &str) -> Vec<PropValue> {
    source
        .split('\n')
        .enumerate()
        .map(|(index, line)| {
            PropValue::Struct(vec![
                ("index".into(), PropValue::Int(index as i64)),
                (
                    "tokens".into(),
                    PropValue::List(if line.is_empty() {
                        Vec::new()
                    } else {
                        vec![PropValue::Struct(vec![
                            ("text".into(), PropValue::Text(line.to_string())),
                            ("kind".into(), PropValue::Text(PLAIN.to_string())),
                            ("start".into(), PropValue::Int(0)),
                        ])]
                    }),
                ),
            ])
        })
        .collect()
}

fn highlight_spans(source: &str) -> Option<Vec<(usize, usize, &'static str)>> {
    let language = tree_sitter_gleam::LANGUAGE.into();
    let mut parser = Parser::new();
    parser.set_language(&language).ok()?;
    let tree = parser.parse(source, None)?;
    let query = Query::new(&language, tree_sitter_gleam::HIGHLIGHT_QUERY).ok()?;
    let names = query.capture_names();
    let mut spans = Vec::new();
    let mut cursor = QueryCursor::new();
    let mut captures = cursor.captures(&query, tree.root_node(), source.as_bytes());
    while let Some((matched, _pattern)) = captures.next() {
        let Some(capture) = matched.captures.first() else {
            continue;
        };
        let node = capture.node;
        if node.is_missing() || node.is_error() {
            continue;
        }
        let name: &str = names
            .get(capture.index as usize)
            .copied()
            .unwrap_or_default();
        spans.push((node.start_byte(), node.end_byte(), kind_for(name)));
    }
    Some(spans)
}

fn kind_for(name: &str) -> &'static str {
    if name.starts_with("comment") {
        "comment"
    } else if name.starts_with("keyword") {
        "keyword"
    } else if name.starts_with("string") {
        "string"
    } else if name.starts_with("number") {
        "number"
    } else if name.starts_with("type")
        || name.starts_with("constructor")
        || name.starts_with("constant")
        || name.starts_with("module")
    {
        "type"
    } else if name.starts_with("punctuation") || name.starts_with("operator") {
        "punct"
    } else {
        PLAIN
    }
}

#[cfg(test)]
mod tests {
    use super::highlight;
    use crate::sessions::PropValue;

    fn token_text(token: &PropValue) -> String {
        let PropValue::Struct(fields) = token else {
            panic!("not a token");
        };
        let PropValue::Text(text) = &fields[0].1 else {
            panic!("no text");
        };
        text.clone()
    }

    fn token_kind(token: &PropValue) -> String {
        let PropValue::Struct(fields) = token else {
            panic!("not a token");
        };
        let PropValue::Text(kind) = &fields[1].1 else {
            panic!("no kind");
        };
        kind.clone()
    }

    fn line_tokens(lines: &[PropValue], index: i64) -> Vec<(String, String)> {
        let PropValue::Struct(fields) = &lines[index as usize] else {
            panic!("not a line");
        };
        let PropValue::List(tokens) = &fields[1].1 else {
            panic!("no tokens");
        };
        tokens
            .iter()
            .map(|token| (token_text(token), token_kind(token)))
            .collect()
    }

    #[test]
    fn highlights_keywords_comments_and_types() {
        let source = "pub fn feed() -> Nil {\n  // serve a snack\n}\n";
        let lines = highlight(source);
        assert_eq!(lines.len(), 4); // trailing newline → empty last line
        // Line 0: keyword ("pub fn"), name ("feed"), type ("Nil").
        let first = line_tokens(&lines, 0);
        assert!(first.iter().any(|(_, kind)| kind == "keyword"));
        assert!(
            first
                .iter()
                .any(|(text, kind)| kind == "type" && text.contains("Nil"))
        );
        // Line 1: a single comment token spanning the whole comment.
        let middle = line_tokens(&lines, 1);
        assert!(
            middle
                .iter()
                .any(|(text, kind)| kind == "comment" && text.contains("serve a snack"))
        );
    }

    #[test]
    fn broken_code_still_produces_lines() {
        let lines = highlight("pub fn oops( {\n");
        assert!(!lines.is_empty());
        for line in &lines {
            let PropValue::Struct(fields) = line else {
                panic!("not a line");
            };
            let PropValue::List(tokens) = &fields[1].1 else {
                panic!("no tokens");
            };
            assert!(tokens.iter().all(|t| matches!(t, PropValue::Struct(_))));
        }
    }
}
