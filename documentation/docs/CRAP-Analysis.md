# CRAP Analysis

GUT can calculate a Change Risk Anti-Patterns (CRAP) score for each named
GDScript method while it runs tests.  CRAP combines cyclomatic complexity
(`CC`) with executable-line coverage:

```text
CRAP = CC² × (1 - coverage)³ + CC
```

Complex code is therefore not automatically a problem, but complex code with
little coverage quickly receives a high score.

CRAP analysis is disabled by default.  Add at least one source directory to
enable it:

```json
{
  "dirs": ["res://test/unit"],
  "crap_dirs": ["res://src"],
  "crap_excludes": ["res://src/generated/*", "res://src/vendor"],
  "crap_threshold": 30.0,
  "crap_fail_on_threshold": false,
  "crap_json_file": "user://crap-report.json"
}
```

The same settings are available in the GUT panel under **CRAP Analysis** and
from the [command line](Command-Line).

## Settings

| Config key | Command-line option | Default | Meaning |
| --- | --- | --- | --- |
| `crap_dirs` | `-gcrap_dir` | `[]` | Source directories to analyze recursively.  An empty list disables analysis. |
| `crap_excludes` | `-gcrap_exclude` | `[]` | Exact paths, directory paths, or wildcard patterns to exclude. |
| `crap_threshold` | `-gcrap_threshold` | `30.0` | A method violates the threshold when its score is greater than or equal to this value. |
| `crap_fail_on_threshold` | `-gcrap_fail_on_threshold` | `false` | Return a non-zero process exit code when at least one method violates the threshold. |
| `crap_json_file` | `-gcrap_json_file` | `""` | Optional standalone JSON report path. |

The threshold is advisory unless `crap_fail_on_threshold` is enabled.  An
incomplete analysis always causes a non-zero process exit code, even when the
threshold gate is disabled.  A non-zero exit code explicitly set by a post-run
hook is preserved; CRAP only changes a zero code to `1`.

GUT automatically excludes its own scripts, configured test scripts and test
directories, and pre/post-run hooks.  User exclusions are added to those hard
exclusions.

## What is measured

The analyzer reports named `func` and `static func` methods, inner-class
methods, and property getters and setters.  Anonymous lambdas and their bodies
are excluded.  Only GDScript source is supported.

Cyclomatic complexity starts at `1` and adds one for each:

- `if`, `elif`, ternary `if`, `for`, and `while`;
- `and`, `or`, `&&`, and `||`;
- non-default `match` arm; and
- `when` guard.

`else`, `break`, and `continue` do not increase complexity.  Keywords inside
comments and strings do not count.

Coverage uses instrumentable executable physical lines.  A multiline
statement counts on its first line, several statements on one line count once,
and inline suite bodies count on the line containing the body.  Blank lines,
comments, signatures, and pure control-flow headers do not count.

GUT injects probes into loaded GDScript resources in memory before test scripts
are collected, restores those resources after the run, and never modifies
source files on disk.  Repeating a run with the same configuration resets its
coverage.  If a reused GUT runner receives changed configuration or analyzed
source inside one process, the report is marked incomplete with
`RESTART_REQUIRED`; start a fresh process so method identities cannot be mixed.
Code executed by an autoload before GUT prepares the run cannot be observed.

## Output

The console prints a summary followed by up to 20 methods with the highest
scores.  The report uses schema version `1` and contains:

- `status`: `disabled`, `complete`, or `incomplete`;
- `metric`: formula, coverage model, threshold, and gate setting;
- `summary`: file/method/line totals, coverage, violations, maximum score, and
  excluded lambda count;
- `methods`: class and method identity, source range, complexity, coverage,
  CRAP score, uncovered lines, and threshold status; and
- `diagnostics`: structured analysis or export errors.

When enabled, the normal GUT result JSON includes the report as
`crap_analysis`.  Set `crap_json_file` when a standalone report is more
convenient for CI.

The report is finalized before the post-run hook, so a hook can inspect it:

```gdscript
extends GutHookScript

func run():
    var report = gut.get_crap_report()
    if report.status == "complete":
        print("Maximum CRAP score: ", report.summary.max_crap)
```

Calling `gut.get_crap_report()` when analysis is disabled returns
`{"status": "disabled"}`.
