use std::fs::{self, File};
use std::io::{BufRead, BufReader, BufWriter, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result, bail};
use clap::{Parser, ValueEnum};
use refbox_rpc::{
    METHOD_DIAGNOSTICS, METHOD_RESOURCES_BY_KEY, METHOD_SEARCH_ENTRIES, METHOD_SOURCE_LOCATION,
    METHOD_SYNC_FILE, METHOD_SYNC_FULL,
};
use serde::Serialize;
use serde_json::{Value, json};

const GENERATED_QUERY: &str = "refboxscale";
const GENERATED_KEY: &str = "rb00000000";
const SEARCH_LIMIT: usize = 20;
const CAPF_LIMIT: usize = 50;

#[derive(Debug, Parser)]
#[command(author, version, about = "refbox scale benchmark harness")]
struct Cli {
    /// Benchmark profile to run.
    #[arg(long, value_enum, default_value_t = Profile::Ci)]
    profile: Profile,

    /// Root bibliography tree for the real-corpus profile.
    #[arg(long)]
    root: Option<PathBuf>,

    /// SQLite database path. Defaults to a temporary database.
    #[arg(long)]
    db: Option<PathBuf>,

    /// refbox daemon binary. Defaults to REFBOX_DAEMON or target sibling lookup.
    #[arg(long)]
    daemon: Option<PathBuf>,

    /// Emacs executable used for display rendering measurements.
    #[arg(long, default_value = "emacs")]
    emacs: String,

    /// Repository root used to load refbox.el for Emacs rendering.
    #[arg(long)]
    repo_root: Option<PathBuf>,

    /// Search query for real-corpus validation.
    #[arg(long)]
    query: Option<String>,

    /// Reference key for lookup/resource/source benchmarks.
    #[arg(long)]
    key: Option<String>,

    /// Source path used to disambiguate duplicate real-corpus keys.
    #[arg(long)]
    source_path: Option<String>,

    /// JSON report path.
    #[arg(long)]
    report: Option<PathBuf>,

    /// Keep generated benchmark roots for inspection.
    #[arg(long)]
    keep: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum, Serialize)]
#[serde(rename_all = "kebab-case")]
enum Profile {
    Ci,
    Release,
    Local,
    Real,
}

#[derive(Debug, Clone, Copy)]
struct ProfileSpec {
    name: &'static str,
    generated_entries: Option<usize>,
    generated_files: usize,
    rpc_samples: usize,
    sync_file_samples: usize,
    elisp_samples: usize,
    thresholds: &'static [Threshold],
}

#[derive(Debug, Clone, Copy)]
struct Threshold {
    metric: &'static str,
    p95_ms: f64,
}

#[derive(Debug, Serialize)]
struct BenchReport {
    profile: Profile,
    root: String,
    db: String,
    daemon: String,
    generated: Option<GeneratedReport>,
    workload: WorkloadReport,
    counts: CountReport,
    assertions: Vec<AssertionReport>,
    metrics: Vec<MetricReport>,
}

#[derive(Debug, Serialize)]
struct GeneratedReport {
    requested_entries: usize,
    file_count: usize,
    malformed_fixture: bool,
}

#[derive(Debug, Serialize)]
struct WorkloadReport {
    query: String,
    key: String,
    source_path: Option<String>,
    search_limit: usize,
    capf_limit: usize,
    rpc_samples: usize,
    sync_file_samples: usize,
    elisp_samples: usize,
}

#[derive(Debug, Serialize, Default)]
struct CountReport {
    discovered_file_count: usize,
    indexed_entry_count: usize,
    diagnostic_count: usize,
    search_result_count: usize,
    capf_candidate_count: usize,
    resource_count: usize,
}

#[derive(Debug, Serialize)]
struct AssertionReport {
    name: String,
    observed: usize,
    expected_min: usize,
    passed: bool,
}

#[derive(Debug, Serialize)]
struct MetricReport {
    name: String,
    kind: &'static str,
    unit: &'static str,
    samples: usize,
    min: f64,
    p50: f64,
    p95: f64,
    max: f64,
    threshold_p95: Option<f64>,
    passed: Option<bool>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let spec = profile_spec(cli.profile);
    let repo_root = cli
        .repo_root
        .unwrap_or(std::env::current_dir().context("failed to resolve current directory")?);
    let daemon = cli
        .daemon
        .or_else(daemon_from_env)
        .map_or_else(default_daemon_path, Ok)?;
    let report_path = cli.report.unwrap_or_else(|| {
        PathBuf::from("target")
            .join("refbox-bench")
            .join(format!("{}.json", spec.name))
    });

    let workspace = BenchmarkWorkspace::new(spec.name, cli.keep)?;
    let (root, generated, source_file) = match spec.generated_entries {
        Some(entry_count) => {
            let root = workspace.root().join("corpus");
            let generated = generate_corpus(&root, entry_count, spec.generated_files)?;
            (
                root,
                Some(generated.report),
                Some(generated.first_source_path),
            )
        }
        None => {
            let root = cli.root.or_else(real_root_from_env).with_context(|| {
                "real profile requires --root or REFBOX_BENCH_REAL_ROOT".to_string()
            })?;
            (root, None, None)
        }
    };
    let root = root
        .canonicalize()
        .with_context(|| format!("failed to canonicalize root: {}", root.display()))?;
    let db = cli
        .db
        .unwrap_or_else(|| workspace.root().join("index.sqlite"));
    let query = cli.query.unwrap_or_else(|| {
        real_env("REFBOX_BENCH_REAL_QUERY").unwrap_or_else(|| GENERATED_QUERY.to_string())
    });
    let key = cli.key.unwrap_or_else(|| {
        real_env("REFBOX_BENCH_REAL_KEY").unwrap_or_else(|| GENERATED_KEY.to_string())
    });
    if cli.profile == Profile::Real {
        if query == GENERATED_QUERY {
            bail!("real profile requires --query or REFBOX_BENCH_REAL_QUERY");
        }
        if key == GENERATED_KEY {
            bail!("real profile requires --key or REFBOX_BENCH_REAL_KEY");
        }
    }
    let mut source_path = cli
        .source_path
        .or_else(|| real_env("REFBOX_BENCH_REAL_SOURCE_PATH"));

    let mut rpc = RpcProcess::spawn(&daemon, &root, &db)?;
    let mut metrics = Vec::new();
    let mut assertions = Vec::new();
    let mut counts = CountReport::default();
    let mut id = 1_i64;

    let (sync_result, full_sync_ms) = rpc.timed_result(&mut id, METHOD_SYNC_FULL, json!({}))?;
    counts.discovered_file_count = usize_field(&sync_result, "discovered_file_count")?;
    counts.indexed_entry_count = usize_field(&sync_result, "indexed_entry_count")?;
    counts.diagnostic_count = usize_field(&sync_result, "diagnostic_count")?;
    metrics.push(metric_report(
        "full_sync",
        "daemon_rpc",
        vec![full_sync_ms],
        threshold_for(spec, "full_sync"),
    ));

    if let Some(generated) = &generated {
        assertions.push(assertion_report(
            "generated entries indexed",
            counts.indexed_entry_count,
            generated.requested_entries,
        ));
        assertions.push(assertion_report(
            "generated diagnostics indexed",
            counts.diagnostic_count,
            1,
        ));
    }

    if source_file.is_none() && source_path.is_none() {
        let (source_result, _) =
            rpc.timed_result(&mut id, METHOD_SOURCE_LOCATION, keyed_params(&key, None))?;
        source_path = source_result
            .get("source_path")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
    }
    let sync_path = source_file
        .as_ref()
        .map(|path| path.display().to_string())
        .or_else(|| source_path.clone());
    if let Some(sync_path) = sync_path {
        let mut samples = Vec::new();
        for _ in 0..spec.sync_file_samples {
            let (_, elapsed_ms) =
                rpc.timed_result(&mut id, METHOD_SYNC_FILE, json!({ "path": sync_path }))?;
            samples.push(elapsed_ms);
        }
        metrics.push(metric_report(
            "single_file_sync",
            "daemon_rpc",
            samples,
            threshold_for(spec, "single_file_sync"),
        ));
    }

    let mut search_entries = Vec::new();
    let mut search_samples = Vec::new();
    for _ in 0..spec.rpc_samples {
        let (result, elapsed_ms) = rpc.timed_result(
            &mut id,
            METHOD_SEARCH_ENTRIES,
            json!({ "query": query, "limit": SEARCH_LIMIT }),
        )?;
        search_entries = value_array(&result, "entries")?;
        search_samples.push(elapsed_ms);
    }
    counts.search_result_count = search_entries.len();
    assertions.push(assertion_report(
        "search returns candidates",
        counts.search_result_count,
        1,
    ));
    metrics.push(metric_report(
        "indexed_search",
        "daemon_rpc",
        search_samples,
        threshold_for(spec, "indexed_search"),
    ));

    let mut capf_entries = Vec::new();
    let mut capf_samples = Vec::new();
    for _ in 0..spec.rpc_samples {
        let (result, elapsed_ms) = rpc.timed_result(
            &mut id,
            METHOD_SEARCH_ENTRIES,
            json!({ "query": query, "limit": CAPF_LIMIT }),
        )?;
        capf_entries = value_array(&result, "entries")?;
        capf_samples.push(elapsed_ms);
    }
    counts.capf_candidate_count = capf_entries.len();
    assertions.push(assertion_report(
        "CAPF query returns bounded candidates",
        counts.capf_candidate_count,
        1,
    ));
    metrics.push(metric_report(
        "capf_candidate_retrieval",
        "daemon_rpc",
        capf_samples,
        threshold_for(spec, "capf_candidate_retrieval"),
    ));

    let resources_params = keyed_params(&key, source_path.as_deref());
    let mut resource_samples = Vec::new();
    for _ in 0..spec.rpc_samples {
        let (result, elapsed_ms) =
            rpc.timed_result(&mut id, METHOD_RESOURCES_BY_KEY, resources_params.clone())?;
        counts.resource_count = value_array(&result, "resources")?.len();
        resource_samples.push(elapsed_ms);
    }
    assertions.push(assertion_report(
        "resource lookup is non-empty",
        counts.resource_count,
        1,
    ));
    metrics.push(metric_report(
        "resource_lookup",
        "daemon_rpc",
        resource_samples,
        threshold_for(spec, "resource_lookup"),
    ));

    let mut diagnostics_samples = Vec::new();
    for _ in 0..spec.rpc_samples {
        let (result, elapsed_ms) = rpc.timed_result(
            &mut id,
            METHOD_DIAGNOSTICS,
            json!({ "limit": SEARCH_LIMIT }),
        )?;
        counts.diagnostic_count = value_array(&result, "diagnostics")?.len();
        diagnostics_samples.push(elapsed_ms);
    }
    if generated.is_some() {
        assertions.push(assertion_report(
            "diagnostics query returns fixture diagnostic",
            counts.diagnostic_count,
            1,
        ));
    }
    metrics.push(metric_report(
        "diagnostics_query",
        "daemon_rpc",
        diagnostics_samples,
        threshold_for(spec, "diagnostics_query"),
    ));

    let source_params = keyed_params(&key, source_path.as_deref());
    let mut source_samples = Vec::new();
    for _ in 0..spec.rpc_samples {
        let (_, elapsed_ms) =
            rpc.timed_result(&mut id, METHOD_SOURCE_LOCATION, source_params.clone())?;
        source_samples.push(elapsed_ms);
    }
    metrics.push(metric_report(
        "source_lookup",
        "daemon_rpc",
        source_samples,
        threshold_for(spec, "source_lookup"),
    ));

    let candidate_file = workspace.root().join("candidates.json");
    write_json(
        &candidate_file,
        &json!({ "entries": if capf_entries.is_empty() { search_entries } else { capf_entries } }),
    )?;
    let render_samples =
        run_elisp_render_benchmark(&cli.emacs, &repo_root, &candidate_file, spec.elisp_samples)?;
    metrics.push(metric_report(
        "elisp_candidate_rendering",
        "emacs_batch",
        render_samples,
        threshold_for(spec, "elisp_candidate_rendering"),
    ));

    let report = BenchReport {
        profile: cli.profile,
        root: root.display().to_string(),
        db: db.display().to_string(),
        daemon: daemon.display().to_string(),
        generated,
        workload: WorkloadReport {
            query,
            key,
            source_path,
            search_limit: SEARCH_LIMIT,
            capf_limit: CAPF_LIMIT,
            rpc_samples: spec.rpc_samples,
            sync_file_samples: spec.sync_file_samples,
            elisp_samples: spec.elisp_samples,
        },
        counts,
        assertions,
        metrics,
    };

    write_json(&report_path, &report)?;
    println!("{}", report_path.display());
    fail_if_regressed(&report)
}

fn profile_spec(profile: Profile) -> ProfileSpec {
    match profile {
        Profile::Ci => ProfileSpec {
            name: "ci",
            generated_entries: Some(2_000),
            generated_files: 8,
            rpc_samples: 20,
            sync_file_samples: 3,
            elisp_samples: 20,
            thresholds: &[
                Threshold {
                    metric: "full_sync",
                    p95_ms: 10_000.0,
                },
                Threshold {
                    metric: "single_file_sync",
                    p95_ms: 3_000.0,
                },
                Threshold {
                    metric: "indexed_search",
                    p95_ms: 500.0,
                },
                Threshold {
                    metric: "capf_candidate_retrieval",
                    p95_ms: 500.0,
                },
                Threshold {
                    metric: "resource_lookup",
                    p95_ms: 500.0,
                },
                Threshold {
                    metric: "diagnostics_query",
                    p95_ms: 500.0,
                },
                Threshold {
                    metric: "source_lookup",
                    p95_ms: 500.0,
                },
                Threshold {
                    metric: "elisp_candidate_rendering",
                    p95_ms: 500.0,
                },
            ],
        },
        Profile::Release => ProfileSpec {
            name: "release",
            generated_entries: Some(100_000),
            generated_files: 100,
            rpc_samples: 50,
            sync_file_samples: 5,
            elisp_samples: 50,
            thresholds: &[],
        },
        Profile::Local => ProfileSpec {
            name: "local",
            generated_entries: Some(1_000_000),
            generated_files: 1_000,
            rpc_samples: 50,
            sync_file_samples: 5,
            elisp_samples: 50,
            thresholds: &[],
        },
        Profile::Real => ProfileSpec {
            name: "real",
            generated_entries: None,
            generated_files: 0,
            rpc_samples: 50,
            sync_file_samples: 5,
            elisp_samples: 50,
            thresholds: &[],
        },
    }
}

fn threshold_for(spec: ProfileSpec, metric: &str) -> Option<f64> {
    spec.thresholds
        .iter()
        .find(|threshold| threshold.metric == metric)
        .map(|threshold| threshold.p95_ms)
}

struct BenchmarkWorkspace {
    root: PathBuf,
    keep: bool,
}

impl BenchmarkWorkspace {
    fn new(profile: &str, keep: bool) -> Result<Self> {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("system time is before UNIX_EPOCH")?
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "refbox-bench-{profile}-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir_all(&root)
            .with_context(|| format!("failed to create benchmark root: {}", root.display()))?;
        Ok(Self { root, keep })
    }

    fn root(&self) -> &Path {
        &self.root
    }
}

impl Drop for BenchmarkWorkspace {
    fn drop(&mut self) {
        if !self.keep {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

#[derive(Debug)]
struct GeneratedCorpus {
    report: GeneratedReport,
    first_source_path: PathBuf,
}

fn generate_corpus(root: &Path, entry_count: usize, file_count: usize) -> Result<GeneratedCorpus> {
    let refs = root.join("refs");
    fs::create_dir_all(&refs)
        .with_context(|| format!("failed to create refs directory: {}", refs.display()))?;
    let entries_per_file = entry_count.div_ceil(file_count);
    let mut first_source_path = None;

    for file_index in 0..file_count {
        let start = file_index * entries_per_file;
        let end = ((file_index + 1) * entries_per_file).min(entry_count);
        if start >= end {
            break;
        }
        let path = refs.join(format!("generated-{file_index:04}.bib"));
        if first_source_path.is_none() {
            first_source_path = Some(path.clone());
        }
        let mut writer = BufWriter::new(
            File::create(&path)
                .with_context(|| format!("failed to create generated file: {}", path.display()))?,
        );
        for index in start..end {
            write_generated_entry(&mut writer, index)?;
        }
    }

    let malformed = refs.join("malformed.bib");
    fs::write(
        &malformed,
        "@article{brokenrefboxscale,\n  title = {Broken Scale Entry\n\n@book{afterbrokenrefboxscale,\n  title = {Recovered Scale Entry}\n}\n",
    )
    .with_context(|| format!("failed to write malformed fixture: {}", malformed.display()))?;

    Ok(GeneratedCorpus {
        report: GeneratedReport {
            requested_entries: entry_count,
            file_count,
            malformed_fixture: true,
        },
        first_source_path: first_source_path.context("generated corpus did not create files")?,
    })
}

fn write_generated_entry(writer: &mut impl Write, index: usize) -> Result<()> {
    let key = generated_key(index);
    writeln!(
        writer,
        "@article{{{key},\n  author = {{Author {index:08} and Writer {writer_index:04}}},\n  title = {{refboxscale Deterministic Topic {topic:04} Entry {index:08}}},\n  year = {{{year}}},\n  journal = {{Journal {journal:03}}},\n  keywords = {{refboxscale, generated, benchmark}},\n  doi = {{10.1000/refbox.{index:08}}},\n  url = {{https://example.invalid/refbox/{index:08}}},\n  file = {{:files/{key}.pdf:PDF}}\n}}\n",
        writer_index = index % 997,
        topic = index % 10_000,
        year = 1970 + (index % 60),
        journal = index % 251,
    )
    .context("failed to write generated entry")
}

fn generated_key(index: usize) -> String {
    format!("rb{index:08}")
}

struct RpcProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl RpcProcess {
    fn spawn(daemon: &Path, root: &Path, db: &Path) -> Result<Self> {
        let mut child = Command::new(daemon)
            .arg("serve")
            .arg("--root")
            .arg(root)
            .arg("--db")
            .arg(db)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .with_context(|| format!("failed to spawn daemon: {}", daemon.display()))?;
        let stdin = child.stdin.take().context("daemon stdin was not piped")?;
        let stdout = child.stdout.take().context("daemon stdout was not piped")?;
        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout),
        })
    }

    fn timed_result(&mut self, id: &mut i64, method: &str, params: Value) -> Result<(Value, f64)> {
        let request_id = *id;
        *id += 1;
        let request = json!({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        });
        let body = serde_json::to_vec(&request).context("failed to serialize JSON-RPC request")?;
        let start = Instant::now();
        write!(self.stdin, "Content-Length: {}\r\n\r\n", body.len())
            .context("failed to write request header")?;
        self.stdin
            .write_all(&body)
            .context("failed to write request body")?;
        self.stdin.flush().context("failed to flush request")?;
        let response = self.read_response()?;
        let elapsed_ms = start.elapsed().as_secs_f64() * 1_000.0;
        if let Some(error) = response.get("error") {
            bail!("{method} returned error: {error}");
        }
        Ok((response["result"].clone(), elapsed_ms))
    }

    fn read_response(&mut self) -> Result<Value> {
        let mut content_length = None;
        loop {
            let mut line = String::new();
            let bytes = self
                .stdout
                .read_line(&mut line)
                .context("failed to read response header")?;
            if bytes == 0 {
                bail!("daemon closed stdout before sending a response");
            }
            if line == "\r\n" {
                break;
            }
            let (name, value) = line
                .trim_end_matches(['\r', '\n'])
                .split_once(':')
                .with_context(|| format!("invalid response header: {line:?}"))?;
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(
                    value
                        .trim()
                        .parse::<usize>()
                        .with_context(|| format!("invalid content length: {value}"))?,
                );
            }
        }

        let length = content_length.context("response did not include Content-Length")?;
        let mut body = vec![0; length];
        self.stdout
            .read_exact(&mut body)
            .context("failed to read response body")?;
        serde_json::from_slice(&body).context("failed to parse JSON-RPC response")
    }
}

impl Drop for RpcProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn run_elisp_render_benchmark(
    emacs: &str,
    repo_root: &Path,
    candidate_file: &Path,
    samples: usize,
) -> Result<Vec<f64>> {
    let output = Command::new(emacs)
        .arg("-Q")
        .arg("--batch")
        .arg("-L")
        .arg(repo_root)
        .arg("-l")
        .arg(repo_root.join("bench/render-candidates.el"))
        .arg("--")
        .arg(candidate_file)
        .arg(samples.to_string())
        .current_dir(repo_root)
        .output()
        .with_context(|| format!("failed to run Emacs benchmark with {emacs}"))?;
    if !output.status.success() {
        bail!(
            "Emacs rendering benchmark failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let stdout = String::from_utf8(output.stdout).context("Emacs output was not UTF-8")?;
    let line = stdout
        .lines()
        .rev()
        .find(|line| !line.trim().is_empty())
        .context("Emacs rendering benchmark did not produce JSON")?;
    let value: Value = serde_json::from_str(line).context("failed to parse Emacs JSON output")?;
    value_array(&value, "samples_ms")?
        .into_iter()
        .map(|value| {
            value
                .as_f64()
                .with_context(|| format!("sample is not a number: {value}"))
        })
        .collect()
}

fn metric_report(
    name: &str,
    kind: &'static str,
    samples: Vec<f64>,
    threshold_p95: Option<f64>,
) -> MetricReport {
    let mut sorted = samples;
    sorted.sort_by(f64::total_cmp);
    let min = *sorted.first().unwrap_or(&0.0);
    let max = *sorted.last().unwrap_or(&0.0);
    let p50 = percentile(&sorted, 0.50);
    let p95 = percentile(&sorted, 0.95);
    MetricReport {
        name: name.to_string(),
        kind,
        unit: "ms",
        samples: sorted.len(),
        min,
        p50,
        p95,
        max,
        threshold_p95,
        passed: threshold_p95.map(|threshold| p95 <= threshold),
    }
}

fn percentile(sorted: &[f64], percentile: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = (percentile * sorted.len() as f64).ceil() as usize;
    sorted[rank.saturating_sub(1).min(sorted.len() - 1)]
}

fn assertion_report(name: &str, observed: usize, expected_min: usize) -> AssertionReport {
    AssertionReport {
        name: name.to_string(),
        observed,
        expected_min,
        passed: observed >= expected_min,
    }
}

fn fail_if_regressed(report: &BenchReport) -> Result<()> {
    let failed_assertions = report
        .assertions
        .iter()
        .filter(|assertion| !assertion.passed)
        .map(|assertion| assertion.name.as_str())
        .collect::<Vec<_>>();
    let failed_metrics = report
        .metrics
        .iter()
        .filter(|metric| metric.passed == Some(false))
        .map(|metric| metric.name.as_str())
        .collect::<Vec<_>>();

    if failed_assertions.is_empty() && failed_metrics.is_empty() {
        return Ok(());
    }

    bail!(
        "benchmark gate failed: assertions={:?}, metrics={:?}",
        failed_assertions,
        failed_metrics
    )
}

fn keyed_params(key: &str, source_path: Option<&str>) -> Value {
    let mut params = json!({ "key": key });
    if let Some(source_path) = source_path {
        params["source_path"] = json!(source_path);
    }
    params
}

fn usize_field(value: &Value, field: &str) -> Result<usize> {
    let raw = value
        .get(field)
        .with_context(|| format!("missing field `{field}`"))?;
    let raw = raw
        .as_u64()
        .with_context(|| format!("field `{field}` is not an unsigned integer: {raw}"))?;
    usize::try_from(raw).with_context(|| format!("field `{field}` exceeds usize"))
}

fn value_array(value: &Value, field: &str) -> Result<Vec<Value>> {
    let raw = value
        .get(field)
        .with_context(|| format!("missing array field `{field}`"))?;
    raw.as_array()
        .with_context(|| format!("field `{field}` is not an array"))
        .cloned()
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create report directory: {}", parent.display()))?;
    }
    let json = serde_json::to_string_pretty(value).context("failed to serialize JSON report")?;
    fs::write(path, format!("{json}\n"))
        .with_context(|| format!("failed to write JSON report: {}", path.display()))
}

fn default_daemon_path() -> Result<PathBuf> {
    let exe = std::env::current_exe().context("failed to resolve benchmark executable path")?;
    let dir = exe
        .parent()
        .context("benchmark executable does not have a parent directory")?;
    let candidate = dir.join(if cfg!(windows) {
        "refbox.exe"
    } else {
        "refbox"
    });
    if candidate.is_file() {
        Ok(candidate)
    } else {
        bail!(
            "failed to locate daemon binary; pass --daemon or set REFBOX_DAEMON (tried {})",
            candidate.display()
        )
    }
}

fn daemon_from_env() -> Option<PathBuf> {
    std::env::var_os("REFBOX_DAEMON").map(PathBuf::from)
}

fn real_root_from_env() -> Option<PathBuf> {
    std::env::var_os("REFBOX_BENCH_REAL_ROOT").map(PathBuf::from)
}

fn real_env(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentile_uses_nearest_rank() {
        let samples = vec![1.0, 2.0, 3.0, 4.0, 5.0];
        assert_eq!(percentile(&samples, 0.50), 3.0);
        assert_eq!(percentile(&samples, 0.95), 5.0);
    }

    #[test]
    fn ci_profile_has_thresholds_for_every_gate_metric() {
        let spec = profile_spec(Profile::Ci);
        for metric in [
            "full_sync",
            "single_file_sync",
            "indexed_search",
            "capf_candidate_retrieval",
            "resource_lookup",
            "diagnostics_query",
            "source_lookup",
            "elisp_candidate_rendering",
        ] {
            assert!(threshold_for(spec, metric).is_some(), "missing {metric}");
        }
    }

    #[test]
    fn release_and_local_profiles_cover_required_generated_scale() {
        assert!(
            profile_spec(Profile::Release)
                .generated_entries
                .expect("release profile should generate entries")
                >= 100_000
        );
        assert_eq!(
            profile_spec(Profile::Local)
                .generated_entries
                .expect("local profile should generate entries"),
            1_000_000
        );
    }
}
