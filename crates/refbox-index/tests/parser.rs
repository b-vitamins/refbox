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
    assert_eq!(field_value(book, "title"), "The T\u{0308}eXb\u{0308}ook");
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
fn keeps_shorttitle_braces_like_parsebib() {
    let file = parse_bibliography_file(
        "shorttitle.bib",
        r#"@book{short2024,
  title = {{Full Title}},
  shorttitle = {{Short Title}},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "short2024");
    assert_eq!(field_value(entry, "title"), "Full Title");
    assert_eq!(field_value(entry, "shorttitle"), "{Short Title}");
}

#[test]
fn collapses_field_whitespace_like_parsebib_display_cache() {
    let file = parse_bibliography_file(
        "whitespace.bib",
        r#"@article{space2024,
  title = {A
    Multi   Space Title},
  author = {Doe,
    Jane and Smith,   John},
  note = {{A
    Multi   Space Note}},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "space2024");
    assert_eq!(field_value(entry, "title"), "A Multi Space Title");
    assert_eq!(field_value(entry, "author"), "Doe, Jane and Smith, John");
    assert_eq!(field_value(entry, "note"), "{A Multi Space Note}");
}

#[test]
fn preserves_postprocessing_excluded_field_whitespace_like_parsebib() {
    let file = parse_bibliography_file(
        "resource-whitespace.bib",
        r#"@article{resources2024,
  file = {foo  bar.pdf; baz.pdf},
  url = {https://example.org/a  b},
  doi = {10.1000/abc  def},
  note = {A  B},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "resources2024");
    assert_eq!(field_value(entry, "file"), "foo  bar.pdf; baz.pdf");
    assert_eq!(field_value(entry, "url"), "https://example.org/a  b");
    assert_eq!(field_value(entry, "doi"), "10.1000/abc  def");
    assert_eq!(field_value(entry, "note"), "A B");
}

#[test]
fn leaves_strings_unexpanded_in_postprocessing_excluded_fields() {
    let file = parse_bibliography_file(
        "resource-strings.bib",
        r#"@string{base = {prefix}}
@article{resources2024,
  file = base # { file.pdf},
  url = base # {://example.org},
  doi = base # {10.1000/x},
  note = base # { note},
  title = base # { title},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "resources2024");
    assert_eq!(field_value(entry, "file"), "base file.pdf");
    assert_eq!(field_value(entry, "url"), "base://example.org");
    assert_eq!(field_value(entry, "doi"), "base10.1000/x");
    assert_eq!(field_value(entry, "note"), "prefix note");
    assert_eq!(field_value(entry, "title"), "prefix title");
}

#[test]
fn inherits_crossref_fields_like_parsebib_cache() {
    let file = parse_bibliography_file(
        "crossref.bib",
        r#"@proceedings{conf2024,
  title = {Conference Title},
  year = {2024},
  publisher = {Parent Publisher},
  doi = {10.1000/parent},
}
@inproceedings{paper2024,
  title = {Paper Title},
  author = {Doe, Jane},
  crossref = {conf2024},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let child = entry(&file, "paper2024");
    assert_eq!(field_value(child, "title"), "Paper Title");
    assert_eq!(field_value(child, "author"), "Doe, Jane");
    assert_eq!(field_value(child, "crossref"), "conf2024");
    assert_eq!(field_value(child, "year"), "2024");
    assert_eq!(field_value(child, "publisher"), "Parent Publisher");
    assert_eq!(field_value(child, "doi"), "10.1000/parent");
    assert_eq!(child.dates[0].raw, "2024");
    assert!(
        child
            .resources
            .iter()
            .all(|resource| resource.lookup_name != "doi")
    );
}

#[test]
fn applies_biblatex_crossref_inheritance_rules_like_parsebib() {
    let file = parse_bibliography_file(
        "biblatex-crossref.bib",
        r#"@proceedings{conf2024,
  title = {Conference Title},
  shorttitle = {Conf Short},
  year = {2024},
}
@inproceedings{paper2024,
  title = {Paper Title},
  crossref = {conf2024},
}
@Comment{
Local Variables:
bibtex-dialect: biblatex
End:
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let child = entry(&file, "paper2024");
    assert_eq!(field_value(child, "title"), "Paper Title");
    assert_eq!(field_value(child, "booktitle"), "Conference Title");
    assert_eq!(field_value(child, "year"), "2024");
    assert!(
        child
            .fields
            .iter()
            .all(|field| field.lookup_name != "shorttitle")
    );
}

#[test]
fn cleans_primary_field_tex_markup_like_parsebib() {
    let file = parse_bibliography_file(
        "tex.bib",
        r#"@article{tex2024,
  title = {An {\LaTeX} Study -- Schr{\"o}dinger and {\'E}tude \& \textsc{abc}},
  author = {Garc{\'{\i}}a, Ana and M{\"u}ller, Max},
  editor = {\AA Team},
  note = {Keep {\LaTeX} and Schr{\"o}dinger},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "tex2024");
    assert_eq!(
        field_value(entry, "title"),
        "An \\LaTeX Study \u{2013} Schr\u{00f6}dinger and \u{00c9}tude & ABC"
    );
    assert_eq!(
        field_value(entry, "author"),
        "Garc\u{00ed}a, Ana and M\u{00fc}ller, Max"
    );
    assert_eq!(field_value(entry, "editor"), "\u{00C5}Team");
    assert_eq!(
        field_value(entry, "note"),
        "Keep {\\LaTeX} and Schr{\\\"o}dinger"
    );
}

#[test]
fn normalizes_shorthand_bibtex_author_accents() {
    let file = parse_bibliography_file(
        "names.bib",
        r#"@article{names2024,
  title = {Authors with BibTeX Accents},
  author = {Porr\`a, Josep and Bogu\~n{\'a}, Mari\`a and Adamov\'a, Petra and Tom{\'a}{\v{s}} Koc{\'a}k},
}
"#,
    );

    assert!(file.diagnostics.is_empty());
    let entry = entry(&file, "names2024");
    assert_eq!(
        field_value(entry, "author"),
        "Porr\u{00e0}, Josep and Bogu\u{00f1}\u{00e1}, Mari\u{00e0} and Adamov\u{00e1}, Petra and Tom\u{00e1}\u{0161} Koc\u{00e1}k"
    );
    assert_eq!(entry.names[0].names[0].family, vec!["Porr\u{00e0}"]);
    assert_eq!(entry.names[0].names[1].family, vec!["Bogu\u{00f1}\u{00e1}"]);
    assert_eq!(entry.names[0].names[2].family, vec!["Adamov\u{00e1}"]);
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
