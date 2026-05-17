use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use refbox_rpc::{
    METHOD_CLOSE_KEYS, METHOD_DIAGNOSTICS, METHOD_DUPLICATE_GROUPS, METHOD_ENTRIES_BY_KEYS,
    METHOD_ENTRY_BY_KEY, METHOD_LIST_ENTRIES, METHOD_RAW_ENTRY, METHOD_RESOURCES_BY_KEY,
    METHOD_SEARCH_ENTRIES, METHOD_SOURCE_LOCATION, METHOD_STATUS, METHOD_SYNC_FILE,
    METHOD_SYNC_FULL,
};
use refbox_store::SCHEMA_VERSION;
use serde_json::{Value, json};

#[test]
fn stdio_rpc_contract_covers_success_and_error_shapes() {
    let project = TestProject::new("rpc-contract");
    project.write("valid.bib", include_str!("fixtures/valid.bib"));
    project.write("resources.bib", include_str!("fixtures/resources.bib"));
    project.write(
        "duplicates-a.bib",
        include_str!("fixtures/duplicates-a.bib"),
    );
    project.write(
        "duplicates-b.bib",
        include_str!("fixtures/duplicates-b.bib"),
    );
    project.write(
        "duplicates-c.bib",
        "@article{zdup2021,\n  title = {Second Duplicate Article},\n  date = {2021}\n}\n",
    );
    project.write(
        "duplicates-d.bib",
        "@book{zdup2021,\n  title = {Second Duplicate Book},\n  date = {2021}\n}\n",
    );
    project.write(
        "close.bib",
        "@article{alphb2020,\n  title = {Close Key}\n}\n",
    );
    project.write("malformed.bib", include_str!("fixtures/malformed.bib"));
    let mut rpc = RpcProcess::spawn(project.root.clone(), project.path("index.sqlite"));

    let sync = rpc.result(1, METHOD_SYNC_FULL, json!({}));
    assert_eq!(sync["discovered_file_count"], 8);
    assert!(sync["indexed_entry_count"].as_u64().expect("entry count") >= 7);
    assert!(sync["diagnostic_count"].as_u64().expect("diagnostics") >= 1);

    let status = rpc.result(2, METHOD_STATUS, json!({}));
    assert_eq!(status["schema_version"], SCHEMA_VERSION);
    assert_eq!(status["counts"]["file_count"], 8);
    assert!(status["counts"]["entry_count"].as_u64().expect("entries") >= 7);

    let scoped_search = rpc.result(
        3,
        METHOD_SEARCH_ENTRIES,
        json!({
            "query": "alpha",
            "limit": 1,
            "source_paths": [project.path("valid.bib")],
        }),
    );
    let entries = scoped_search["entries"].as_array().expect("entries array");
    assert_eq!(entries.len(), 1);
    let alpha_id = entries[0]["id"]
        .as_i64()
        .expect("entry id should be numeric");
    assert_eq!(entries[0]["key"], "alpha2020");
    assert_eq!(entries[0]["source_path"], project.path_string("valid.bib"));
    assert!(entries[0]["fields"].as_array().expect("fields").len() >= 2);

    let listed = rpc.result(
        4,
        METHOD_LIST_ENTRIES,
        json!({
            "limit": 2,
            "offset": 0,
        }),
    );
    let listed_entries = listed["entries"].as_array().expect("listed entries");
    assert_eq!(listed_entries.len(), 2);
    assert!(
        !listed_entries[0]["fields"]
            .as_array()
            .expect("fields")
            .is_empty()
    );

    let entries_by_keys = rpc.result(
        41,
        METHOD_ENTRIES_BY_KEYS,
        json!({
            "keys": ["alpha2020", "res2020"],
            "limit_per_key": 1,
        }),
    );
    let keyed_entries = entries_by_keys["entries"]
        .as_array()
        .expect("entries by keys array");
    assert_eq!(keyed_entries.len(), 2);
    assert!(
        !keyed_entries[0]["fields"]
            .as_array()
            .expect("keyed fields")
            .is_empty()
    );

    let close_keys = rpc.result(
        43,
        METHOD_CLOSE_KEYS,
        json!({
            "key": "alpha2020",
            "max_distance": 1,
            "limit": 10,
        }),
    );
    assert_eq!(close_keys["keys"], json!(["alphb2020"]));

    let xref_entries = rpc.result(
        44,
        METHOD_ENTRIES_BY_KEYS,
        json!({
            "keys": ["xchild2021"],
            "limit_per_key": 1,
            "crossref_fields": ["xref"],
        }),
    );
    let xref_child = &xref_entries["entries"]
        .as_array()
        .expect("xref entries by keys array")[0];
    assert!(
        xref_child["resource_kinds"]
            .as_array()
            .expect("xref child resource kinds")
            .iter()
            .any(|kind| kind == "file")
    );
    assert!(
        xref_child["resources"]
            .as_array()
            .expect("xref child resources")
            .iter()
            .any(|resource| resource["owner_key"] == "xparent2020")
    );

    let resources = rpc.result(5, METHOD_RESOURCES_BY_KEY, json!({ "key": "res2020" }));
    let mut kinds = resources["resources"]
        .as_array()
        .expect("resources array")
        .iter()
        .map(|resource| resource["kind"].as_str().expect("resource kind"))
        .collect::<Vec<_>>();
    kinds.sort_unstable();
    assert_eq!(kinds, vec!["doi", "file", "url"]);

    let duplicates = rpc.result(6, METHOD_DUPLICATE_GROUPS, json!({ "limit": 20 }));
    assert_eq!(
        duplicates["groups"]
            .as_array()
            .expect("duplicate groups")
            .len(),
        2
    );
    assert_eq!(duplicates["groups"][0]["key"], "dup2020");
    assert_eq!(
        duplicates["groups"][0]["entries"]
            .as_array()
            .expect("duplicate entries")
            .len(),
        2
    );

    let limited_duplicates = rpc.result(61, METHOD_DUPLICATE_GROUPS, json!({ "limit": 1 }));
    assert_eq!(
        limited_duplicates["groups"]
            .as_array()
            .expect("limited duplicate groups")
            .len(),
        1
    );

    let diagnostics = rpc.result(7, METHOD_DIAGNOSTICS, json!({ "limit": 20 }));
    assert!(
        diagnostics["diagnostics"]
            .as_array()
            .expect("diagnostics array")
            .iter()
            .any(|diagnostic| diagnostic["file_path"] == project.path_string("malformed.bib"))
    );

    let source = rpc.result(8, METHOD_SOURCE_LOCATION, json!({ "key": "alpha2020" }));
    assert_eq!(source["source_path"], project.path_string("valid.bib"));
    assert_eq!(source["source"]["start"]["line"], 1);

    let raw = rpc.result(
        9,
        METHOD_RAW_ENTRY,
        json!({ "id": alpha_id, "key": "alpha2020" }),
    );
    assert!(
        raw["raw"]
            .as_str()
            .expect("raw entry")
            .contains("@article{alpha2020")
    );

    let duplicate_lookup = rpc.result(11, METHOD_ENTRY_BY_KEY, json!({ "key": "dup2020" }));
    assert_eq!(
        duplicate_lookup["source_path"],
        project.path_string("duplicates-a.bib")
    );
    assert_error_kind(
        rpc.request(12, METHOD_RAW_ENTRY, json!({ "key": "missing" })),
        "unknown_key",
    );
    assert_error_kind(
        rpc.request(13, METHOD_SYNC_FILE, json!({ "path": "../outside.bib" })),
        "invalid_path",
    );
}

fn assert_error_kind(response: Value, expected: &str) {
    assert_eq!(response["jsonrpc"], "2.0");
    assert!(response.get("result").is_none());
    assert_eq!(response["error"]["data"]["kind"], expected);
}

struct RpcProcess {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl RpcProcess {
    fn spawn(root: PathBuf, db: PathBuf) -> Self {
        let mut child = Command::new(env!("CARGO_BIN_EXE_refbox"))
            .arg("serve")
            .arg("--root")
            .arg(root)
            .arg("--db")
            .arg(db)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .expect("daemon should spawn");
        let stdin = child.stdin.take().expect("stdin should be piped");
        let stdout = BufReader::new(child.stdout.take().expect("stdout should be piped"));
        Self {
            child,
            stdin,
            stdout,
        }
    }

    fn request(&mut self, id: i64, method: &str, params: Value) -> Value {
        let request = json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        });
        let body = serde_json::to_vec(&request).expect("request should serialize");
        write!(self.stdin, "Content-Length: {}\r\n\r\n", body.len()).expect("header should write");
        self.stdin.write_all(&body).expect("body should write");
        self.stdin.flush().expect("request should flush");
        self.read_response()
    }

    fn result(&mut self, id: i64, method: &str, params: Value) -> Value {
        let response = self.request(id, method, params);
        assert_eq!(response["jsonrpc"], "2.0");
        assert_eq!(response["id"], id);
        assert!(response.get("error").is_none(), "{response:#}");
        response["result"].clone()
    }

    fn read_response(&mut self) -> Value {
        let mut content_length = None;
        loop {
            let mut line = String::new();
            self.stdout
                .read_line(&mut line)
                .expect("response header should read");
            if line == "\r\n" {
                break;
            }
            let (name, value) = line
                .trim_end_matches(['\r', '\n'])
                .split_once(':')
                .expect("response header should be shaped");
            if name.eq_ignore_ascii_case("content-length") {
                content_length = Some(
                    value
                        .trim()
                        .parse::<usize>()
                        .expect("content length should parse"),
                );
            }
        }
        let length = content_length.expect("content length should be present");
        let mut body = vec![0; length];
        self.stdout
            .read_exact(&mut body)
            .expect("response body should read");
        serde_json::from_slice(&body).expect("response should parse")
    }
}

impl Drop for RpcProcess {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

struct TestProject {
    root: PathBuf,
}

impl TestProject {
    fn new(name: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time should be monotonic")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("refbox-{name}-{}-{unique}", std::process::id()));
        fs::create_dir_all(&root).expect("test root should be created");
        Self { root }
    }

    fn path(&self, path: &str) -> PathBuf {
        self.root.join(path)
    }

    fn path_string(&self, path: &str) -> String {
        self.path(path).display().to_string()
    }

    fn write(&self, path: &str, contents: &str) -> PathBuf {
        let path = self.path(path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("fixture parent should be created");
        }
        fs::write(&path, contents).expect("fixture should be written");
        path
    }
}

impl Drop for TestProject {
    fn drop(&mut self) {
        if Path::new(&self.root).exists() {
            fs::remove_dir_all(&self.root).expect("test root should be removed");
        }
    }
}
