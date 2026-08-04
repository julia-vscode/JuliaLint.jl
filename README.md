# JuliaLint.jl

> [!WARNING]
> **JuliaLint is beta software.** It is still under active development, may be
> unstable, and everything described here — including commands, options, output,
> and the configuration format — is subject to change without notice.

`julialint` is a command line static analysis tool for Julia. It exposes the
linting capabilities of [JuliaWorkspaces.jl](https://github.com/julia-vscode/JuliaWorkspaces.jl)
as a standalone app, and is a companion to [JuliaFormat.jl](https://github.com/julia-vscode/JuliaFormat.jl).

`julialint` analyzes Julia source files and reports diagnostics — errors,
warnings, information, and hints — that help you catch problems before running
your code. Diagnostics can be printed as human-readable text, or emitted as JSON
or SARIF for integration with other tools and CI systems.

## Installation

`julialint` is distributed as a Julia app. Install it with the `app` command in the package REPL:

```
pkg> app add https://github.com/julia-vscode/JuliaLint.jl
```

This installs the `julialint` executable and makes it available on your
`PATH`.

## Usage

```
julialint [options] [path]
```

`path` may be a single directory. The directory is searched recursively for
Julia files. When no path is given, the current directory is used.

### Options

| Option | Description |
| --- | --- |
| `-f`, `--format FORMAT` | Output format: `text` (default), `json`, or `sarif`. |
| `-v`, `--verbose` | Show source context around each diagnostic. |
| `-q`, `--quiet` | Show only errors (suppress warnings, info, and hints). |
| `--max-warnings N` | Exit with code `1` if the warning count exceeds `N` (`-1` = unlimited). |
| `-o`, `--output-file FILE` | Write output to a file instead of stdout. |
| `--log LEVEL` | Set the log level (`debug` or `info`); warnings and errors are always shown. |
| `--version` | Print the version and exit. |
| `-h`, `--help` | Print help and exit. |

### Examples

```sh
# Lint every Julia file under src/
julialint src/

# Lint the current directory
julialint

# Show source context around each diagnostic
julialint --verbose src/

# Show only errors
julialint --quiet src/

# Fail (exit code 1) if there are more than 10 warnings — useful in CI
julialint --max-warnings 10 src/

# Emit JSON for tooling
julialint --format json -o diagnostics.json src/

# Emit SARIF for GitHub Code Scanning
julialint --format sarif -o results.sarif src/
```

## Output formats

| Format | Description |
| --- | --- |
| `text` | Human-readable diagnostics with a summary count. Use `--verbose` for Rust/clippy-style source context with caret markers. |
| `json` | Structured diagnostics grouped by file, suitable for further processing. |
| `sarif` | SARIF v2.1.0 output compatible with GitHub Code Scanning and other SARIF consumers. |

## Configuration

> [!WARNING]
> The `julialint.toml` configuration format is **experimental**. The available
> keys, their values, and default behavior may change in any release without
> notice.

Linting behavior can be customized with a `julialint.toml` file (the name is
matched case-insensitively, so `JuliaLint.toml` also works). Place the file in
your project; it applies to all Julia files in that directory and its
subdirectories.

Configuration is hierarchical: when several `julialint.toml` files exist along a
file's path, they are merged with deeper (more specific) files overriding
shallower ones on a per-key basis.

Every option is a boolean (`true`/`false`) unless noted otherwise. All checks
are enabled by default except `syntax-warnings`.

### Diagnostic categories

| Key | Default | Description |
| --- | --- | --- |
| `syntax-errors` | `true` | Report Julia syntax errors. |
| `syntax-warnings` | `false` | Report Julia syntax warnings. |
| `testitem-errors` | `true` | Report errors in `@testitem` blocks. |
| `toml-syntax-errors` | `true` | Report TOML syntax errors in config, `Project.toml`, and `Manifest.toml` files. |
| `lint-config-errors` | `true` | Report invalid keys or values in the `julialint.toml` file itself. |
| `format-config-errors` | `true` | Report errors in formatter configuration files. |
| `static-lint` | `true` | Master switch for all StaticLint semantic checks below. Set to `false` to disable them all at once. |
| `missing-refs` | `"symbols"` | Control reporting of missing references. One of `"none"` (off), `"symbols"` (identifiers only), or `"all"`. |

### StaticLint checks

These checks apply only when `static-lint` is enabled.

| Key | Default | Description |
| --- | --- | --- |
| `call` | `true` | Flag possible method call errors (wrong number/type of arguments). |
| `iter` | `true` | Flag loop iterators that will likely error. |
| `nothingcomp` | `true` | Flag comparisons against `nothing` that should use `isnothing`/`===`. |
| `constif` | `true` | Flag boolean literals used as an `if` condition (always or never runs). |
| `lazy` | `true` | Flag `&&`/`||` whose first argument is a boolean literal. |
| `datadecl` | `true` | Flag non-`DataType` values used in a type declaration. |
| `typeparam` | `true` | Flag type parameters that are declared but never used. |
| `modname` | `true` | Flag a module whose name matches that of its parent. |
| `pirates` | `true` | Flag type piracy (extending imported functions without an owned type). |
| `useoffuncargs` | `true` | Flag function arguments that are declared but never used. |
| `kwdefault` | `true` | Flag keyword default values that don't match the argument type. |
| `literal` | `true` | Flag inappropriate use of literal values. |
| `break-continue` | `true` | Flag `break`/`continue` used outside a loop. |
| `constdecl` | `true` | Flag invalid `const` declarations and redefinitions. |

### Example

```toml
# julialint.toml

# Surface syntax warnings in addition to errors
syntax-warnings = true

# Report every missing reference, not just identifiers
missing-refs = "all"

# Turn off a couple of noisy checks
useoffuncargs = false
literal = false
```

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success; no errors (and, with `--max-warnings`, the warning limit was not exceeded). |
| `1` | Errors were found, the warning limit was exceeded, or the given path is not a directory. |
| `2` | `julialint` itself failed to analyze the project. Re-run with `--log debug` for the full stack trace. |
