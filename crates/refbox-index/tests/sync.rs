use std::collections::BTreeMap;
use std::convert::Infallible;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use refbox_core::{
    BibliographyFile, DerivedBibliographyStore, IndexStoreCounts, IndexedFileMetadata,
    IndexedFileOrigin,
};
use refbox_index::{DiscoveryPolicy, SyncEngine};

#[test]
fn full_sync_indexes_eligible_files_and_prunes_missing_files() {
    let project = TestProject::new("full-sync");
    project.write("refs/a.bib", "@article{a2020, title = {Alpha}}\n");
    project.write("refs/b.bib", "@book{b2020, title = {Beta}}\n");
    project.write(".hidden/hidden.bib", "@article{hidden, title = {Hidden}}\n");
    project.write(
        "target/generated.bib",
        "@article{generated, title = {Generated}}\n",
    );
    project.write("refs/not-bib.txt", "@article{text, title = {Text}}\n");

    let engine = SyncEngine::new(DiscoveryPolicy::new(vec![project.root.clone()], Vec::new()));
    let mut store = MemoryStore::default();

    let status = engine.sync_full(&mut store).expect("full sync should work");
    assert_eq!(status.discovered_file_count, 2);
    assert_eq!(status.changed_file_count, 2);
    assert_eq!(status.indexed_file_count, 2);
    assert_eq!(status.indexed_entry_count, 2);
    assert!(store.path_ending("refs/a.bib").is_some());
    assert!(store.path_ending("refs/b.bib").is_some());
    assert!(store.path_ending(".hidden/hidden.bib").is_none());
    assert!(store.path_ending("target/generated.bib").is_none());
    assert_eq!(store.bulk_begin_count, 1);
    assert_eq!(store.bulk_finish_count, 1);
    assert_eq!(store.bulk_depth, 0);

    fs::remove_file(project.path("refs/b.bib")).expect("test file should remove");
    let status = engine
        .sync_full(&mut store)
        .expect("second full sync should work");
    assert_eq!(status.removed_file_count, 1);
    assert_eq!(status.skipped_file_count, 1);
    assert_eq!(status.indexed_file_count, 1);
    assert!(store.path_ending("refs/a.bib").is_some());
    assert!(store.path_ending("refs/b.bib").is_none());
    assert_eq!(store.bulk_begin_count, 2);
    assert_eq!(store.bulk_finish_count, 2);
    assert_eq!(store.bulk_depth, 0);
}

#[test]
fn single_file_sync_updates_only_that_file() {
    let project = TestProject::new("single-file-sync");
    let a_path = project.write("refs/a.bib", "@article{a2020, title = {Alpha}}\n");
    project.write("refs/b.bib", "@article{b2020, title = {Beta}}\n");

    let engine = SyncEngine::new(DiscoveryPolicy::new(vec![project.root.clone()], Vec::new()));
    let mut store = MemoryStore::default();
    engine.sync_full(&mut store).expect("full sync should work");

    project.write("refs/a.bib", "@article{a2020, title = {Alpha Updated}}\n");
    let status = engine
        .sync_file(&mut store, &a_path)
        .expect("single-file sync should work");

    assert_eq!(status.changed_file_count, 1);
    assert_eq!(status.indexed_file_count, 2);
    assert_eq!(
        store.field_value_for_key("a2020", "title"),
        Some("Alpha Updated")
    );
    assert_eq!(store.field_value_for_key("b2020", "title"), Some("Beta"));
}

#[test]
fn file_removal_drops_only_that_file() {
    let project = TestProject::new("remove-file");
    let a_path = project.write("refs/a.bib", "@article{a2020, title = {Alpha}}\n");
    project.write("refs/b.bib", "@article{b2020, title = {Beta}}\n");

    let engine = SyncEngine::new(DiscoveryPolicy::new(vec![project.root.clone()], Vec::new()));
    let mut store = MemoryStore::default();
    engine.sync_full(&mut store).expect("full sync should work");

    let status = engine
        .remove_file(&mut store, &a_path)
        .expect("remove should work");

    assert_eq!(status.removed_file_count, 1);
    assert_eq!(status.indexed_file_count, 1);
    assert_eq!(store.field_value_for_key("a2020", "title"), None);
    assert_eq!(store.field_value_for_key("b2020", "title"), Some("Beta"));
}

#[test]
fn single_file_sync_respects_discovery_policy() {
    let project = TestProject::new("single-file-policy");
    let visible_path = project.write("refs/a.bib", "@article{a2020, title = {Alpha}}\n");
    let hidden_path = project.write(".hidden/hidden.bib", "@article{hidden, title = {Hidden}}\n");

    let engine = SyncEngine::new(DiscoveryPolicy::new(vec![project.root.clone()], Vec::new()));
    let mut store = MemoryStore::default();

    engine
        .sync_file(&mut store, &visible_path)
        .expect("visible file should sync");
    engine
        .sync_file(&mut store, &hidden_path)
        .expect("hidden file should be rejected through normal removal path");

    assert_eq!(store.field_value_for_key("a2020", "title"), Some("Alpha"));
    assert_eq!(store.field_value_for_key("hidden", "title"), None);
}

#[test]
fn explicit_bibliography_files_are_authoritative_corpus_members() {
    let project = TestProject::new("explicit-files");
    let discovered = project.write("refs/a.bib", "@article{a2020, title = {Alpha}}\n");
    let explicit = project.write(
        "outside/not-a-bib-extension.txt",
        "@book{b2020, title = {Beta}}\n",
    );

    let policy = DiscoveryPolicy::new(vec![project.path("refs")], vec![explicit.clone()]);
    let engine = SyncEngine::new(policy);
    let mut store = MemoryStore::default();

    let status = engine.sync_full(&mut store).expect("full sync should work");
    assert_eq!(status.discovered_file_count, 2);
    assert!(store.path_ending("refs/a.bib").is_some());
    assert!(
        store
            .path_ending("outside/not-a-bib-extension.txt")
            .is_some()
    );
    assert_eq!(store.field_value_for_key("a2020", "title"), Some("Alpha"));
    assert_eq!(store.field_value_for_key("b2020", "title"), Some("Beta"));

    fs::remove_file(explicit).expect("explicit fixture should remove");
    let status = engine
        .sync_full(&mut store)
        .expect("second full sync should work");
    assert_eq!(status.removed_file_count, 1);
    assert_eq!(store.path_ending("outside/not-a-bib-extension.txt"), None);
    assert!(
        store
            .files
            .contains_key(discovered.to_str().expect("path should be UTF-8"))
    );
}

#[test]
fn targeted_sync_accepts_explicit_files_outside_roots() {
    let project = TestProject::new("explicit-file-sync");
    let explicit = project.write("manual/source.bib", "@article{x2020, title = {Exact}}\n");
    let engine = SyncEngine::new(DiscoveryPolicy::new(Vec::new(), vec![explicit.clone()]));
    let mut store = MemoryStore::default();

    let status = engine
        .sync_file(&mut store, &explicit)
        .expect("explicit file sync should work");

    assert_eq!(status.changed_file_count, 1);
    assert_eq!(store.field_value_for_key("x2020", "title"), Some("Exact"));
}

#[test]
fn explicit_file_sync_indexes_local_files_outside_policy() {
    let project = TestProject::new("ad-hoc-file-sync");
    let local = project.write(
        "document/local.bib",
        "@article{local2020, title = {Local}}\n",
    );
    let engine = SyncEngine::new(DiscoveryPolicy::new(Vec::new(), Vec::new()));
    let mut store = MemoryStore::default();

    let status = engine
        .sync_explicit_file(&mut store, &local)
        .expect("explicit file sync should work");
    assert_eq!(status.changed_file_count, 1);
    assert_eq!(
        store.field_value_for_key("local2020", "title"),
        Some("Local")
    );

    fs::remove_file(local).expect("local fixture should remove");
    let status = engine
        .sync_explicit_file(&mut store, project.path("document/local.bib"))
        .expect("explicit file removal should work");
    assert_eq!(status.removed_file_count, 1);
    assert_eq!(store.field_value_for_key("local2020", "title"), None);
}

#[test]
fn managed_sync_rewrites_local_file_origin_even_when_content_is_fresh() {
    let project = TestProject::new("local-origin-upgrade");
    let local = project.write(
        "document/local.bib",
        "@article{local2020, title = {Local}}\n",
    );
    let engine = SyncEngine::new(DiscoveryPolicy::new(Vec::new(), Vec::new()));
    let mut store = MemoryStore::default();

    engine
        .sync_explicit_file(&mut store, &local)
        .expect("explicit file sync should work");
    assert_eq!(
        store
            .metadata
            .get(local.to_string_lossy().as_ref())
            .map(|metadata| metadata.origin),
        Some(IndexedFileOrigin::Local)
    );

    let engine = SyncEngine::new(DiscoveryPolicy::new(Vec::new(), vec![local.clone()]));
    let status = engine
        .sync_file(&mut store, &local)
        .expect("managed file sync should work");
    assert_eq!(status.changed_file_count, 1);
    assert_eq!(
        store
            .metadata
            .get(local.to_string_lossy().as_ref())
            .map(|metadata| metadata.origin),
        Some(IndexedFileOrigin::Configured)
    );
}

#[test]
fn discovery_policy_applies_include_and_exclude_globs() {
    let project = TestProject::new("discovery-policy");
    project.write("refs/keep.bib", "@article{keep, title = {Keep}}\n");
    project.write("refs/skip.bib", "@article{skip, title = {Skip}}\n");
    project.write(
        "other/outside.bib",
        "@article{outside, title = {Outside}}\n",
    );

    let mut policy = DiscoveryPolicy::new(vec![project.root.clone()], Vec::new());
    policy.include_globs.push("refs/*.bib".to_string());
    policy.exclude_globs.push("refs/skip.bib".to_string());

    let files = policy.discover_files().expect("discovery should work");
    assert_eq!(files, vec![project.path("refs/keep.bib")]);
}

#[test]
fn sync_status_reports_counts_and_freshness_metadata() {
    let project = TestProject::new("sync-status");
    project.write(
        "refs/broken.bib",
        "@article{broken,\n  title = {Missing close\n\n@,\n",
    );

    let engine = SyncEngine::new(DiscoveryPolicy::new(vec![project.root.clone()], Vec::new()));
    let mut store = MemoryStore::default();
    let status = engine.sync_full(&mut store).expect("sync should work");

    assert_eq!(status.indexed_file_count, 1);
    assert_eq!(status.indexed_entry_count, 0);
    assert!(status.diagnostic_count > 0);
    assert!(status.latest_modified_ns.is_some());

    let metadata = store
        .metadata
        .values()
        .next()
        .expect("metadata should exist");
    assert!(metadata.size_bytes > 0);
    assert!(metadata.modified_ns.is_some());
    assert!(!metadata.content_hash.is_empty());
    assert_eq!(metadata.entry_count, 0);
    assert!(metadata.diagnostic_count > 0);
}

#[derive(Debug, Default)]
struct MemoryStore {
    files: BTreeMap<String, BibliographyFile>,
    metadata: BTreeMap<String, IndexedFileMetadata>,
    bulk_begin_count: usize,
    bulk_finish_count: usize,
    bulk_depth: usize,
}

impl MemoryStore {
    fn path_ending(&self, suffix: &str) -> Option<&str> {
        self.files
            .keys()
            .find(|path| path.ends_with(suffix))
            .map(String::as_str)
    }

    fn field_value_for_key(&self, key: &str, field_name: &str) -> Option<&str> {
        self.files
            .values()
            .flat_map(|file| &file.entries)
            .find(|entry| entry.id.key == key)
            .and_then(|entry| {
                entry
                    .fields
                    .iter()
                    .find(|field| field.lookup_name == field_name)
            })
            .map(|field| field.value.as_str())
    }
}

impl DerivedBibliographyStore for MemoryStore {
    type Error = Infallible;

    fn begin_bulk_update(&mut self) -> Result<(), Self::Error> {
        self.bulk_begin_count += 1;
        self.bulk_depth += 1;
        Ok(())
    }

    fn finish_bulk_update(&mut self) -> Result<(), Self::Error> {
        self.bulk_finish_count += 1;
        self.bulk_depth = self.bulk_depth.saturating_sub(1);
        Ok(())
    }

    fn indexed_file_metadata(&self) -> Result<Vec<IndexedFileMetadata>, Self::Error> {
        Ok(self.metadata.values().cloned().collect())
    }

    fn upsert_file(
        &mut self,
        file: &BibliographyFile,
        metadata: &IndexedFileMetadata,
    ) -> Result<(), Self::Error> {
        self.files.insert(file.path.clone(), file.clone());
        self.metadata
            .insert(metadata.path.clone(), metadata.clone());
        Ok(())
    }

    fn remove_file(&mut self, path: &str) -> Result<(), Self::Error> {
        self.files.remove(path);
        self.metadata.remove(path);
        Ok(())
    }

    fn index_counts(&self) -> Result<IndexStoreCounts, Self::Error> {
        Ok(IndexStoreCounts {
            file_count: self.files.len(),
            entry_count: self
                .files
                .values()
                .map(|file| file.entries.len())
                .sum::<usize>(),
            diagnostic_count: self
                .files
                .values()
                .map(|file| {
                    file.diagnostics.len()
                        + file
                            .entries
                            .iter()
                            .map(|entry| entry.diagnostics.len())
                            .sum::<usize>()
                })
                .sum(),
        })
    }
}

struct TestProject {
    root: PathBuf,
}

impl TestProject {
    fn new(name: &str) -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("time should be after epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("refbox-{name}-{}-{unique}", std::process::id()));
        fs::create_dir_all(&root).expect("test root should create");
        Self { root }
    }

    fn path(&self, path: &str) -> PathBuf {
        self.root.join(path)
    }

    fn write(&self, path: &str, contents: &str) -> PathBuf {
        let path = self.path(path);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("test parent should create");
        }
        fs::write(&path, contents).expect("test file should write");
        path
    }
}

impl Drop for TestProject {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}
