module LintApp

using JuliaWorkspaces, ArgParse, JSON, Logging

# `pkgversion` reads the version baked into the loaded package, so this keeps
# working for an installed app, where `../Project.toml` need not exist on disc.
const _VERSION = let
    v = pkgversion(@__MODULE__)
    v === nothing ? "0.0.0" : string(v)
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

    # The rule id is what a user writes in `JuliaLint.toml` to configure or
    # silence this finding, so it is the more useful thing to show.
    rule = _rule_id(diag)
    if !isempty(rule)
        print(io, " [", rule, "]")
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

    # --- Rule attribution ---
    rule = _rule_id(diag)
    if !isempty(rule)
        if use_color
            println(io, " "^(gutter_w + 1), _BLUE, "= ", _RESET, "rule: ", rule)
        else
            println(io, " "^(gutter_w + 1), "= ", "rule: ", rule)
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

# The stable rule id, as named in `JuliaLint.toml`. Diagnostics from analyses
# that predate rule ids fall back to their source.
_rule_id(diag) = diag.code === nothing ? diag.source : string(diag.code)

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
        "rule"        => _rule_id(diag),
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
            "ruleId"  => _rule_id(diag),
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
                        "name"           => "julialint",
                        "version"        => _VERSION,
                        "informationUri" => "https://github.com/julia-vscode/LintApp.jl",
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
        # Without `prog`, ArgParse falls back to `basename(Base.source_path())`,
        # which is empty under an app launch, and the usage line prints the
        # literal `<PROGRAM>` placeholder.
        prog = "julialint",
        description = "julialint — a static analysis tool for Julia code",
        version = _VERSION,
        add_version = true,
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
        "--no-progress"
            help = "disable progress output on stderr"
            action = :store_true
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
# Progress reporting (stderr)
# ---------------------------------------------------------------------------

# Progress goes to stderr so it never mixes with results on stdout (or -o).
# Two render modes: `live` rewrites a single status line in place (stderr is a
# TTY); otherwise plain lines are printed — one per phase transition plus
# throttled count updates — so CI logs show liveness without flooding.
#
# Updates arrive from two sources: the JuliaWorkspaces progress callback
# (phase-prefixed keys like "index:<env>", fired on the dynamic-feature reactor
# task) and the per-file lint callback (fired on the main task); the lock makes
# the shared state and interleaved stderr writes safe. Key-aggregation
# semantics follow LanguageServer's progress bars: a key is active from its
# first sub-100 report, a report >= 100 completes it, and a terminal report for
# a never-seen key is a no-op.
mutable struct ProgressReporter
    io::IO
    live::Bool
    lock::ReentrantLock
    phase_active::Dict{String,Dict{String,Int}}  # phase -> (active key -> latest pct)
    phase_seen::Dict{String,Set{String}}         # phase -> every key ever active
    phase_done::Dict{String,Int}                 # phase -> completed key count
    lint_done::Int
    lint_total::Int
    last_render::Float64
    last_line::String
    t0::Float64
end

ProgressReporter(io::IO, live::Bool) = ProgressReporter(
    io, live, ReentrantLock(),
    Dict{String,Dict{String,Int}}(), Dict{String,Set{String}}(), Dict{String,Int}(),
    0, 0, 0.0, "", time())

# Phase = key prefix before ':' (index/download/refresh), else the whole key.
function _progress_phase(key::String)
    i = findfirst(==(':'), key)
    return i === nothing ? key : key[1:prevind(key, i)]
end

function _report_jw!(pr::ProgressReporter, key::String, ::String, pct::Int)
    lock(pr.lock) do
        phase = _progress_phase(key)
        active = get!(Dict{String,Int}, pr.phase_active, phase)
        if pct >= 100
            haskey(active, key) || return
            delete!(active, key)
            pr.phase_done[phase] = get(pr.phase_done, phase, 0) + 1
        else
            push!(get!(Set{String}, pr.phase_seen, phase), key)
            active[key] = pct
        end
        _maybe_render!(pr)
    end
    return nothing
end

function _report_lint!(pr::ProgressReporter, done::Int, total::Int)
    lock(pr.lock) do
        pr.lint_done = done
        pr.lint_total = total
        _maybe_render!(pr)
    end
    return nothing
end

# The most user-meaningful thing currently in flight. Linting wins while it is
# underway; between lint rounds the environment phases take over again.
function _current_label(pr::ProgressReporter)
    if pr.lint_total > 0 && pr.lint_done < pr.lint_total
        return "Linting files ($(pr.lint_done)/$(pr.lint_total))"
    end
    for (phase, name) in (("index", "Indexing environments"),
                          ("download", "Downloading symbol caches"),
                          ("refresh", "Refreshing environments"))
        active = get(pr.phase_active, phase, nothing)
        (active === nothing || isempty(active)) && continue
        done = get(pr.phase_done, phase, 0)
        total = length(pr.phase_seen[phase])
        return "$name ($done/$total)"
    end
    isempty(get(pr.phase_active, "package-caches", Dict{String,Int}())) || return "Loading package caches"
    isempty(get(pr.phase_active, "bootstrap", Dict{String,Int}())) || return "Preparing analysis environment"
    return ""
end

# Label up to the "(k/n)" counter, for phase-transition detection.
_label_head(s::AbstractString) = String(first(split(s, " (")))

# Caller must hold pr.lock.
function _maybe_render!(pr::ProgressReporter)
    label = _current_label(pr)
    (isempty(label) || label == pr.last_line) && return
    now = time()
    # Phase transitions always render so short phases still show up; within a
    # phase, count updates are throttled (tight for a live line, coarse for
    # scrolling plain lines).
    if _label_head(label) == _label_head(pr.last_line)
        min_dt = pr.live ? 0.1 : 5.0
        now - pr.last_render < min_dt && return
    end
    if pr.live
        print(pr.io, "\r\e[2K", label)
    else
        println(pr.io, label)
    end
    flush(pr.io)
    pr.last_render = now
    pr.last_line = label
    return
end

# Clear the live status line (before error output or the final summary).
function _clear_progress!(pr::ProgressReporter)
    lock(pr.lock) do
        if pr.live && !isempty(pr.last_line)
            print(pr.io, "\r\e[2K")
            flush(pr.io)
        end
        pr.last_line = ""
    end
    return nothing
end

function _finish_progress!(pr::ProgressReporter, nfiles::Int)
    _clear_progress!(pr)
    println(pr.io, "Analyzed $nfiles files in $(round(time() - pr.t0, digits=1))s")
    flush(pr.io)
    return nothing
end

# ---------------------------------------------------------------------------
# Warning collection
# ---------------------------------------------------------------------------

# Buffers `Warn`-and-above log records emitted during the analysis run —
# the engine's environment/indexing warnings would otherwise print raw,
# interleaved with the progress output. Drained after the run into a
# "Workspace warnings" block. The analysis engine logs from concurrently
# scheduled tasks, hence the lock.
struct CollectingLogger <: Logging.AbstractLogger
    lock::ReentrantLock
    messages::Vector{String}
end
CollectingLogger() = CollectingLogger(ReentrantLock(), String[])

Logging.min_enabled_level(::CollectingLogger) = Logging.Warn
Logging.shouldlog(::CollectingLogger, level, _module, group, id) = true
Logging.catch_exceptions(::CollectingLogger) = true

# Keyword payloads (`@warn "..." key`) carry the context of a record, but a
# value can be arbitrarily large (an exception with backtrace), so cap it.
function _render_log_value(v)
    s = sprint(show, v)
    return length(s) > 200 ? string(first(s, 200), "…") : s
end

function Logging.handle_message(logger::CollectingLogger, level, message, _module, group, id, file, line; kwargs...)
    msg = string(message)
    if !isempty(kwargs)
        msg = string(msg, " (", join(("$k = $(_render_log_value(v))" for (k, v) in kwargs), ", "), ")")
    end
    lock(logger.lock) do
        push!(logger.messages, msg)
    end
    return nothing
end

_drain_warnings!(logger::CollectingLogger) = lock(logger.lock) do
    msgs = copy(logger.messages)
    empty!(logger.messages)
    msgs
end
_drain_warnings!(::Nothing) = String[]

# Deduplicated (order-preserving, with a repeat count) block on stderr, after
# the progress output is done and before the findings are written.
function _print_workspace_warnings(io, msgs, use_color)
    isempty(msgs) && return
    counts = Dict{String,Int}()
    order = String[]
    for m in msgs
        haskey(counts, m) || push!(order, m)
        counts[m] = get(counts, m, 0) + 1
    end
    println(io)
    if use_color
        println(io, _BOLD, "Workspace warnings:", _RESET)
    else
        println(io, "Workspace warnings:")
    end
    for m in order
        n = counts[m]
        suffix = n > 1 ? " (×$n)" : ""
        println(io, "  ", m, suffix)
    end
    flush(io)
    return
end

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

# Peel the wrappers the analysis engine adds on the way out — Salsa's
# `DerivedFunctionException` (whose `showerror` appends a multi-line Salsa
# trace) and `TaskFailedException` — so the user-facing line names the actual
# cause. Matched structurally rather than by type, since LintApp depends on
# neither Salsa nor the internals that throw these.
function _unwrap_error(err)
    for _ in 1:8
        if hasproperty(err, :captured_exception)
            err = getproperty(err, :captured_exception)
        elseif err isa TaskFailedException
            err = err.task.result
        elseif err isa CompositeException && !isempty(err.exceptions)
            err = first(err.exceptions)
        else
            break
        end
    end
    return err
end

# A single line naming the cause, for the top-level failure report.
function _brief_error(err)
    msg = sprint(showerror, _unwrap_error(err))
    return String(first(eachsplit(msg, '\n')))
end

function (@main)(ARGS)
    parsed_args = parse_commandline(ARGS)

    # --- Logging ---
    # With an explicit --log level the user asked for live log output; without
    # one, warnings are buffered by a CollectingLogger and reported as a
    # "Workspace warnings" block after the run instead of interleaving with
    # the progress output.
    log_level = parsed_args["log"]
    collector = nothing
    if log_level == "debug"
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    elseif log_level == "info"
        global_logger(ConsoleLogger(stderr, Logging.Info))
    else
        collector = CollectingLogger()
        global_logger(collector)
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

    # --- Progress reporting ---
    # Live single-line rendering only on a TTY and only when the ConsoleLogger
    # stays at Warn: with --log debug/info, log records share stderr and would
    # clobber a rewritten line, so fall back to plain progress lines.
    pr = if parsed_args["no-progress"]::Bool
        nothing
    else
        ProgressReporter(stderr, stderr isa Base.TTY && log_level === nothing)
    end

    # --- Lint ---
    # Anything the analysis engine throws (a corrupt symbol cache, a child
    # process dying, an internal error) is reported as a tool failure rather
    # than an uncaught-exception dump: exit code 2, distinct from 1 ("lint
    # findings"). The raw exception stays available under `--log debug`.
    local jw, all_diagnostics
    try
        jw = workspace_from_folders([target_path],
            dynamic=JuliaWorkspaces.DynamicIndexingOnly,
            symbolcache_download=true,
            progress_callback=pr === nothing ? nothing : (key, msg, pct) -> _report_jw!(pr, key, msg, pct))
        all_diagnostics = get_diagnostics_blocking(jw,
            progress_callback=pr === nothing ? nothing : (done, total) -> _report_lint!(pr, done, total))
        pr === nothing || _finish_progress!(pr, length(all_diagnostics))
    catch err
        err isa InterruptException && rethrow()
        pr === nothing || _clear_progress!(pr)
        # Buffered warnings often carry the context of the failure — show them.
        _print_workspace_warnings(stderr, _drain_warnings!(collector), stderr isa Base.TTY)
        @debug "Analysis failed" target_path exception=(err, catch_backtrace())
        printstyled(stderr, "error", color=:red, bold=true)
        println(stderr, ": julialint failed to analyze ", target_path, ": ", _brief_error(err))
        println(stderr, "       run with --log debug for the full stack trace")
        return 2
    end

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

    # --- Workspace warnings ---
    # Env-resolution failures arrive both as buffered log records and as
    # `environment_errors` diagnostics; the diagnostic is the canonical report,
    # so matching buffered records are dropped instead of shown twice.
    # (Computed before --quiet filters the diagnostics away.)
    env_error_messages = Set{String}(e[3].message for e in entries if e[3].code === :environment_errors)
    warnings = filter(m -> m ∉ env_error_messages, _drain_warnings!(collector))
    _print_workspace_warnings(stderr, warnings, stderr isa Base.TTY)

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

# ---------------------------------------------------------------------------
# Precompile workload
# ---------------------------------------------------------------------------

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    workload_dir = mktempdir()
    write(joinpath(workload_dir, "script.jl"), """
    function f(a)
        unused = 1
        return not_defined_xyz(a)
    end
    """)

    @compile_workload begin
        parse_commandline(String[])

        # DynamicOff so no child processes are spawned during precompilation.
        jw = JuliaWorkspaces.JuliaWorkspace(store_path=mktempdir())
        JuliaWorkspaces.add_folder_from_disc!(jw, workload_dir)
        all_diagnostics = get_diagnostics_blocking(jw)

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

        io = IOBuffer()
        counts = Dict{Symbol,Int}()
        for (_, _, diag, text_file) in entries
            _print_diagnostic(io, diag, text_file, false)
            _print_diagnostic(io, diag, text_file, true)
            _print_diagnostic_verbose(io, diag, text_file, false)
            counts[diag.severity] = get(counts, diag.severity, 0) + 1
        end
        _print_summary(io, counts)
        _output_json(io, entries)
        _output_sarif(io, entries, workload_dir)

        # The app's real path runs a dynamic workspace; repeat the diagnostics
        # run through workspace_from_folders with dynamic indexing so the
        # app-side specializations of that path land in this pkgimage. A plain
        # scripts folder requires no environment indexing, so no child Julia
        # processes are spawned during precompilation. symbolcache_download
        # must stay off here (no network during precompile).
        Logging.with_logger(Logging.NullLogger()) do
            # Exercise the progress path too, into a throwaway buffer, so its
            # specializations land in the pkgimage.
            pr = ProgressReporter(IOBuffer(), false)
            jw2 = workspace_from_folders([workload_dir];
                dynamic=JuliaWorkspaces.DynamicIndexingOnly,
                symbolcache_download=false,
                store_path=mktempdir(),
                progress_callback=(key, msg, pct) -> _report_jw!(pr, key, msg, pct))
            get_diagnostics_blocking(jw2,
                progress_callback=(done, total) -> _report_lint!(pr, done, total))
            _finish_progress!(pr, 1)
            put!(jw2.dynamic_feature.in_channel, JuliaWorkspaces.ShutdownMsg())
            while JuliaWorkspaces.state(jw2.dynamic_feature.controller_fsm) != JuliaWorkspaces.DynamicControllerStopped
                yield()
            end
        end
    end
end

end # module LintApp
