module JuliaLint

using JuliaWorkspaces, ArgParse, JSON, Logging

const _VERSION = let
    proj = joinpath(dirname(@__DIR__), "Project.toml")
    m = match(r"^version\s*=\s*\"([^\"]+)\""m, read(proj, String))
    m === nothing ? "0.0.0" : String(m[1])
end

const _SEVERITY_COLORS = Dict{Symbol,String}(
    :error       => "\e[31m",
    :warning     => "\e[33m",
    :information => "\e[36m",
    :hint        => "\e[2m",
)

const _RESET = "\e[0m"
const _BOLD = "\e[1m"
const _BLUE = "\e[34m"

# ---------------------------------------------------------------------------
# Line extraction helper
# ---------------------------------------------------------------------------

"""
    _get_line_text(st::JuliaWorkspaces.SourceText, line::Int) -> Union{String,Nothing}

Extract line `line` (1-based) from `st`, stripping trailing newline characters.
Returns `nothing` when `line` is out of range.
"""
function _get_line_text(st, line::Int)
    li = st.line_indices
    (line < 1 || line > length(li)) && return nothing
    start = li[line]
    stop = line < length(li) ? li[line + 1] - 1 : lastindex(st.content)
    # strip trailing \r and \n
    while stop >= start && st.content[stop] in ('\r', '\n')
        stop -= 1
    end
    return st.content[start:stop]
end

# ---------------------------------------------------------------------------
# Compact diagnostic (default text output)
# ---------------------------------------------------------------------------

function _print_diagnostic(io::IO, diag, text_file, use_color::Bool)
    pos = position_at(text_file.content, first(diag.range))
    abs_path = JuliaWorkspaces.uri2filepath(text_file.uri)

    loc = string(abs_path, ":", pos.line, ":", pos.column)

    if use_color
        color = get(_SEVERITY_COLORS, diag.severity, "")
        print(io, loc, ": ", color, string(diag.severity), _RESET)
    else
        print(io, loc, ": ", string(diag.severity))
    end

    print(io, ": ", diag.message)

    if !isempty(diag.source)
        print(io, " [", diag.source, "]")
    end

    println(io)
end

# ---------------------------------------------------------------------------
# Verbose diagnostic (Rust/clippy-style with code context)
# ---------------------------------------------------------------------------

function _print_diagnostic_verbose(io::IO, diag, text_file, use_color::Bool)
    st = text_file.content
    start_pos = position_at(st, first(diag.range))
    end_pos   = position_at(st, last(diag.range))
    abs_path  = JuliaWorkspaces.uri2filepath(text_file.uri)

    sev_str = string(diag.severity)
    sev_color = get(_SEVERITY_COLORS, diag.severity, "")

    # Determine context lines to show
    diag_line = start_pos.line
    first_ctx = max(1, diag_line - 1)
    last_ctx  = min(length(st.line_indices), diag_line + 1)

    # Gutter width for right-aligned line numbers
    gutter_w = ndigits(last_ctx)

    # --- Header: severity + message ---
    if use_color
        println(io, sev_color, _BOLD, sev_str, _RESET, ": ", diag.message)
    else
        println(io, sev_str, ": ", diag.message)
    end

    # --- Location arrow ---
    if use_color
        println(io, " "^(gutter_w + 1), _BLUE, "--> ", _RESET, abs_path, ":", diag_line, ":", start_pos.column)
    else
        println(io, " "^(gutter_w + 1), "--> ", abs_path, ":", diag_line, ":", start_pos.column)
    end

    # --- Blank separator ---
    _print_gutter(io, gutter_w, nothing, use_color)
    println(io)

    # --- Context lines ---
    for ln in first_ctx:last_ctx
        line_text = _get_line_text(st, ln)
        line_text === nothing && continue

        _print_gutter(io, gutter_w, ln, use_color)
        println(io, " ", line_text)

        # Caret marker under the diagnostic line
        if ln == diag_line
            # Compute span length (clamped to the same line)
            col_start = start_pos.column
            if start_pos.line == end_pos.line
                span_len = max(1, end_pos.column - start_pos.column + 1)
            else
                span_len = 1
            end

            _print_gutter(io, gutter_w, nothing, use_color)
            if use_color
                println(io, " ", " "^(col_start - 1), sev_color, "^"^span_len, _RESET)
            else
                println(io, " ", " "^(col_start - 1), "^"^span_len)
            end
        end
    end

    # --- Blank separator ---
    _print_gutter(io, gutter_w, nothing, use_color)
    println(io)

    # --- Source attribution ---
    if !isempty(diag.source)
        if use_color
            println(io, " "^(gutter_w + 1), _BLUE, "= ", _RESET, "source: ", diag.source)
        else
            println(io, " "^(gutter_w + 1), "= ", "source: ", diag.source)
        end
    end

    println(io)
end

function _print_gutter(io::IO, width::Int, line_num::Union{Int,Nothing}, use_color::Bool)
    if use_color
        if line_num === nothing
            print(io, " "^width, " ", _BLUE, "|", _RESET)
        else
            print(io, lpad(string(line_num), width), " ", _BLUE, "|", _RESET)
        end
    else
        if line_num === nothing
            print(io, " "^width, " ", "|")
        else
            print(io, lpad(string(line_num), width), " ", "|")
        end
    end
end

# ---------------------------------------------------------------------------
# JSON output
# ---------------------------------------------------------------------------

function _diagnostic_to_dict(diag, text_file)
    st = text_file.content
    start_pos = position_at(st, first(diag.range))
    end_pos   = position_at(st, last(diag.range))
    abs_path  = JuliaWorkspaces.uri2filepath(text_file.uri)

    return Dict{String,Any}(
        "file"        => abs_path,
        "startLine"   => start_pos.line,
        "startColumn" => start_pos.column,
        "endLine"     => end_pos.line,
        "endColumn"   => end_pos.column,
        "severity"    => string(diag.severity),
        "message"     => diag.message,
        "source"      => diag.source,
        "tags"        => [string(t) for t in diag.tags],
    )
end

function _output_json(io::IO, entries)
    # Group by file
    grouped = Dict{String,Vector{Dict{String,Any}}}()
    for (abs_path, _, diag, text_file) in entries
        d = _diagnostic_to_dict(diag, text_file)
        push!(get!(Vector{Dict{String,Any}}, grouped, abs_path), d)
    end

    result = [
        Dict{String,Any}(
            "file" => path,
            "diagnostics" => diags,
        )
        for (path, diags) in sort!(collect(grouped), by=first)
    ]

    JSON.print(io, result, 2)
    println(io)
end

# ---------------------------------------------------------------------------
# SARIF output (v2.1.0 — GitHub Code Scanning compatible)
# ---------------------------------------------------------------------------

const _SARIF_SEVERITY_MAP = Dict{Symbol,String}(
    :error       => "error",
    :warning     => "warning",
    :information => "note",
    :hint        => "note",
)

function _output_sarif(io::IO, entries, root_path::String)
    results = Dict{String,Any}[]

    for (abs_path, _, diag, text_file) in entries
        st = text_file.content
        start_pos = position_at(st, first(diag.range))
        end_pos   = position_at(st, last(diag.range))

        # Make path relative to root for SARIF artifactLocation
        rel_path = relpath(abs_path, root_path)
        # Normalize to forward slashes for URI compatibility
        rel_path = replace(rel_path, '\\' => '/')

        sarif_result = Dict{String,Any}(
            "ruleId"  => diag.source,
            "level"   => get(_SARIF_SEVERITY_MAP, diag.severity, "note"),
            "message" => Dict{String,Any}("text" => diag.message),
            "locations" => [
                Dict{String,Any}(
                    "physicalLocation" => Dict{String,Any}(
                        "artifactLocation" => Dict{String,Any}(
                            "uri"        => rel_path,
                            "uriBaseId"  => "%SRCROOT%",
                        ),
                        "region" => Dict{String,Any}(
                            "startLine"   => start_pos.line,
                            "startColumn" => start_pos.column,
                            "endLine"     => end_pos.line,
                            "endColumn"   => end_pos.column,
                        ),
                    ),
                ),
            ],
        )

        push!(results, sarif_result)
    end

    sarif = Dict{String,Any}(
        "\$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
        "version"  => "2.1.0",
        "runs" => [
            Dict{String,Any}(
                "tool" => Dict{String,Any}(
                    "driver" => Dict{String,Any}(
                        "name"           => "JuliaLint",
                        "version"        => _VERSION,
                        "informationUri" => "https://github.com/julia-vscode/JuliaLint.jl",
                    ),
                ),
                "originalUriBaseIds" => Dict{String,Any}(
                    "%SRCROOT%" => Dict{String,Any}(
                        "uri" => "file:///" * replace(root_path, '\\' => '/') * "/",
                    ),
                ),
                "results" => results,
            ),
        ],
    )

    JSON.print(io, sarif, 2)
    println(io)
end

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

function parse_commandline(ARGS)
    s = ArgParseSettings(
        description = "JuliaLint — a static analysis tool for Julia code",
    )

    @add_arg_table! s begin
        "path"
            help = "path to lint (defaults to current directory)"
            arg_type = String
            default = ""
            required = false
        "--log"
            help = "set log level (debug or info); warn/error always shown"
            arg_type = String
            metavar = "LEVEL"
            range_tester = x -> x in ("debug", "info")
        "--format", "-f"
            help = "output format: text, json, or sarif"
            arg_type = String
            default = "text"
            metavar = "FORMAT"
            range_tester = x -> x in ("text", "json", "sarif")
        "--verbose", "-v"
            help = "show source context around each diagnostic"
            action = :store_true
        "--quiet", "-q"
            help = "show only errors (suppress warnings, info, and hints)"
            action = :store_true
        "--max-warnings"
            help = "exit with code 1 if warning count exceeds N (-1 = unlimited)"
            arg_type = Int
            default = -1
            metavar = "N"
        "--output-file", "-o"
            help = "write output to a file instead of stdout"
            arg_type = String
            metavar = "FILE"
    end

    return parse_args(ARGS, s)
end

# ---------------------------------------------------------------------------
# Text output summary
# ---------------------------------------------------------------------------

function _print_summary(io::IO, counts::Dict{Symbol,Int})
    isempty(counts) && return

    parts = String[]
    for sev in (:error, :warning, :information, :hint)
        n = get(counts, sev, 0)
        n > 0 && push!(parts, "$n $(sev == :information ? "info" : sev)$(n != 1 ? "s" : "")")
    end
    if !isempty(parts)
        println(io)
        println(io, join(parts, ", "))
    end
end

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

function (@main)(ARGS)
    parsed_args = parse_commandline(ARGS)

    # --- Logging ---
    ENV["JULIA_LOAD_PATH"] = ";"
    log_level = parsed_args["log"]
    if log_level == "debug"
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    elseif log_level == "info"
        global_logger(ConsoleLogger(stderr, Logging.Info))
    else
        global_logger(ConsoleLogger(stderr, Logging.Warn))
    end

    # --- Target path ---
    raw_path = parsed_args["path"]
    target_path = isempty(raw_path) ? pwd() : abspath(raw_path)
    if !isdir(target_path)
        printstyled(stderr, "error", color=:red, bold=true)
        println(stderr, ": path does not exist or is not a directory: ", target_path)
        return 1
    end

    # --- Options ---
    fmt       = parsed_args["format"]::String
    verbose   = parsed_args["verbose"]::Bool
    quiet     = parsed_args["quiet"]::Bool
    max_warn  = parsed_args["max-warnings"]::Int
    out_file  = parsed_args["output-file"]

    # --- Lint ---
    jw = workspace_from_folders([target_path], dynamic=JuliaWorkspaces.DynamicIndexingOnly, symbolcache_download=true)
    all_diagnostics = get_diagnostics_blocking(jw)

    # --- Collect & sort entries ---
    entries = []
    for (uri, diagnostics) in all_diagnostics
        isempty(diagnostics) && continue
        text_file = get_text_file(jw, uri)
        abs_path = JuliaWorkspaces.uri2filepath(uri)
        for diag in diagnostics
            push!(entries, (abs_path, first(diag.range), diag, text_file))
        end
    end
    sort!(entries, by=x -> (x[1], x[2]))

    # --- Apply --quiet filter ---
    if quiet
        filter!(e -> e[3].severity === :error, entries)
    end

    # --- Determine output IO ---
    out_io = stdout
    close_io = false
    if out_file !== nothing
        out_io = open(out_file, "w")
        close_io = true
    end

    try
        use_color = !close_io && out_io isa Base.TTY

        if fmt == "json"
            _output_json(out_io, entries)
        elseif fmt == "sarif"
            _output_sarif(out_io, entries, target_path)
        else
            # text format
            counts = Dict{Symbol,Int}()
            for (_, _, diag, text_file) in entries
                if verbose
                    _print_diagnostic_verbose(out_io, diag, text_file, use_color)
                else
                    _print_diagnostic(out_io, diag, text_file, use_color)
                end
                counts[diag.severity] = get(counts, diag.severity, 0) + 1
            end
            _print_summary(out_io, counts)
        end
    finally
        close_io && close(out_io)
    end

    # --- Exit code ---
    n_errors   = count(e -> e[3].severity === :error,   entries)
    n_warnings = count(e -> e[3].severity === :warning, entries)

    if n_errors > 0
        return 1
    end
    if max_warn >= 0 && n_warnings > max_warn
        return 1
    end

    return 0
end

end # module JuliaLint
