import Foundation
import ForkcastCore

// Single source of truth for `forkcast help`, `forkcast <cmd> --help`, `forkcast help --json` and the man page.

/// Read from the enclosing Forkcast.app's Info.plist (stamped by `make` from the git tag).
let version: String = {
    guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return "dev" }
    let plist = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
    return (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "dev"
}()

struct Option: Codable { let flag: String; let help: String }

struct Command: Codable {
    let name: String
    var aliases: [String] = []
    let category: String
    let synopsis: String
    let summary: String
    var details: String = ""
    var options: [Option] = []
    var examples: [String] = []
    var exitCodes: String = "0 success · 1 error · 3 Forkcast not reachable"
}

let jsonOpt = Option(flag: "--json", help: "Print the raw JSON response (stable field names; see `forkcast help api`).")

let commands: [Command] = [
    // MARK: Look
    Command(name: "status", category: "Look",
            synopsis: "forkcast status [--json]",
            summary: "One snapshot of the whole machine: power, CPU, memory, disk, network, headroom, alerts, top groups and jobs.",
            details: """
            Power shows charger watts, total draw, net battery flow (+ into the battery, − out of it — the truth even when \
            macOS says "charging") and time to full/empty at the current flow, then the reconciliation \
            CPU + GPU + memory/SoC + display & other = total. Answers in well under 100 ms. Right after Forkcast starts, \
            rates need a second sample: status waits up to 3 s, and the JSON carries "warmingUp": true until then.
            """,
            options: [jsonOpt],
            examples: ["forkcast status", "forkcast status --json | jq '.power.netBatteryW'"]),
    Command(name: "ps", aliases: ["processes"], category: "Look",
            synopsis: "forkcast ps [--by job|app|tree] [--sort power|cpu|mem] [--all] [--limit N] [--json]",
            summary: "Processes grouped by job (default), by app, or as a process tree, with power, CPU and memory.",
            details: """
            Job grouping puts every process under the top-level process of its job (the first process below a shell, \
            terminal or agent), labelled from its command line — three renders started from one terminal are three rows. \
            Registered jobs (see `forkcast run`) override the automatic grouping. Memory is the physical footprint. \
            Short-lived children (e.g. a renderer started for each item) are credited to their parent's job when they \
            exit, so a job's CPU and power include work done by processes too brief to be sampled. Idle groups are \
            hidden unless --all is given (registered jobs are always shown).
            """,
            options: [Option(flag: "--by job|app|tree", help: "Grouping (default: job)."),
                      Option(flag: "--sort power|cpu|mem", help: "Sort order (default: power, then CPU)."),
                      Option(flag: "--all", help: "Include idle groups (under 0.5% CPU and 0.01 W)."),
                      Option(flag: "--limit N", help: "Rows to print (default 30; JSON includes up to N processes per group)."), jsonOpt],
            examples: ["forkcast ps", "forkcast ps --sort cpu", "forkcast ps --all --sort mem", "forkcast ps --by tree",
                       "forkcast ps --json | jq '.[0].processes[].command'"]),
    Command(name: "headroom", category: "Look",
            synopsis: "forkcast headroom [--group G] [--json]",
            summary: "Can I add more work? Free resources, a cost card per kind of job, and an estimate with its bottleneck.",
            details: """
            Free CPU is the 90th percentile over the last 30 minutes. Each cost card measures the running instances of one \
            kind of job (p90 cores, peak memory, watts, disk MB/min); only *active* instances count — ones that used CPU \
            or disk in the last 2 minutes — so lanes idling while they wait for an earlier lane don't dilute the cost \
            (they are shown as "waiting"). The estimate is floor(free ÷ per-instance cost) for \
            each resource; the smallest names the bottleneck. Confidence drops when the cost varied a lot.
            """,
            options: [Option(flag: "--group G", help: "Only cost cards whose kind or label contains G."), jsonOpt],
            examples: ["forkcast headroom", "forkcast headroom --group render --json"]),
    Command(name: "history", category: "Look",
            synopsis: "forkcast history METRIC [--range 24h] [--step 5m] [--json]",
            summary: "Time series of a recorded metric (kept for 30 days).",
            details: "Metrics: \(historyMetrics.joined(separator: ", ")). Gauges are averaged per step; *_mb counters are summed.",
            options: [Option(flag: "--range DUR", help: "How far back (s/m/h/d; default 24h)."),
                      Option(flag: "--step DUR", help: "Bucket size (default 60s)."), jsonOpt],
            examples: ["forkcast history net_battery_w --range 6h --step 10m", "forkcast history disk_free_gb --range 7d --step 1h --json"]),
    Command(name: "events", category: "Look",
            synopsis: "forkcast events [--since 1h] [--types a,b] [--json]",
            summary: "The timeline: plug/unplug, sleep/wake, boot, alerts, guard actions, jobs, crashes, volumes.",
            details: """
            Types are dotted (power.plugged, job.finished, alert.fired, guard.pause, …); --types job matches every job.* type. \
            --since takes a duration (90m, 2h, 1d), a unix timestamp or an ISO-8601 date.
            """,
            options: [Option(flag: "--since WHEN", help: "Start of the window (default 1h)."),
                      Option(flag: "--types LIST", help: "Comma-separated type prefixes, e.g. job,alert,power."), jsonOpt],
            examples: ["forkcast events --since 8h", "forkcast events --types job,crash --since 1d --json"]),
    Command(name: "changes", category: "Look",
            synopsis: "forkcast changes [--since 1h] [--json]",
            summary: "What changed since a time: jobs started, finished, failed, went stale; crashes; alerts.",
            options: [Option(flag: "--since WHEN", help: "Duration, unix timestamp or ISO-8601 (default 1h)."), jsonOpt],
            examples: ["forkcast changes --since 3h", "forkcast changes --since \"$LAST_CHECK\" --json"]),
    Command(name: "open", category: "Look",
            synopsis: "forkcast open",
            summary: "Open the Forkcast dashboard window.",
            examples: ["forkcast open"]),

    // MARK: Jobs
    Command(name: "run", category: "Jobs",
            synopsis: "forkcast run --name N [--group G] [--log FILE] [--regex R] [--total T] [--after JOB|PID] -- COMMAND [ARGS…]",
            summary: "Start a command and track it as a job: its whole process tree, progress, ETA and exit code.",
            details: """
            The command inherits your terminal (stdin/stdout/stderr). Ctrl-C, SIGTERM and SIGHUP are forwarded to it, and \
            forkcast exits with the command's exit code (128+signal if it was killed). With --after, the job is registered \
            as queued and starts when JOB finishes (or, given a pid, when that process exits). With --log, progress is read \
            from the last "done/total" match in the file (or --regex with two capture groups); a relative path is resolved \
            against the current directory and stored as an absolute path. Re-using a name starts a new run (#2, #3…): the \
            previous run moves to the job's history, and `job NAME …` conditions always mean the latest run. If Forkcast \
            isn't running the command still runs, untracked.
            """,
            options: [Option(flag: "--name N", help: "Job name (default: the command's file name). Re-using a name starts a new run; the old one is kept in history."),
                      Option(flag: "--group G", help: "Job group for ETAs, pause/resume and guards (default: default)."),
                      Option(flag: "--log FILE", help: "Log file to read progress and activity from."),
                      Option(flag: "--regex R", help: "Progress regex; group 1 = done, group 2 = total. Default (\\d+)\\s*/\\s*(\\d+)."),
                      Option(flag: "--total T", help: "Total items, for progress % and ETA."),
                      Option(flag: "--after JOB", help: "Queue: wait for JOB to finish (or a pid, e.g. 4242 or 'pid 4242', to exit) before starting."),
                      Option(flag: "--stale DUR", help: "Stale after this long without progress, heartbeat or log output (e.g. 3h), or 'never'. Default 15m (config: alerts.jobStaleMinutes).")],
            examples: ["forkcast run --name batch7 --group renders --log render.log --total 1721 -- ./render.sh batch7",
                       "forkcast run --name lane2 --group captures --after 4242 -- ./lane.sh 2   # starts when pid 4242 exits",
                       "forkcast run --name queue --group renders --log queue.log --stale 3h -- ./queue.sh   # logs only START/END",
                       "forkcast run --name batch7-2 --group renders --after batch7 -- ./render.sh batch7-2"],
            exitCodes: "the command's own exit code · 127 command not found · 2 usage error"),
    Command(name: "register", category: "Jobs",
            synopsis: "forkcast register --name N --pid PID [--group G] [--log FILE] [--regex R] [--total T] [--after JOB] [--json]",
            summary: "Track an already-running process (and every child it spawns) as a job.",
            details: "Without --pid the job is registered as queued; start it with `forkcast start NAME` (with or without a pid), or by reporting progress. The exit code of a registered (not `run`) process can't be known; it ends as done-ok if progress reached the total, otherwise as ended (state \"exited\", shown neutrally, not as an alert). A relative --log is resolved against the current directory.",
            options: [Option(flag: "--name N", help: "Job name (required)."), Option(flag: "--pid PID", help: "Root process of the job."),
                      Option(flag: "--group G", help: "Job group (default: default)."), Option(flag: "--log FILE", help: "Log to read progress from."),
                      Option(flag: "--regex R", help: "Progress regex (see `forkcast run --help`)."), Option(flag: "--total T", help: "Total items."),
                      Option(flag: "--after JOB", help: "Predecessor, for queued-ETA estimates."),
                      Option(flag: "--stale DUR", help: "Stale after this long without progress, heartbeat or log output (e.g. 3h), or 'never'. Default 15m (config: alerts.jobStaleMinutes)."), jsonOpt],
            examples: ["forkcast register --name ghidra --group analysis --pid 4242", "./render.sh & forkcast register --name r1 --group renders --pid $! --log render.log"]),
    Command(name: "progress", category: "Jobs",
            synopsis: "forkcast progress NAME [DONE[/TOTAL]] [--total T] [--log FILE] [--regex R] [--stale DUR] [--note TEXT] [--json]",
            summary: "Report progress for a job, or change how its progress is measured, without restarting it.",
            details: "For a job with no process (see `forkcast start`), reporting a count starts a queued job, and reaching the total ends it as done-ok. DONE is optional: `--total` alone sets or changes the total of a running job, and `--log`/`--regex` attach a log-based progress rule to it (the log is read on the next sample). Pass an empty --log '' or --regex '' to remove one.",
            options: [Option(flag: "--total T", help: "Set or change the total."),
                      Option(flag: "--log FILE", help: "Read progress and activity from this log from now on."),
                      Option(flag: "--regex R", help: "Progress regex for the log; group 1 = done, group 2 = total."),
                      Option(flag: "--stale DUR", help: "Change the stale limit (e.g. 3h, or 'never')."),
                      Option(flag: "--note TEXT", help: "Short status note shown with the job."), jsonOpt],
            examples: ["forkcast progress batch7 412/1721", "forkcast progress batch7 413 --note 'bank B'",
                       "forkcast progress arturia-q1 --total 863", "forkcast progress presets2 --log captures/_logs/presets.log --regex 'preset (\\d+) of (\\d+)'"]),
    Command(name: "state", category: "Jobs",
            synopsis: "forkcast state NAME waiting [--on JOB|PID] | forkcast state NAME running [--json]",
            summary: "Mark a job as waiting for another job or process (not stale, not counted in cost cards), or running again.",
            details: "A waiting job is shown as waiting instead of running with a long \"last activity\" time, never goes stale, and is left out of headroom cost cards. It returns to running by itself when what it waits for ends (a job finishing, or a pid exiting), or when you run `forkcast state NAME running`.",
            options: [Option(flag: "--on X", help: "What it waits for: a job name, or a pid (4242 or 'pid 4242')."), jsonOpt],
            examples: ["forkcast state lane2 waiting --on lane1", "forkcast state lane2 waiting --on 'pid 4242'", "forkcast state lane2 running"]),
    Command(name: "beat", category: "Jobs",
            synopsis: "forkcast beat NAME",
            summary: "Heartbeat: the job is alive (no count). Resets its stale timer.",
            examples: ["while work; do forkcast beat sync; done"]),
    Command(name: "start", category: "Jobs",
            synopsis: "forkcast start NAME [--pid PID] [--json]",
            summary: "Mark a queued job as running, with or without a process of its own.",
            details: """
            For work that has no long-lived process — an AI agent's task whose commands are short-lived shells, a \
            manual step — register it without --pid, then `forkcast start NAME` when work begins. A job with no process is \
            tracked by its progress, heartbeats and log: it can go stale, it has a rate and ETA, and it ends with \
            `forkcast done NAME`, or by itself (done-ok) when its progress reaches the total. Reporting a count with \
            `forkcast progress` also starts it. It has no process cost, so it adds nothing to headroom cost cards. \
            With --pid the job tracks that process tree, as `forkcast register --pid` would. Don't give several jobs the \
            same pid (for example a shared agent CLI): a process tree belongs to one job.
            """,
            options: [Option(flag: "--pid PID", help: "Attach this process as the job's root."), jsonOpt],
            examples: ["forkcast register --name mod3 --group modules --total 9 --after mod2   # queue it",
                       "forkcast start mod3   # when work on it begins; then `forkcast progress mod3 4/9` …",
                       "forkcast start capture --pid 4242"]),
    Command(name: "done", category: "Jobs",
            synopsis: "forkcast done NAME [--code N] [--json]",
            summary: "End a job and record its exit code (0, the default, is done-ok; anything else is done-error).",
            details: "Use it for jobs that `forkcast run` doesn't end for you: ones started with `forkcast start` and no process, or registered processes whose exit code you know. A job that has already ended is left as it is (exit 0).",
            options: [Option(flag: "--code N", help: "Exit code to record (default 0)."), jsonOpt],
            examples: ["forkcast done mod3", "forkcast done mod3 --code 1   # failed"]),
    Command(name: "jobs", category: "Jobs",
            synopsis: "forkcast jobs [--group G] [--json]",
            summary: "Registered jobs: state, progress, rate, ETA, time since last activity, cost and exit code.",
            details: "States: queued, running, waiting (see `forkcast state`), paused, stale (no progress/log/heartbeat for the job's stale limit — default 15 min, or --stale on run/register), done-ok, done-error, killed, ended (JSON state \"exited\": the process ended and its exit code can't be known). A job started without a process (`forkcast start`) shows \"no process attached\" instead of its cost. Names are never truncated; #N marks a re-run. The ETA is shown only while the job is progressing (rate > 0); a job without a total has no ETA — set one with `forkcast progress NAME --total N`.",
            options: [Option(flag: "--group G", help: "Only this group."), jsonOpt],
            examples: ["forkcast jobs", "forkcast jobs --group renders --json"]),
    Command(name: "job", category: "Jobs",
            synopsis: "forkcast job NAME [--json]",
            summary: "One job in detail: ETA basis, command line, log path and earlier runs under the same name.",
            options: [jsonOpt], examples: ["forkcast job batch7"]),
    Command(name: "eta", category: "Jobs",
            synopsis: "forkcast eta [GROUP] [--json]",
            summary: "Combined ETA per job group (when the last job finishes), throughput, and the basis of the estimate.",
            details: "Queued jobs (--after) are included: each starts when its predecessor finishes and runs what is left of its total at the group's average per-job rate (items/h, so give jobs totals in the same unit). A running job without a rate of its own yet uses that average too. When some unfinished jobs have no ETA (no total), the group ETA is a lower bound, shown as \"≥ 7h20m, 3 jobs without ETA\" (JSON: etaIsLowerBound, jobsWithoutETA).",
            options: [jsonOpt], examples: ["forkcast eta", "forkcast eta renders --json"]),
    Command(name: "forget", category: "Jobs",
            synopsis: "forkcast forget NAME",
            summary: "Remove a job from the registry (it does not stop the process).",
            examples: ["forkcast forget batch7"]),

    // MARK: Wait & automate
    Command(name: "wait", category: "Wait & automate",
            synopsis: "forkcast wait 'EXPRESSION' [--timeout 3h] [--json]",
            summary: "Block until a condition is true — use this instead of shell polling loops.",
            details: "See `forkcast help expressions` for the language. Prints which condition fired. Quote the expression.",
            options: [Option(flag: "--timeout DUR", help: "Give up after this long (default 1h, max 7d)."),
                      Option(flag: "--json", help: "Print {met, timedOut, fired, waitedSeconds, status}.")],
            examples: ["forkcast wait 'battery > 25 or not on_ac' --timeout 3h", "forkcast wait 'job batch7 done' && ./next-step.sh",
                       "forkcast wait 'pid 12345 exits'", "forkcast wait 'file /tmp/done.flag exists'"],
            exitCodes: "0 condition met · 124 timed out · 2 bad expression · 3 Forkcast not reachable"),
    Command(name: "check", category: "Wait & automate",
            synopsis: "forkcast check 'EXPRESSION'",
            summary: "Validate an expression without waiting (prints how it was parsed).",
            examples: ["forkcast check 'on_ac and net_battery_w < 0'"],
            exitCodes: "0 valid · 2 invalid"),
    Command(name: "pause", category: "Wait & automate",
            synopsis: "forkcast pause GROUP",
            summary: "Pause every process of a group (SIGSTOP). It stays marked \"paused since …\" until resumed.",
            details: "GROUP can be a registered job group, a job name, or a row label / id from `forkcast ps`.",
            examples: ["forkcast pause renders"]),
    Command(name: "resume", category: "Wait & automate",
            synopsis: "forkcast resume GROUP",
            summary: "Resume a paused group (SIGCONT).",
            examples: ["forkcast resume renders"]),
    Command(name: "guards", category: "Wait & automate",
            synopsis: "forkcast guards [--json]",
            summary: "List guard rules with their state, last firing and any error.",
            options: [jsonOpt], examples: ["forkcast guards"]),
    Command(name: "guard", category: "Wait & automate",
            synopsis: "forkcast guard add --name N --when 'EXPR' [--for 10m] --action pause|resume|notify [--group G] [--resume-when 'EXPR']\nforkcast guard rm NAME",
            summary: "Add or remove an automatic rule: when a condition holds (for a while), pause/resume a group or notify.",
            details: "A pause guard with --resume-when resumes the group when that second condition becomes true. Every guard action is written to the timeline.",
            options: [Option(flag: "--name N", help: "Rule name (adding an existing name replaces it)."), Option(flag: "--when EXPR", help: "Condition (see `forkcast help expressions`)."),
                      Option(flag: "--for DUR", help: "Condition must hold this long first."), Option(flag: "--action A", help: "pause, resume or notify."),
                      Option(flag: "--group G", help: "Target group for pause/resume."), Option(flag: "--resume-when EXPR", help: "Automatically resume when this holds.")],
            examples: ["forkcast guard add --name drain --when 'net_battery_w < 0 and on_ac' --for 10m --action pause --group renders --resume-when 'battery > 30'",
                       "forkcast guard add --name disk --when 'disk_free_gb < 50' --action pause --group renders",
                       "forkcast guard add --name installer --when \"process_running('installer')\" --action pause --group exports",
                       "forkcast guard rm drain"]),

    // MARK: Reference
    Command(name: "metrics", category: "Reference",
            synopsis: "forkcast metrics",
            summary: "List metric names for expressions and for `forkcast history`.",
            examples: ["forkcast metrics"]),
    Command(name: "help", category: "Reference",
            synopsis: "forkcast help [COMMAND | TOPIC] [--json | --man]",
            summary: "This help. Topics: expressions, agents, api, exit-codes, files.",
            options: [Option(flag: "--json", help: "Every command, option and example as JSON (for agents)."),
                      Option(flag: "--man", help: "Print the man page source (roff).")],
            examples: ["forkcast help run", "forkcast help expressions", "forkcast help agents", "forkcast help --json"]),
    Command(name: "version", category: "Reference",
            synopsis: "forkcast version", summary: "Print the version.", examples: ["forkcast --version"]),
]

let historyMetrics = ["battery", "draw_w", "net_battery_w", "charger_w", "cpu_w", "gpu_w", "soc_w", "other_w", "cpu_busy_cores",
                      "p_busy_pct", "e_busy_pct", "thermal", "mem_pressure", "mem_used_gb", "swap_gb", "compressed_gb",
                      "disk_free_gb", "disk_read_mb", "disk_write_mb", "net_down_mb", "net_up_mb", "on_ac"]

let categories = ["Look", "Jobs", "Wait & automate", "Reference"]

func findCommand(_ name: String) -> Command? { commands.first { $0.name == name || $0.aliases.contains(name) } }

// MARK: - Topics

let topics: [String: (title: String, body: String)] = [
    "expressions": ("Condition expressions (wait, check, guards)", """
    An expression is one or more conditions joined with and / or / not and parentheses.

    Comparisons     METRIC OP VALUE      OP is > < >= <= == !=        e.g. battery > 25, disk_free_gb < 50
    Flags           on_ac, charging, throttling  (true when non-zero)     e.g. not on_ac
    Named values    mem_pressure == red (green/yellow/red), thermal >= serious (nominal/fair/serious/critical)
    Jobs            job NAME done | ok | failed | running | stale | paused | started | exists
    Processes       pid PID exits | running        process_running('name')  or  process NAME running
    Groups          group NAME idle | busy | paused | running | done | exists   (idle = under 5% CPU)
    Files           file PATH exists | missing     (~ is expanded)

    Examples
      battery > 25
      on_ac and net_battery_w > 0
      disk_free_gb < 50 or mem_pressure == red
      job batch7 done and not group renders busy
      pid 12345 exits
      file ~/renders/done.flag exists
      process_running('installer')

    Metrics
    \(Expr.metrics.sorted { $0.key < $1.key }.map { "  " + $0.key.padding(toLength: 22, withPad: " ", startingAt: 0) + $0.value }.joined(separator: "\n"))

    pid and file conditions are checked every second; the others update with each sample (every few seconds while \
    something is waiting). `job NAME …` always refers to the latest run of that name; a wait on a job condition is \
    first evaluated 3 s after it starts, so a run registered right after (`forkcast run … &`) is the one it sees. \
    disk_free_gb is free space right now, as df and statvfs report it; disk_free_purgeable_gb adds what macOS says \
    it could purge.
    """),
    "agents": ("Using forkcast from scripts and AI agents", """
    1. Prefer --json. Field names are stable; units are in the names (W, GB, MBs = MB/s, Pct = 0–100, cores).
       Discover everything with `forkcast help --json` (all commands, options, examples, exit codes).
    2. Start long work with `forkcast run --name N --group G [--log F --total T] -- cmd …` so it is tracked by name,
       its exit code is recorded, and progress/ETA work. For something already running: `forkcast register --pid`.
       Work with no process of its own (a subagent's task, whose commands are short-lived shells under a shared agent
       CLI): `forkcast register --name N --group G --total T [--after PREV]`, `forkcast start N`, report progress,
       then `forkcast done N [--code C]` (it also ends by itself when progress reaches the total). Never register
       the shared agent CLI's pid for it: a process tree belongs to one job.
    3. Never write `until …; do sleep; done` or pgrep loops. Use `forkcast wait 'EXPR' --timeout DUR` and branch on the
       exit code: 0 met, 124 timed out, 2 bad expression, 3 Forkcast not reachable.
    4. Ask "how long until everything is done?" with `forkcast eta --json` (per-group ETA and its basis), or read
       .jobGroups from `forkcast status --json`.
    5. Before adding parallel work, check `forkcast headroom --json`: .cards[].estimateMore, .bottleneck, .confidence.
    6. After being away, `forkcast changes --since <last timestamp> --json` lists jobs started/finished/failed/stale,
       crashes and alerts.
    7. Protect the machine with guards, e.g. pause a group when the battery drains on AC:
       forkcast guard add --name drain --when 'net_battery_w < 0 and on_ac' --for 10m --action pause --group G --resume-when 'battery > 30'
    8. Report progress from scripts: `forkcast progress N 412/1721` or `forkcast beat N`; a job with no activity for
       15 min becomes stale and raises an alert. Jobs that legitimately go quiet for long (a queue that only logs
       START/END) should be started with --stale 3h (or --stale never).
    9. Right after Forkcast starts, status JSON has "warmingUp": true until rates can be measured (~1 s).

    The CLI is a thin client of a localhost HTTP API (see `forkcast help api`); call it directly if that is easier.
    If Forkcast isn't running, the CLI starts it.
    """),
    "api": ("HTTP API", """
    Base URL http://127.0.0.1:47215 (loopback only). Port and token: ~/Library/Application Support/Forkcast/api.json.
    GET needs no token. POST/DELETE need the header  Authorization: Bearer <token>.  Requests carrying a browser
    Origin header are refused. Responses are JSON; errors are {"error": "…"} with status 400/401/403/404.

    GET  /status                                   full snapshot (same as `forkcast status --json`)
    GET  /processes?group_by=job|app|tree&limit=N
    GET  /headroom[?group=G]
    GET  /jobs[?group=G]          GET /jobs/NAME
    GET  /groups                  GET /groups/G/eta
    GET  /events?since=1h&types=job,alert&limit=N
    GET  /changes?since=1h
    GET  /wait?until=EXPR&timeout=3h               long-poll; {met, timedOut, fired, waitedSeconds, status}
    GET  /guards                  GET /metrics      GET /history?metric=M&range=24h&step=60s
    POST /jobs/register           {name, group, pid?, log?, logRegex?, total?, after?, command?, cwd?, staleAfter?}
    POST /jobs/NAME/progress      {done?, total?, note?, log?, logRegex?, cwd?, staleAfter?}  or  {progress: "412/1721"}
    POST /jobs/NAME/state         {state: "waiting"|"running", on?}
    POST /jobs/NAME/beat          POST /jobs/NAME/exit {code?, signal?, run?}      POST /jobs/NAME/start {pid?}
    POST /groups/G/pause          POST /groups/G/resume
    POST /guards                  {name, when, forSeconds?, action, group?, resumeWhen?, enabled?}
    DELETE /jobs/NAME             DELETE /guards/NAME

    Example:  curl -s 127.0.0.1:47215/status | jq .power
    """),
    "exit-codes": ("Exit codes", """
    0    success / condition met
    1    error (for example an unknown job or group)
    2    usage error: unknown command or option, missing argument, bad expression
    3    Forkcast is not running and could not be started
    124  `forkcast wait` timed out
    `forkcast run` exits with the command's own exit code (128+N if it was killed by signal N, 127 if it couldn't start).
    """),
    "files": ("Files", """
    /Applications/Forkcast.app                              the app (menu bar + dashboard + API server)
    /Applications/Forkcast.app/Contents/Helpers/forkcast    this command (linked from ~/.local/bin/forkcast)
    ~/Library/Application Support/Forkcast/config.json      alert thresholds, guards, label rules, watched folders/volumes,
                                                            sampling, delivery (webhook / shell command); reloaded on save
    ~/Library/Application Support/Forkcast/api.json         API port and token (mode 600)
    ~/Library/Application Support/Forkcast/history.sqlite   30 days of metrics, timeline events and the job registry
    """),
]

// MARK: - Rendering

func wrap(_ text: String, indent: Int, width: Int = 100) -> String {
    let pad = String(repeating: " ", count: indent)
    var out: [String] = []
    for para in text.components(separatedBy: "\n") {
        var line = ""
        for word in para.split(separator: " ", omittingEmptySubsequences: false) {
            if line.count + word.count + 1 > width - indent, !line.isEmpty { out.append(pad + line); line = "" }
            line += (line.isEmpty ? "" : " ") + word
        }
        out.append(pad + line)
    }
    return out.joined(separator: "\n")
}

func overviewText() -> String {
    var s = """
    forkcast \(version) — command line for Forkcast: power, resources and long-running jobs on this Mac.

    Usage: forkcast COMMAND [OPTIONS]        forkcast COMMAND --help        man forkcast

    """
    for cat in categories {
        s += "\n\(cat):\n"
        for c in commands where c.category == cat {
            s += "  " + c.name.padding(toLength: 11, withPad: " ", startingAt: 0) + c.summary + "\n"
        }
    }
    s += """

    Help topics:  forkcast help expressions | agents | api | exit-codes | files
    For agents:   forkcast help agents   ·   forkcast help --json   ·   add --json to any read command

    Quick start:
      forkcast status                                                  what is the machine doing?
      forkcast run --name r1 --group renders -- ./render.sh            track a long job
      forkcast wait 'job r1 done or battery < 15' --timeout 6h         block until something happens
      forkcast eta                                                     when will everything be done?
    """
    return s
}

func commandText(_ c: Command) -> String {
    var s = "\(c.synopsis)\n\n" + wrap(c.summary, indent: 2) + "\n"
    if !c.details.isEmpty { s += "\n" + wrap(c.details, indent: 2) + "\n" }
    if !c.aliases.isEmpty { s += "\n  Alias: \(c.aliases.joined(separator: ", "))\n" }
    if !c.options.isEmpty {
        s += "\nOptions:\n"
        for o in c.options { s += "  " + o.flag.padding(toLength: 22, withPad: " ", startingAt: 0) + o.help + "\n" }
        s += "  " + "-h, --help".padding(toLength: 22, withPad: " ", startingAt: 0) + "Show this help.\n"
    }
    if !c.examples.isEmpty { s += "\nExamples:\n" + c.examples.map { "  $ " + $0 }.joined(separator: "\n") + "\n" }
    s += "\nExit codes: \(c.exitCodes)\n"
    return s
}

func topicText(_ key: String) -> String? {
    topics[key].map { "\($0.title)\n\n" + $0.body + "\n" }
}

struct HelpJSON: Codable {
    let tool: String
    let version: String
    let description: String
    let commands: [Command]
    let topics: [String: String]
    let exitCodes: [String: String]
    let expressionMetrics: [String: String]
}

func helpJSON() -> String {
    let h = HelpJSON(tool: "forkcast", version: version,
                     description: "CLI for Forkcast.app: monitor power, CPU, memory, disk, network and long-running jobs on macOS; wait on conditions; pause/resume job groups.",
                     commands: commands, topics: topics.mapValues { $0.body },
                     exitCodes: ["0": "success / condition met", "1": "error", "2": "usage error or bad expression",
                                 "3": "Forkcast not reachable", "124": "wait timed out"],
                     expressionMetrics: Expr.metrics)
    return JSON.string(h)
}

// MARK: - Man page (roff), generated from the same table

func roff(_ s: String) -> String {
    var t = s.replacingOccurrences(of: "\\", with: "\\e").replacingOccurrences(of: "-", with: "\\-")
    t = t.split(separator: "\n", omittingEmptySubsequences: false).map { line in
        line.hasPrefix(".") || line.hasPrefix("'") ? "\\&" + line : String(line)
    }.joined(separator: "\n")
    return t
}

func manPage() -> String {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    var m = """
    .TH FORKCAST 1 "\(df.string(from: Date()))" "Forkcast \(version)" "User Commands"
    .SH NAME
    forkcast \\- monitor power, resources and long\\-running jobs on macOS
    .SH SYNOPSIS
    .B forkcast
    .I command
    .RI [ options ]
    .br
    .B forkcast
    .I command
    .B \\-\\-help
    .br
    .B forkcast help
    .RI [ command | topic ]
    .RB [ \\-\\-json ]
    .SH DESCRIPTION
    \(roff("forkcast is the command-line client for Forkcast.app, a low-overhead menu bar monitor. It answers two questions: is the machine safe (power vs the charger, disk, memory, heat), and is my work progressing — and can I add more? Read commands print human-readable text, or stable JSON with --json. Long-running work can be started and tracked as named jobs with progress and ETAs; `forkcast wait` blocks until a condition is true, replacing shell polling loops; guards pause or resume job groups automatically."))
    .PP
    \(roff("forkcast talks to the app over a localhost HTTP API (see API below). If the app is not running, forkcast starts it."))

    """
    for cat in categories {
        m += ".SH \(cat.uppercased()) COMMANDS\n"
        for c in commands where c.category == cat {
            m += ".TP\n.B \(roff(c.synopsis.components(separatedBy: "\n")[0]))\n"
            for extra in c.synopsis.components(separatedBy: "\n").dropFirst() { m += ".br\n.B \(roff(extra))\n" }
            m += roff(c.summary) + "\n"
            if !c.details.isEmpty { m += ".IP\n" + roff(c.details) + "\n" }
            if !c.aliases.isEmpty { m += ".IP\nAlias: \(roff(c.aliases.joined(separator: ", ")))\n" }
            for o in c.options { m += ".RS\n.TP\n.B \(roff(o.flag))\n\(roff(o.help))\n.RE\n" }
            if !c.examples.isEmpty {
                m += ".IP\nExamples:\n.RS\n.nf\n" + c.examples.map { roff("$ " + $0) }.joined(separator: "\n") + "\n.fi\n.RE\n"
            }
            m += ".IP\nExit status: \(roff(c.exitCodes))\n"
        }
    }
    for key in ["expressions", "agents", "api", "exit-codes", "files"] {
        let t = topics[key]!
        let header = ["expressions": "EXPRESSIONS", "agents": "USE FROM SCRIPTS AND AGENTS", "api": "API",
                      "exit-codes": "EXIT STATUS", "files": "FILES"][key]!
        m += ".SH \(header)\n\(roff(t.title)).\n.PP\n.nf\n\(roff(t.body))\n.fi\n"
    }
    m += """
    .SH NOTES
    \(roff("Per-process power is the measured CPU package power (IOReport energy counters, the same source as powermetrics) split by each process's energy counter; power that cannot be pinned on a live, readable process (root daemons, the kernel, processes that start and exit between samples) is reported as \"System, kernel & short-lived processes\". Memory is the physical footprint. No root privileges are needed."))
    .SH SEE ALSO
    .BR powermetrics (1),
    .BR top (1),
    .BR pmset (1)
    .PP
    Dashboard: open Forkcast.app, or run
    .BR "forkcast open" .

    """
    return m
}
