use refbox_index::parse_bibliography_file;
use refbox_store::{RefboxStore, SCHEMA_VERSION};

#[test]
fn migrations_are_versioned_from_first_schema() {
    let store = RefboxStore::open_in_memory().expect("store should open");
    assert_eq!(
        store.schema_version().expect("schema version should query"),
        SCHEMA_VERSION
    );
}

#[test]
fn inserts_parsed_files_and_queries_records_back() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let file = parse_bibliography_file(
        "refs/main.bib",
        r#"@article{smith2020,
  author = {Smith, Jane and Doe, John},
  title = {Scalable Reference Indexing},
  journaltitle = {Journal of Fast Tools},
  date = {2020-05-12},
  abstract = {A bounded query store for references.},
  doi = {10.1000/refbox}
}"#,
    );

    store.insert_file(&file).expect("file should insert");

    let entries = store
        .entries_by_key("smith2020")
        .expect("entry should query");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].file_path, "refs/main.bib");
    assert_eq!(entries[0].source.start.line, 1);
    assert_eq!(entries[0].source.start.column, 0);

    let fields = store
        .fields_for_entry(entries[0].id)
        .expect("fields should query");
    let title = fields
        .iter()
        .find(|field| field.lookup_name == "title")
        .expect("title field should be stored");
    assert_eq!(title.value, "{Scalable Reference Indexing}");
    assert_eq!(
        title
            .source
            .as_ref()
            .expect("field source should be stored")
            .start
            .line,
        3
    );

    let results = store.search("scalable", 5).expect("search should work");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].key, "smith2020");
    assert_eq!(results[0].entry_type, "article");
}

#[test]
fn diagnostics_and_source_locations_are_queryable() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let file = parse_bibliography_file(
        "refs/broken.bib",
        r#"@article{broken2020,
  title = {Missing close

@book{afterbroken,
  title = {Recovered After Broken}
}

@,"#,
    );

    store.insert_file(&file).expect("file should insert");

    let diagnostics = store.diagnostics().expect("diagnostics should query");
    assert!(
        diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "missing-entry-type")
    );
    let unclosed = diagnostics
        .iter()
        .find(|diagnostic| diagnostic.code == "unclosed-braced-value")
        .expect("entry diagnostic should be stored");
    assert_eq!(unclosed.target_kind, "entry");
    assert_eq!(
        unclosed
            .source
            .as_ref()
            .expect("diagnostic source should be stored")
            .start
            .line,
        2
    );

    let recovered = store
        .entries_by_key("afterbroken")
        .expect("recovered entry should query");
    assert_eq!(recovered.len(), 1);
    assert_eq!(recovered[0].source.start.line, 4);
}

#[test]
fn duplicate_keys_from_different_files_are_preserved() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let first = parse_bibliography_file(
        "refs/a.bib",
        r#"@article{dup2020,
  title = {First Copy}
}"#,
    );
    let second = parse_bibliography_file(
        "refs/b.bib",
        r#"@book{dup2020,
  title = {Second Copy}
}"#,
    );

    store.insert_file(&first).expect("first file should insert");
    store
        .insert_file(&second)
        .expect("second file should insert");

    let entries = store
        .entries_by_key("dup2020")
        .expect("duplicate entries should query");
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].file_path, "refs/a.bib");
    assert_eq!(entries[1].file_path, "refs/b.bib");

    let duplicate_groups = store
        .duplicate_groups()
        .expect("duplicate groups should query");
    assert_eq!(duplicate_groups.len(), 1);
    assert_eq!(duplicate_groups[0].key, "dup2020");
    assert_eq!(duplicate_groups[0].entries.len(), 2);
}

#[test]
fn fts_queries_are_bounded_and_deterministic_for_ties() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let file = parse_bibliography_file(
        "refs/search.bib",
        r#"@article{beta,
  title = {Shared Ranking Signal}
}

@article{alpha,
  title = {Shared Ranking Signal}
}

@article{gamma,
  title = {Shared Ranking Signal}
}"#,
    );

    store.insert_file(&file).expect("file should insert");

    let results = store.search("shared", 2).expect("search should work");
    assert_eq!(
        results
            .iter()
            .map(|result| result.key.as_str())
            .collect::<Vec<_>>(),
        vec!["alpha", "beta"]
    );
}
