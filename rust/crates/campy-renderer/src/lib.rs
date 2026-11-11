//! Slint interpreter adapter. All live UI handles stay on the UI thread.

use slint_interpreter::{CompilationResult, Compiler, DiagnosticLevel};

pub mod sessions;

/// Compile an interpreted UI without creating a window or retaining handles.
/// A successful result is the number of exported components.
pub fn validate(source: &str) -> Result<usize, String> {
    // BEAM scheduler stacks are substantially smaller than ordinary Rust stacks.
    // Slint's standard-widget compiler needs its own bounded native stack.
    // Only owned text/results cross this boundary; no live UI handles are created.
    let source = source.to_owned();
    std::thread::Builder::new()
        .name("campy-ui-compiler".into())
        .stack_size(8 * 1024 * 1024)
        .spawn(move || compile(&source))
        .map_err(|error| format!("Cannot start UI compiler: {error}"))?
        .join()
        .map_err(|_| "UI compiler panicked".to_string())?
}

fn compile(source: &str) -> Result<usize, String> {
    compile_source(source).map(|result| result.component_names().count())
}

fn compile_source(source: &str) -> Result<CompilationResult, String> {
    let compiler = Compiler::default();
    let result =
        spin_on::spin_on(compiler.build_from_source(source.into(), "campy-preview.slint".into()));
    let errors: Vec<_> = result
        .diagnostics()
        .filter(|diagnostic| diagnostic.level() == DiagnosticLevel::Error)
        .map(|diagnostic| diagnostic.to_string())
        .collect();
    if errors.is_empty() {
        Ok(result)
    } else {
        Err(errors.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::validate;

    #[test]
    fn compiles_a_component_without_a_display() {
        assert_eq!(
            validate("export component Sample inherits Window { Text { text: \"hello\"; } }"),
            Ok(1)
        );
    }

    #[test]
    fn invalid_binding_is_a_diagnostic_not_a_panic() {
        let error = validate(
            "export component Sample inherits Window { Text { text: missing-property; } }",
        )
        .unwrap_err();
        assert!(error.contains("missing-property"), "{error}");
    }
}
