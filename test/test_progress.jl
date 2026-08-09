@testitem "ProgressReporter aggregation and live rendering" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, true)

    # Single-operation phase renders its fixed label.
    LintApp._report_jw!(pr, "bootstrap", "Booting...", 0)
    s = String(take!(io))
    @test occursin("\r\e[2K", s)
    @test occursin("Preparing analysis environment", s)
    LintApp._report_jw!(pr, "bootstrap", "Done", 100)

    # Index keys aggregate into one (done/total) counter.
    pr.last_render = 0.0
    LintApp._report_jw!(pr, "index:/proj/a", "Queued", 0)
    @test occursin("Indexing environments (0/1)", String(take!(io)))

    pr.last_render = 0.0
    LintApp._report_jw!(pr, "index:/proj/b", "Queued", 0)
    @test occursin("Indexing environments (0/2)", String(take!(io)))

    pr.last_render = 0.0
    LintApp._report_jw!(pr, "index:/proj/a", "Done", 100)
    @test occursin("Indexing environments (1/2)", String(take!(io)))

    # A terminal report for a never-active key is a no-op.
    pr.last_render = 0.0
    LintApp._report_jw!(pr, "index:/proj/zzz", "Done", 100)
    @test isempty(String(take!(io)))
    @test pr.phase_done["index"] == 1

    # Lint progress takes priority over environment phases while underway.
    pr.last_render = 0.0
    LintApp._report_lint!(pr, 1, 3)
    @test occursin("Linting files (1/3)", String(take!(io)))

    # Reaching done == total hands the label back to the environment phases.
    pr.last_render = 0.0
    LintApp._report_lint!(pr, 3, 3)
    s = String(take!(io))
    @test !occursin("Linting files", s)

    # finish clears the live line and prints the summary.
    LintApp._finish_progress!(pr, 3)
    s = String(take!(io))
    @test occursin("\r\e[2K", s)
    @test occursin(r"Analyzed 3 files in \d+(\.\d+)?s", s)
end

@testitem "ProgressReporter plain-mode throttling" begin
    io = IOBuffer()
    pr = LintApp.ProgressReporter(io, false)

    # First report is a phase transition and always renders, as a full line.
    LintApp._report_lint!(pr, 1, 100)
    @test String(take!(io)) == "Linting files (1/100)\n"

    # Same-phase count updates inside the throttle window stay quiet.
    LintApp._report_lint!(pr, 2, 100)
    @test isempty(String(take!(io)))

    # Once the window has passed, the next update renders.
    pr.last_render = time() - 10.0
    LintApp._report_lint!(pr, 50, 100)
    @test String(take!(io)) == "Linting files (50/100)\n"

    # A phase transition bypasses the throttle.
    LintApp._report_jw!(pr, "index:/proj/a", "Queued", 0)
    @test isempty(String(take!(io)))  # lint still underway, label unchanged
    LintApp._report_lint!(pr, 100, 100)
    @test String(take!(io)) == "Indexing environments (0/1)\n"

    # Plain-mode finish has no clear sequence, just the summary line.
    LintApp._finish_progress!(pr, 100)
    s = String(take!(io))
    @test !occursin("\e[2K", s)
    @test occursin("Analyzed 100 files in ", s)
end

@testitem "CLI progress on stderr" setup=[CLIHelper] begin
    run_cli, CLEAN, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.CLEAN, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "a.jl"), CLEAN)
    write(joinpath(dir, "b.jl"), SYNTAX_ERROR)

    # Captured stderr is not a TTY, so progress uses plain lines.
    code, out, err = run_cli([dir])
    @test code == 1
    @test occursin("Linting files (", err)
    @test occursin("Analyzed 2 files in ", err)
    @test !occursin("Linting files", out)

    # --no-progress silences it entirely.
    _, _, err = run_cli(["--no-progress", dir])
    @test !occursin("Linting files", err)
    @test !occursin("Analyzed", err)
end

@testitem "-o output identical with and without progress" setup=[CLIHelper] begin
    run_cli, SYNTAX_ERROR = CLIHelper.run_cli, CLIHelper.SYNTAX_ERROR

    dir = mktempdir()
    write(joinpath(dir, "bad.jl"), SYNTAX_ERROR)

    f1 = joinpath(mktempdir(), "with.txt")
    f2 = joinpath(mktempdir(), "without.txt")
    run_cli(["--output-file", f1, dir])
    run_cli(["--no-progress", "--output-file", f2, dir])
    @test read(f1, String) == read(f2, String)
end
