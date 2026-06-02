# JuliaLint.jl

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

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success; no errors (and, with `--max-warnings`, the warning limit was not exceeded). |
| `1` | Errors were found, the warning limit was exceeded, or the given path is not a directory. |
