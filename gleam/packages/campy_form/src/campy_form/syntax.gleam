import gleam/list
import gleam/string

// Small Gleam tokenizer used for the IDE's read-only highlighted editor.
// It covers the subset the IDE generates plus ordinary hand-written code.
pub type Kind {
  Space
  Comment
  Keyword
  Str
  Number
  TypeName
  Name
  Punct
}

pub type Token {
  Token(kind: Kind, text: String)
}

pub fn color(kind: Kind) -> String {
  case kind {
    Space -> "#abb2bf"
    Comment -> "#7f848e"
    Keyword -> "#c678dd"
    Str -> "#98c379"
    Number -> "#d19a66"
    TypeName -> "#e5c07b"
    Name -> "#abb2bf"
    Punct -> "#56b6c2"
  }
}

const keywords = [
  "pub", "fn", "let", "case", "import", "type", "use", "if", "else", "as",
  "const", "opaque", "panic", "todo", "assert", "echo", "when", "with",
]

pub fn tokenize(line: String) -> List(Token) {
  scan(string.to_graphemes(line), [])
}

fn scan(chars: List(String), acc: List(Token)) -> List(Token) {
  case chars {
    [] -> list.reverse(acc)
    [first, ..rest] ->
      case first {
        " " | "\t" -> {
          let #(text, remaining) = take_while(chars, is_space)
          scan(remaining, [Token(Space, text), ..acc])
        }
        "/" ->
          case rest {
            ["/", ..comment] ->
              list.reverse([
                Token(Comment, "//" <> string.concat(comment)),
                ..acc
              ])
            _ -> scan(rest, [Token(Punct, "/"), ..acc])
          }
        "\"" -> {
          let #(text, remaining) = take_string(rest, ["\""], False)
          scan(remaining, [Token(Str, text), ..acc])
        }
        "`" -> {
          let #(text, remaining) = take_until(rest, "`", ["`"])
          scan(remaining, [Token(Str, text), ..acc])
        }
        _ ->
          case is_digit(first) {
            True -> {
              let #(text, remaining) = take_while(chars, is_number_char)
              scan(remaining, [Token(Number, text), ..acc])
            }
            False ->
              case is_name_start(first) {
                True -> {
                  let #(text, remaining) = take_while(chars, is_name_char)
                  scan(remaining, [Token(name_kind(text), text), ..acc])
                }
                False -> {
                  let #(text, remaining) = take_while(chars, is_punct)
                  scan(remaining, [Token(Punct, text), ..acc])
                }
              }
          }
      }
  }
}

fn name_kind(text: String) -> Kind {
  case list.contains(keywords, text) {
    True -> Keyword
    False ->
      case is_upper(text) {
        True -> TypeName
        False -> Name
      }
  }
}

fn take_while(
  chars: List(String),
  predicate: fn(String) -> Bool,
) -> #(String, List(String)) {
  take_while_loop(chars, predicate, [])
}

fn take_while_loop(
  chars: List(String),
  predicate: fn(String) -> Bool,
  acc: List(String),
) -> #(String, List(String)) {
  case chars {
    [first, ..rest] ->
      case predicate(first) {
        True -> take_while_loop(rest, predicate, [first, ..acc])
        False -> #(string.concat(list.reverse(acc)), chars)
      }
    [] -> #(string.concat(list.reverse(acc)), [])
  }
}

fn take_string(
  chars: List(String),
  acc: List(String),
  escaped: Bool,
) -> #(String, List(String)) {
  case chars {
    [] -> #(string.concat(list.reverse(acc)), [])
    [first, ..rest] ->
      case escaped {
        True -> take_string(rest, [first, ..acc], False)
        False ->
          case first {
            "\\" -> take_string(rest, ["\\", ..acc], True)
            "\"" -> #(string.concat(list.reverse(["\"", ..acc])), rest)
            _ -> take_string(rest, [first, ..acc], False)
          }
      }
  }
}

fn take_until(
  chars: List(String),
  terminator: String,
  acc: List(String),
) -> #(String, List(String)) {
  case chars {
    [] -> #(string.concat(list.reverse(acc)), [])
    [first, ..rest] ->
      case first == terminator {
        True -> #(string.concat(list.reverse([first, ..acc])), rest)
        False -> take_until(rest, terminator, [first, ..acc])
      }
  }
}

fn is_space(char: String) -> Bool {
  char == " " || char == "\t"
}

fn is_digit(char: String) -> Bool {
  string.contains("0123456789", char)
}

fn is_number_char(char: String) -> Bool {
  is_digit(char)
  || char == "_"
  || char == "."
  || char == "x"
  || char == "b"
  || char == "o"
}

fn is_name_start(char: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_", char)
}

fn is_name_char(char: String) -> Bool {
  is_name_start(char) || is_digit(char)
}

fn is_upper(text: String) -> Bool {
  case string.to_graphemes(text) {
    [first, ..] -> string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
    [] -> False
  }
}

fn is_punct(char: String) -> Bool {
  !is_space(char)
  && !is_digit(char)
  && !is_name_start(char)
  && char != "\""
  && char != "`"
  && char != "/"
}
