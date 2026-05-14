use refbox_index::parse_bibliography_file;
use refbox_store::{RefboxStore, SCHEMA_VERSION};
use rusqlite::Connection;
use std::fs;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

#[test]
fn migrations_are_versioned_from_first_schema() {
    let db_path = unique_db_path("refbox-migrations");
    {
        let store = RefboxStore::open(&db_path).expect("store should open");
        assert_eq!(
            store.schema_version().expect("schema version should query"),
            SCHEMA_VERSION
        );
    }

    let connection = Connection::open(&db_path).expect("database should open");
    for removed_object in ["source_spans", "fields_lookup_value_idx"] {
        let count: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name = ?1",
                [removed_object],
                |row| row.get(0),
            )
            .expect("schema object check should query");
        assert_eq!(count, 0, "{removed_object} should not exist");
    }
    let fts_sql: String = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE name = 'entry_fts'",
            [],
            |row| row.get(0),
        )
        .expect("FTS schema should query");
    assert!(
        fts_sql.contains("prefix='1 2 3 4'"),
        "entry_fts should keep type-ahead prefix indexes"
    );
    drop(connection);
    let _ = fs::remove_file(db_path);
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
    assert_eq!(entries[0].source.start.column, 1);

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
        .search("scalable", 5, &[], &[], false, true)
        .expect("search should work");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].key, "smith2020");
    assert_eq!(results[0].entry_type, "article");
    let hydrated = store
        .hydrate_search_results(results, &["crossref".to_string()], None, true, true, None)
        .expect("search results should hydrate");
    assert_eq!(hydrated.len(), 1);
    assert!(
        hydrated[0]
            .fields
            .iter()
            .any(|field| field.lookup_name == "title")
    );
    assert_eq!(hydrated[0].resource_kinds, vec!["doi"]);

    let lightweight = store
        .search("scalable", 5, &[], &[], false, true)
        .and_then(|results| {
            store.hydrate_search_results(
                results,
                &["crossref".to_string()],
                None,
                false,
                true,
                None,
            )
        })
        .expect("lightweight search results should hydrate");
    assert_eq!(lightweight[0].resource_kinds, vec!["doi"]);
    assert!(lightweight[0].resources.is_empty());

    let title_only = store
        .search("scalable", 5, &[], &[], false, true)
        .and_then(|results| {
            store.hydrate_search_results(
                results,
                &["crossref".to_string()],
                Some(&["title".to_string()]),
                true,
                true,
                None,
            )
        })
        .expect("filtered search results should hydrate");
    assert_eq!(
        title_only[0]
            .fields
            .iter()
            .map(|field| field.lookup_name.as_str())
            .collect::<Vec<_>>(),
        vec!["title"]
    );
    let capped = store
        .search("scalable", 5, &[], &[], false, true)
        .and_then(|results| {
            store.hydrate_search_results(
                results,
                &["crossref".to_string()],
                Some(&["title".to_string()]),
                true,
                true,
                Some(8),
            )
        })
        .expect("capped search results should hydrate");
    assert_eq!(capped[0].fields[0].value, "{Scalabl");

    let source_free = store
        .search("scalable", 5, &[], &[], false, true)
        .and_then(|results| {
            store.hydrate_search_results(
                results,
                &["crossref".to_string()],
                Some(&["title".to_string()]),
                false,
                false,
                None,
            )
        })
        .expect("source-free search results should hydrate");
    assert_eq!(source_free[0].fields[0].lookup_name, "title");
    assert!(source_free[0].fields[0].source.is_none());

    let resources = store
        .resources_for_entry(entries[0].id, &["crossref".to_string()])
        .expect("resources should query");
    assert_eq!(resources.len(), 1);
    assert_eq!(resources[0].kind, "doi");
    assert_eq!(resources[0].key, "smith2020");
    assert_eq!(resources[0].owner_key, "smith2020");
}

#[test]
fn bulk_updates_commit_or_roll_back_as_a_unit() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let file = parse_bibliography_file("refs/main.bib", "@article{alpha2020, title = {Alpha}}\n");

    store.begin_bulk_update().expect("bulk update should begin");
    store.insert_file(&file).expect("bulk insert should work");
    store
        .cancel_bulk_update()
        .expect("bulk update should roll back");
    assert_eq!(
        store
            .index_counts()
            .expect("counts should query")
            .entry_count,
        0
    );

    store
        .begin_bulk_update()
        .expect("bulk update should begin again");
    store.insert_file(&file).expect("bulk insert should work");
    store
        .finish_bulk_update()
        .expect("bulk update should commit");
    assert_eq!(
        store
            .index_counts()
            .expect("counts should query")
            .entry_count,
        1
    );
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
            .any(|diagnostic| diagnostic.code == "unclosed-entry")
    );
    let unclosed = diagnostics
        .iter()
        .find(|diagnostic| diagnostic.code == "unclosed-braced-value")
        .expect("entry diagnostic should be stored");
    assert_eq!(unclosed.target_kind, "file");
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

    let replacement = parse_bibliography_file(
        "refs/b.bib",
        r#"@book{unique2020,
  title = {Second Copy}
}"#,
    );
    store
        .insert_file(&replacement)
        .expect("replacement file should insert");
    assert!(
        store
            .duplicate_groups()
            .expect("duplicate groups should query")
            .is_empty()
    );
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

    let results = store
        .search("shared", 2, &[], &[], false, true)
        .expect("search should work");
    assert_eq!(
        results
            .iter()
            .map(|result| result.key.as_str())
            .collect::<Vec<_>>(),
        vec!["alpha", "beta"]
    );
}

#[test]
fn unranked_fts_queries_use_fast_index_order_for_typeahead() {
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

    let results = store
        .search("shared", 2, &[], &[], false, false)
        .expect("search should work");
    assert_eq!(
        results
            .iter()
            .map(|result| result.key.as_str())
            .collect::<Vec<_>>(),
        vec!["beta", "alpha"]
    );
}

#[test]
fn fts_queries_prefix_match_title_author_and_punctuation_safe_input() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let file = parse_bibliography_file(
        "refs/prefix.bib",
        r#"@article{austin2021d3pm,
  author = {Austin, Jacob and Johnson, Daniel},
  title = {Structured Denoising Diffusion Models in Discrete State-Spaces},
  doi = {10.1000/refbox}
}"#,
    );

    store.insert_file(&file).expect("file should insert");

    let title = store
        .search("diff", 5, &[], &[], false, true)
        .expect("title prefix search");
    assert_eq!(title[0].key, "austin2021d3pm");

    let author = store
        .search("jac aust", 5, &[], &[], false, true)
        .expect("author prefix search");
    assert_eq!(author[0].key, "austin2021d3pm");

    let punctuation = store
        .search("10.1000/ref", 5, &[], &[], false, true)
        .expect("punctuation search should not expose FTS syntax errors");
    assert_eq!(punctuation[0].key, "austin2021d3pm");
}

#[test]
fn migration_rebuilds_existing_fts_rows_with_prefix_indexes() {
    let db_path = unique_db_path("refbox-fts-migration");
    {
        let mut store = RefboxStore::open(&db_path).expect("store should open");
        let file = parse_bibliography_file(
            "refs/prefix-migration.bib",
            r#"@article{austin2021d3pm,
  author = {Austin, Jacob},
  title = {Structured Denoising Diffusion Models}
}"#,
        );
        store.insert_file(&file).expect("file should insert");
    }

    {
        let connection = Connection::open(&db_path).expect("database should open");
        connection
            .execute_batch(
                r#"
CREATE VIRTUAL TABLE entry_fts_old USING fts5(
    entry_key,
    title,
    names,
    date,
    venue,
    abstract,
    keywords,
    identifiers
);
INSERT INTO entry_fts_old(rowid, entry_key, title, names, date, venue, abstract, keywords, identifiers)
SELECT rowid, entry_key, title, names, date, venue, abstract, keywords, identifiers
FROM entry_fts;
DROP TABLE entry_fts;
ALTER TABLE entry_fts_old RENAME TO entry_fts;
DELETE FROM schema_migrations WHERE version >= 5;
PRAGMA user_version = 4;
"#,
            )
            .expect("database should downgrade FTS shape");
    }

    let store = RefboxStore::open(&db_path).expect("store should migrate");
    let results = store
        .search("diff", 5, &[], &[], false, true)
        .expect("prefix search");
    assert_eq!(results[0].key, "austin2021d3pm");
    drop(store);

    let connection = Connection::open(&db_path).expect("database should open");
    let fts_sql: String = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE name = 'entry_fts'",
            [],
            |row| row.get(0),
        )
        .expect("FTS schema should query");
    assert!(fts_sql.contains("prefix='1 2 3 4'"));
    drop(connection);
    let _ = fs::remove_file(db_path);
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
        .search(
            "shared",
            5,
            &["refs/second.bib".to_string()],
            &[],
            false,
            true,
        )
        .expect("search should work");
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].key, "second");
    assert_eq!(results[0].file_path, "refs/second.bib");
}

#[test]
fn fts_queries_can_be_filtered_to_resource_kinds() {
    let mut store = RefboxStore::open_in_memory().expect("store should open");
    let file = parse_bibliography_file(
        "refs/resources.bib",
        r#"@article{withfile,
  title = {Shared Resource Signal},
  file = {paper.pdf}
}
@article{withdoi,
  title = {Shared Resource Signal},
  doi = {10.1000/resource}
}"#,
    );

    store.insert_file(&file).expect("file should insert");

    let file_results = store
        .search("shared", 5, &[], &["file".to_string()], false, true)
        .expect("filtered search should work");
    assert_eq!(file_results.len(), 1);
    assert_eq!(file_results[0].key, "withfile");

    let doi_results = store
        .search("", 5, &[], &["doi".to_string()], true, true)
        .expect("tag-only search should work");
    assert_eq!(doi_results.len(), 1);
    assert_eq!(doi_results[0].key, "withdoi");

    let empty_results = store
        .search("", 5, &[], &[], false, true)
        .expect("blank search should work");
    assert!(empty_results.is_empty());
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

    let results = store
        .search("child", 5, &[], &[], false, true)
        .expect("child search should work");
    let hydrated = store
        .hydrate_search_results(results, &["crossref".to_string()], None, true, true, None)
        .expect("hydrated search should include resources");
    let child = hydrated
        .iter()
        .find(|entry| entry.key == "child2020")
        .expect("child search result should hydrate");
    assert!(
        child
            .resources
            .iter()
            .any(|resource| resource.kind == "file"
                && resource.owner_key == "parent2020"
                && resource.inherited_from_key.as_deref() == Some("parent2020"))
    );
}

#[test]
fn large_author_lists_do_not_materialize_unused_name_rows() {
    let db_path = unique_db_path("refbox-large-authors");
    let author_count = 512;
    let authors = (0..author_count)
        .map(|index| format!("Family{index}, Given{index}"))
        .collect::<Vec<_>>()
        .join(" and ");
    let input = format!(
        "@article{{atlas2020,\n  author = {{{authors}}},\n  title = {{Large Collaboration Paper}}\n}}"
    );

    {
        let mut store = RefboxStore::open(&db_path).expect("store should open");
        let file = parse_bibliography_file("refs/large-authors.bib", &input);
        store.insert_file(&file).expect("file should insert");
    }

    let connection = Connection::open(&db_path).expect("database should open");
    let stored_names: i64 = connection
        .query_row("SELECT COUNT(*) FROM names", [], |row| row.get(0))
        .expect("name storage should query");
    let source_span_table_count: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE name = 'source_spans'",
            [],
            |row| row.get(0),
        )
        .expect("source span table check should query");

    assert_eq!(stored_names, 0);
    assert_eq!(source_span_table_count, 0);

    drop(connection);
    let _ = fs::remove_file(db_path);
}

#[test]
fn migration_updates_stored_source_columns_to_one_based() {
    let db_path = unique_db_path("refbox-source-column-migration");
    {
        let mut store = RefboxStore::open(&db_path).expect("store should open");
        let file = parse_bibliography_file(
            "refs/source-column.bib",
            r#"@article{alpha,
  title = {Alpha}
}"#,
        );
        store.insert_file(&file).expect("file should insert");
    }

    {
        let connection = Connection::open(&db_path).expect("database should open");
        connection
            .execute_batch(
                r#"
UPDATE entries SET source_start_column = 0, source_end_column = 1;
DELETE FROM schema_migrations WHERE version = 6;
PRAGMA user_version = 5;
"#,
            )
            .expect("database should simulate pre-1-based source columns");
    }

    let store = RefboxStore::open(&db_path).expect("store should migrate");
    let entries = store
        .entries_by_key("alpha")
        .expect("entry should query after migration");
    assert_eq!(entries[0].source.start.column, 1);
    assert_eq!(entries[0].source.end.column, 2);
    drop(store);

    let _ = fs::remove_file(db_path);
}

fn unique_db_path(name: &str) -> PathBuf {
    let unique = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time should be after UNIX_EPOCH")
        .as_nanos();
    std::env::temp_dir().join(format!("{name}-{}-{unique}.sqlite", std::process::id()))
}
