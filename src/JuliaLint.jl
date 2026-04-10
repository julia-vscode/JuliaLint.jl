module JuliaLint

using JuliaWorkspaces

const _SEVERITY_COLORS = Dict{Symbol,String}(
    :error       => "\e[31m",
    :warning     => "\e[33m",
    :information => "\e[36m",
    :hint        => "\e[2m",
)

function _print_diagnostic(io::IO, diag, text_file, base_path, use_color::Bool)
    pos = position_at(text_file.content, first(diag.range))
    abs_path = JuliaWorkspaces.uri2filepath(text_file.uri)
    rel_path = relpath(abs_path, base_path)

    if use_color
        file_uri = string(text_file.uri)
        print(io, "\e]8;;", file_uri, "\e\\", rel_path, "\e]8;;\e\\")
    else
        print(io, rel_path)
    end

    print(io, ":", pos.line, ":", pos.column, ": ")

    sev_str = string(diag.severity)
    if use_color
        color = get(_SEVERITY_COLORS, diag.severity, "")
        print(io, color, sev_str, "\e[0m")
    else
        print(io, sev_str)
    end

    print(io, ": ", diag.message)

    if !isempty(diag.source)
        print(io, " [", diag.source, "]")
    end

    println(io)
end

function (@main)(ARGS)
    ENV["JULIA_LOAD_PATH"] = ";"
    jw = workspace_from_folders([pwd()], dynamic=JuliaWorkspaces.DynamicIndexingOnly)

    all_diagnostics = get_diagnostics_blocking(jw)

    use_color = stdout isa Base.TTY
    base_path = pwd()

    entries = []
    for (uri, diagnostics) in all_diagnostics
        isempty(diagnostics) && continue
        text_file = get_text_file(jw, uri)
        rel_path = relpath(JuliaWorkspaces.uri2filepath(uri), base_path)
        for diag in diagnostics
            push!(entries, (rel_path, first(diag.range), diag, text_file))
        end
    end
    sort!(entries, by=x -> (x[1], x[2]))

    counts = Dict{Symbol,Int}()
    for (_, _, diag, text_file) in entries
        _print_diagnostic(stdout, diag, text_file, base_path, use_color)
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
