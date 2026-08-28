@testitem "parse_commandline defaults" begin
    parsed = LintApp.parse_commandline(String[])
    @test parsed["path"] == ""
    @test parsed["format"] == "text"
    @test parsed["verbose"] == false
    @test parsed["quiet"] == false
    @test parsed["max-warnings"] == -1
    @test parsed["output-file"] === nothing
    @test parsed["experimental-v2"] == false

    parsed = LintApp.parse_commandline(["--experimental-v2"])
    @test parsed["experimental-v2"] == true
end

@testitem "experimental v2 flag flags an unused variable" setup=[CLIHelper] begin
    run_cli = CLIHelper.run_cli

    dir = mktempdir()
    write(joinpath(dir, "a.jl"), "function f(x)\n    unused_local = 1\n    return x\nend\n")

    # The unused_binding rule defaults to :hint; the v2 engine reports it
    # with the variable name in the message.
    code_on, out_on, _ = run_cli(["--experimental-v2", dir])
    @test code_on == 0
    @test occursin("unused_local", out_on)

    # Without the flag the run must still succeed (StaticLint may or may not
    # report its own version of the finding; we only assert no crash).
    code_off, _, _ = run_cli([dir])
    @test code_off == 0
end

@testitem "nonexistent path" setup=[CLIHelper] begin
    run_cli = CLIHelper.run_cli

    code, _, err = run_cli([joinpath(mktempdir(), "does-not-exist")])
    @test code == 1
    @test occursin("path does not exist", err)
end

@testitem "clean directory" setup=[CLIHelper] begin
    run_cli, CLEAN = CLIHelper.run_cli, CLIHelper.CLEAN

    dir = mktempdir()
    write(joinpath(dir, "a.jl"), CLEAN)

    code, out, _ = run_cli([dir])
    @test code == 0
    @test !occursin("error", out)
end

@testitem "syntax error produces an error finding and exit 1" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    code, out, _ = run_cli([dir])
    @test code == 1
    # Windows drive letters may round-trip through URIs with different casing.
    @test occursin("bad.jl", lowercase(out))
    @test occursin("error", out)

    # --verbose shows source context with a caret marker.
    code, out, _ = run_cli(["--verbose", dir])
    @test code == 1
    @test occursin("-->", out)
    @test occursin("^", out)
end

@testitem "JuliaLint.toml disables a rule" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)
    write(joinpath(dir, "JuliaLint.toml"), """
    [rules]
    syntax_errors = "off"
    """)

    code, out, _ = run_cli([dir])
    @test code == 0
    @test !occursin("bad.jl", lowercase(out))
end

@testitem "json output" setup=[CLIHelper] begin
    using JSON

    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    code, out, _ = run_cli(["--format", "json", dir])
    @test code == 1
    parsed = JSON.parse(out)
    @test parsed isa Vector
    @test length(parsed) == 1
    @test occursin("bad.jl", lowercase(parsed[1]["file"]))
    diags = parsed[1]["diagnostics"]
    @test !isempty(diags)
    d = diags[1]
    @test d["severity"] == "error"
    @test haskey(d, "message")
    @test haskey(d, "rule")
    @test d["startLine"] isa Integer
end

@testitem "sarif output" setup=[CLIHelper] begin
    using JSON

    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    code, out, _ = run_cli(["--format", "sarif", dir])
    @test code == 1
    sarif = JSON.parse(out)
    @test sarif["version"] == "2.1.0"
    run = sarif["runs"][1]
    @test run["tool"]["driver"]["name"] == "julialint"
    results = run["results"]
    @test !isempty(results)
    r = results[1]
    @test r["level"] == "error"
    @test !isempty(r["ruleId"])
    loc = r["locations"][1]["physicalLocation"]
    @test loc["artifactLocation"]["uri"] == "bad.jl"
    @test loc["region"]["startLine"] == 1
end

@testitem "output file" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)
    out_file = joinpath(mktempdir(), "lint.txt")

    code, out, _ = run_cli(["--output-file", out_file, dir])
    @test code == 1
    @test isempty(out)
    @test occursin("bad.jl", lowercase(read(out_file, String)))
end
