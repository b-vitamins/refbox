use refbox_core::ResourceKind;
use refbox_index::parse_bibliography_file;

#[test]
fn parses_valid_bibtex_and_biblatex_records() {
    let file = parse_bibliography_file("valid.bib", include_str!("fixtures/valid.bib"));

    assert!(file.diagnostics.is_empty());
    assert_eq!(file.entries.len(), 3);

    let article = entry(&file, "smith2020");
    assert_eq!(article.entry_type, "article");
    assert!(article.raw.text.starts_with("@Article{smith2020"));
    assert_eq!(article.raw.source.start.line, 6);
    assert_eq!(article.raw.source.start.column, 1);

    let title = field_value(article, "title");
    assert_eq!(title, "Fast Bibliography Indexing");
    assert_eq!(field_value(article, "month"), "jan");
    assert_eq!(field_value(article, "note"), "Escaped \\{ delimiter \\}");
    assert!(field_value(article, "abstract").contains("second line with {nested} braces"));
    assert!(
        article.fields.iter().any(|field| {
            field.raw_name == "journaltitle" && field.lookup_name == "journaltitle"
        })
    );
    assert_eq!(article.names[0].names.len(), 2);
    assert_eq!(article.dates[0].parts.year, Some(2020));
    assert_eq!(article.dates[0].parts.month, Some(5));
    assert_eq!(article.dates[0].parts.day, Some(12));
    assert!(
        article
            .resources
            .iter()
            .any(|field| field.kind == ResourceKind::Doi)
    );
    assert!(
        article
            .resources
            .iter()
            .any(|field| field.kind == ResourceKind::Url)
    );

    let book = entry(&file, "knuth1984");
    assert_eq!(field_value(book, "title"), "The \\\"TeX\\\" book");
    assert_eq!(book.dates[0].parts.year, Some(1984));
    assert!(
        book.resources
            .iter()
            .any(|field| field.kind == ResourceKind::File)
    );

    let proceedings = entry(&file, "unicode2024");
    assert_eq!(
        field_value(proceedings, "title"),
        "Unicode and Nested Braces"
    );
    assert_eq!(field_value(proceedings, "author"), "Núñez, Ana");
    assert!(
        proceedings
            .resources
            .iter()
            .any(|field| field.kind == ResourceKind::Crossref)
    );
    assert!(
        proceedings
            .resources
            .iter()
            .any(|field| field.kind == ResourceKind::Pmid)
    );
    assert!(
        proceedings
            .resources
            .iter()
            .any(|field| field.kind == ResourceKind::Pmcid)
    );
    assert_eq!(field_value(proceedings, "customfield"), "kept");
}

#[test]
fn expands_string_variables_without_expanding_month_abbreviations() {
    let file = parse_bibliography_file(
        "strings.bib",
        r#"@string{jmlr = {Journal of Machine Learning Research}}
@article{macro2024,
  title = {Protected {Title}},
  journal = jmlr # { X},
  month = jan,
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "macro2024");
    assert!(entry.raw.text.contains("journal = jmlr # { X}"));
    assert_eq!(field_value(entry, "title"), "Protected Title");
    assert_eq!(
        field_value(entry, "journal"),
        "Journal of Machine Learning Research X"
    );
    assert_eq!(field_value(entry, "month"), "jan");
}

#[test]
fn normalizes_protective_braces_in_primary_name_fields() {
    let file = parse_bibliography_file(
        "names.bib",
        r#"@book{names2024,
  author = {{Aaboud}, Morad and {CMS Collaboration}},
  editor = {{Team Refbox}},
  translator = {{Translation Team}},
  note = {{Keep Braces}},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "names2024");
    assert_eq!(
        field_value(entry, "author"),
        "Aaboud, Morad and CMS Collaboration"
    );
    assert_eq!(field_value(entry, "editor"), "Team Refbox");
    assert_eq!(field_value(entry, "translator"), "{Translation Team}");
    assert_eq!(field_value(entry, "note"), "{Keep Braces}");
}

#[test]
fn recovers_following_entries_from_localized_field_errors() {
    let file = parse_bibliography_file("mixed.bib", include_str!("fixtures/mixed.bib"));

    assert!(
        file.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "missing-field-separator")
    );
    assert_eq!(file.entries.len(), 1);

    let recovered = entry(&file, "next2021");
    assert!(recovered.diagnostics.is_empty());
    assert_eq!(field_value(recovered, "title"), "Recovered Entry");
}

#[test]
fn malformed_files_return_diagnostics_without_panics() {
    let file = parse_bibliography_file("malformed.bib", include_str!("fixtures/malformed.bib"));

    assert_eq!(file.entries.len(), 1);
    assert!(
        file.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "unclosed-braced-value")
    );
    assert!(
        file.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "unclosed-entry")
    );

    let recovered = entry(&file, "afterbroken");
    assert_eq!(field_value(recovered, "title"), "Recovered After Broken");
}

fn entry<'file>(
    file: &'file refbox_core::BibliographyFile,
    key: &str,
) -> &'file refbox_core::BibliographyEntry {
    file.entries
        .iter()
        .find(|entry| entry.id.key == key)
        .unwrap_or_else(|| panic!("missing entry {key}"))
}

fn field_value<'entry>(entry: &'entry refbox_core::BibliographyEntry, name: &str) -> &'entry str {
    entry
        .fields
        .iter()
        .find(|field| field.lookup_name == name)
        .map(|field| field.value.as_str())
        .unwrap_or_else(|| panic!("missing field {name} in {}", entry.id.key))
}
