//! Protocol v2 wire types (the Rust mirror of
//! `gleam/packages/campy_bridge/src/campy_bridge.gleam`).
//!
//! The BEAM is the source of truth: every UI is a `ControlDesc` tree sent
//! with `LoadUi`, and later commands address controls by their integer id.
//! Nothing here names a zgui type — `controls.rs` is the only place that
//! turns descriptions into views.

/// A wire-friendly property value (mirrors Gleam `WireValue`).
#[derive(Debug, Clone, PartialEq)]
pub enum PropValue {
    Text(String),
    Bool(bool),
    Int(i64),
    Float(f64),
    List(Vec<PropValue>),
    Struct(Vec<(String, PropValue)>),
    /// Path to an image file.
    Image(String),
}

impl PropValue {
    pub fn text(&self) -> Option<&str> {
        match self {
            Self::Text(text) => Some(text),
            _ => None,
        }
    }

    pub fn boolean(&self) -> Option<bool> {
        match self {
            Self::Bool(value) => Some(*value),
            _ => None,
        }
    }

    pub fn integer(&self) -> Option<i64> {
        match self {
            Self::Int(value) => Some(*value),
            Self::Float(value) if value.fract() == 0.0 => Some(*value as i64),
            _ => None,
        }
    }

    pub fn number(&self) -> Option<f64> {
        match self {
            Self::Int(value) => Some(*value as f64),
            Self::Float(value) => Some(*value),
            _ => None,
        }
    }
}

/// The bytes a value contributes to a description's size cap.
pub fn prop_value_size(value: &PropValue) -> usize {
    match value {
        PropValue::Text(text) => text.len(),
        PropValue::Bool(_) | PropValue::Int(_) | PropValue::Float(_) => 16,
        PropValue::List(items) => items.iter().map(prop_value_size).sum::<usize>() + 8,
        PropValue::Struct(fields) => {
            fields
                .iter()
                .map(|(name, value)| name.len() + prop_value_size(value))
                .sum::<usize>()
                + 8
        }
        PropValue::Image(path) => path.len(),
    }
}

/// A plain-text rendering used by list/console fallbacks.
pub fn prop_value_text(value: &PropValue) -> String {
    match value {
        PropValue::Text(text) => text.clone(),
        PropValue::Bool(value) => value.to_string(),
        PropValue::Int(value) => value.to_string(),
        PropValue::Float(value) => value.to_string(),
        PropValue::List(_) | PropValue::Struct(_) => "[…]".into(),
        PropValue::Image(path) => path.clone(),
    }
}

/// One designed control (mirrors Gleam `ControlDesc`).
#[derive(Debug, Clone)]
pub struct ControlDesc {
    pub id: u64,
    pub kind: String,
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub enabled: bool,
    pub visible: bool,
    pub props: Vec<(String, PropValue)>,
    pub children: Vec<ControlDesc>,
}

impl ControlDesc {
    pub fn prop(&self, key: &str) -> Option<&PropValue> {
        self.props
            .iter()
            .find(|(name, _)| name == key)
            .map(|(_, value)| value)
    }
}

/// A validated UI document (the `LoadUi` payload).
#[derive(Debug, Clone)]
pub struct UiDocument {
    pub title: String,
    pub width: f64,
    pub height: f64,
    pub theme: String,
    pub controls: Vec<ControlDesc>,
}

/// A bridge command (mirrors Gleam `Command` minus the generation, which
/// the session layer attaches when routing).
#[derive(Debug, Clone)]
pub enum Op {
    LoadUi(UiDocument),
    SetText {
        control: u64,
        value: String,
    },
    SetBool {
        control: u64,
        key: String,
        value: bool,
    },
    SetInt {
        control: u64,
        key: String,
        value: i64,
    },
    SetFloat {
        control: u64,
        key: String,
        value: f64,
    },
    SetModel {
        control: u64,
        items: Vec<PropValue>,
    },
    SetGeometry {
        control: u64,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    SetCode {
        control: u64,
        source: String,
    },
    AppendConsole {
        control: u64,
        bytes: String,
    },
    /// `items` are `(start, end, class)` byte spans on `layer`.
    SetMarks {
        control: u64,
        layer: String,
        items: Vec<(u64, u64, String)>,
    },
    ReadText {
        control: u64,
        key: String,
    },
    /// Several ops that belong to one moment, applied as one command.
    ///
    /// A gesture changes a dozen things at once — the control's rectangle,
    /// the selection's outline and grips, the inspector's fields. Sent as
    /// separate commands they each wake the window, and the window draws a
    /// frame between them: a drag became two presents per pointer move, and
    /// the presents (vsync-paced) were what the pointer then waited on.
    Batch {
        ops: Vec<Op>,
    },
    Resize {
        width: f64,
        height: f64,
    },
}

/// A native event (mirrors Gleam `NativeEvent`; the session layer fills
/// `session` and `generation`).
#[derive(Debug, Clone)]
pub struct Event {
    pub kind: String,
    pub payload: String,
}

impl Event {
    pub fn new(kind: impl Into<String>, payload: impl Into<String>) -> Self {
        Self {
            kind: kind.into(),
            payload: payload.into(),
        }
    }
}

/// Sizes and limits, carried over from protocol v1.
pub const QUEUE_CAPACITY: usize = 4096;
pub const MAX_SESSIONS: usize = 32;
pub const MAX_SOURCE_BYTES: usize = 512 * 1024;
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
