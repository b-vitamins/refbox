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

    let results = store
        .search("scalable", 5, &[])
        .expect("search should work");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].key, "smith2020");
    assert_eq!(results[0].entry_type, "article");

    let resources = store
        .resources_for_entry(entries[0].id, &["crossref".to_string()])
        .expect("resources should query");
    assert_eq!(resources.len(), 1);
    assert_eq!(resources[0].kind, "doi");
    assert_eq!(resources[0].key, "smith2020");
    assert_eq!(resources[0].owner_key, "smith2020");
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

    let results = store.search("shared", 2, &[]).expect("search should work");
    assert_eq!(
        results
            .iter()
            .map(|result| result.key.as_str())
            .collect::<Vec<_>>(),
        vec!["alpha", "beta"]
    );
}

#[test]
fn fts_queries_can_be_scoped_to_source_paths() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let first = parse_bibliography_file(
        "refs/first.bib",
        r#"@article{first,
  title = {Shared Scope Signal}
}"#,
    );
    let second = parse_bibliography_file(
        "refs/second.bib",
        r#"@article{second,
  title = {Shared Scope Signal}
}"#,
    );

    store.insert_file(&first).expect("first file should insert");
    store
        .insert_file(&second)
        .expect("second file should insert");

    let results = store
        .search("shared", 5, &["refs/second.bib".to_string()])
        .expect("search should work");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].key, "second");
    assert_eq!(results[0].file_path, "refs/second.bib");
}

#[test]
fn resource_queries_inherit_crossref_resources() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let file = parse_bibliography_file(
        "refs/crossref.bib",
        r#"@proceedings{parent2020,
  title = {Parent Work},
  file = {parent.pdf},
  doi = {10.1000/parent}
}

@inproceedings{child2020,
  title = {Child Work},
  crossref = {parent2020},
  url = {https://example.test/child}
}"#,
    );

    store.insert_file(&file).expect("file should insert");

    let child = store
        .entries_by_key("child2020")
        .expect("child should query");
    assert_eq!(child.len(), 1);

    let resources = store
        .resources_for_entry(child[0].id, &["crossref".to_string()])
        .expect("resources should query");
    assert!(
        resources
            .iter()
            .any(|resource| resource.kind == "url" && resource.inherited_from_key.is_none())
    );
    let inherited_file = resources
        .iter()
        .find(|resource| resource.kind == "file")
        .expect("parent file should be inherited");
    assert_eq!(inherited_file.key, "child2020");
    assert_eq!(inherited_file.owner_key, "parent2020");
    assert_eq!(
        inherited_file.inherited_from_key.as_deref(),
        Some("parent2020")
    );

    let direct_only = store
        .resources_for_entry(child[0].id, &[])
        .expect("direct resources should query");
    assert!(
        direct_only
            .iter()
            .all(|resource| resource.owner_key == "child2020")
    );

    let keyed_resources = store
        .resources_for_keys(&["child2020".to_string()], 1, &["crossref".to_string()])
        .expect("keyed resources should query");
    assert!(
        keyed_resources
            .iter()
            .any(|resource| resource.owner_key == "parent2020")
    );
}
