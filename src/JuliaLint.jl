module JuliaLint

using JuliaWorkspaces, ArgParse, Logging

const _SEVERITY_COLORS = Dict{Symbol,String}(
    :error       => "\e[31m",
    :warning     => "\e[33m",
    :information => "\e[36m",
    :hint        => "\e[2m",
)

function _print_diagnostic(io::IO, diag, text_file, use_color::Bool)
    pos = position_at(text_file.content, first(diag.range))
    abs_path = JuliaWorkspaces.uri2filepath(text_file.uri)

    loc = string(abs_path, ":", pos.line, ":", pos.column)

    if use_color
        color = get(_SEVERITY_COLORS, diag.severity, "")
        print(io, loc, ": ", color, string(diag.severity), "\e[0m")
    else
        print(io, loc, ": ", string(diag.severity))
    end

    print(io, ": ", diag.message)

    if !isempty(diag.source)
        print(io, " [", diag.source, "]")
    end

    println(io)
end

function parse_commandline(ARGS)
    s = ArgParseSettings()

    @add_arg_table! s begin
        "--log"
            help = "set log level (debug or info); warn/error always shown"
            arg_type = String
            metavar = "LEVEL"
            range_tester = x -> x in ("debug", "info")
    end

    return parse_args(ARGS, s)
end

function (@main)(ARGS)
    parsed_args = parse_commandline(ARGS)
    ENV["JULIA_LOAD_PATH"] = ";"
    log_level = parsed_args["log"]
    if log_level == "debug"
        global_logger(ConsoleLogger(stderr, Logging.Debug))
    elseif log_level == "info"
        global_logger(ConsoleLogger(stderr, Logging.Info))
    else
        global_logger(ConsoleLogger(stderr, Logging.Warn))
    end
    jw = workspace_from_folders([pwd()], dynamic=JuliaWorkspaces.DynamicIndexingOnly)

    all_diagnostics = get_diagnostics_blocking(jw)

    use_color = stdout isa Base.TTY

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

    counts = Dict{Symbol,Int}()
    for (_, _, diag, text_file) in entries
        _print_diagnostic(stdout, diag, text_file, use_color)
        counts[diag.severity] = get(counts, diag.severity, 0) + 1
    end

    if !isempty(counts)
        parts = String[]
        for sev in (:error, :warning, :information, :hint)
            n = get(counts, sev, 0)
            n > 0 && push!(parts, "$n $(sev == :information ? "info" : sev)$(n != 1 ? "s" : "")")
        end
        if !isempty(parts)
            println()
            println(join(parts, ", "))
        end
    end
end

end # module JuliaLint
