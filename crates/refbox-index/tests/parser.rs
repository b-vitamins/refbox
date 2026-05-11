use refbox_core::{DiagnosticTarget, ResourceKind};
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
    assert_eq!(article.raw.source.start.column, 0);

    let title = field_value(article, "title");
    assert_eq!(title, "{Fast {Bibliography} Indexing}");
    assert_eq!(field_value(article, "month"), "jan");
    assert_eq!(field_value(article, "note"), "{Escaped \\{ delimiter \\}}");
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
    assert_eq!(field_value(book, "title"), "\"The \\\"TeX\\\" book\"");
    assert_eq!(book.dates[0].parts.year, Some(1984));
    assert!(
        book.resources
            .iter()
            .any(|field| field.kind == ResourceKind::File)
    );

    let proceedings = entry(&file, "unicode2024");
    assert_eq!(
        field_value(proceedings, "title"),
        "{Unicode and Nested {Braces}}"
    );
    assert_eq!(field_value(proceedings, "author"), "{Núñez, Ana}");
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
    assert_eq!(field_value(proceedings, "customfield"), "{kept}");
}

#[test]
fn recovers_partial_entries_from_localized_field_errors() {
    let file = parse_bibliography_file("mixed.bib", include_str!("fixtures/mixed.bib"));

    assert!(file.diagnostics.is_empty());
    assert_eq!(file.entries.len(), 2);

    let partial = entry(&file, "partial2020");
    assert!(
        partial
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "expected-field-equals")
    );
    assert!(
        partial
            .fields
            .iter()
            .all(|field| field.lookup_name != "title")
    );
    assert_eq!(field_value(partial, "year"), "{2020}");
    assert_eq!(field_value(partial, "url"), "{https://example.test}");

    let recovered = entry(&file, "next2021");
    assert!(recovered.diagnostics.is_empty());
    assert_eq!(field_value(recovered, "title"), "{Recovered Entry}");
}

#[test]
fn malformed_files_return_diagnostics_without_panics() {
    let file = parse_bibliography_file("malformed.bib", include_str!("fixtures/malformed.bib"));

    assert_eq!(file.entries.len(), 2);
    assert!(
        file.diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "missing-entry-type")
    );

    let broken = entry(&file, "broken2020");
    assert!(
        broken
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "unclosed-braced-value")
    );
    assert!(
        broken
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == "unclosed-entry")
    );
    assert!(matches!(
        &broken.diagnostics[0].target,
        DiagnosticTarget::Entry { id } if id.key == "broken2020"
    ));

    let recovered = entry(&file, "afterbroken");
    assert_eq!(field_value(recovered, "title"), "{Recovered After Broken}");
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
