@testmodule CLIHelper begin
    using LintApp

    # Run LintApp.main with captured stdout/stderr, returning
    # (exit_code, stdout::String, stderr::String).
    function run_cli(args::Vector{String})
        out_path, out_io = mktemp()
        err_path, err_io = mktemp()
        local code
        try
            code = redirect_stdio(() -> LintApp.main(args); stdout=out_io, stderr=err_io)
        finally
            close(out_io)
            close(err_io)
        end
        return code, read(out_path, String), read(err_path, String)
    end

    const CLEAN = "x = 1\n"
    const SYNTAX_ERROR = "function foo( end\n"
end
