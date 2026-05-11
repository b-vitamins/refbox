//! Bibliography discovery, parsing, and indexing.

use refbox_core::{
    BibliographyEntry, BibliographyField, BibliographyFile, DateParts, Diagnostic,
    DiagnosticSeverity, EntryDate, EntryId, NameList, PersonName, RawEntry, ResourceField,
    SourcePosition, SourceSpan, normalize_lookup_name,
};

pub fn parse_bibliography_file(path: impl Into<String>, input: &str) -> BibliographyFile {
    Parser::new(path.into(), input).parse()
}

struct Parser<'input> {
    path: String,
    input: &'input str,
    byte: usize,
    line: u32,
    column: u32,
}

impl<'input> Parser<'input> {
    fn new(path: String, input: &'input str) -> Self {
        Self {
            path,
            input,
            byte: 0,
            line: 1,
            column: 0,
        }
    }

    fn parse(mut self) -> BibliographyFile {
        let mut file = BibliographyFile::new(self.path.clone());

        while !self.is_eof() {
            if self.peek() == Some('@') {
                self.parse_command(&mut file);
            } else {
                self.bump();
            }
        }

        file
    }

    fn parse_command(&mut self, file: &mut BibliographyFile) {
        let command_start = self.position();
        let command_start_byte = self.byte;
        self.bump();
        self.skip_whitespace();

        let entry_type_start = self.byte;
        while self.peek().is_some_and(is_type_char) {
            self.bump();
        }
        let raw_entry_type = self.input[entry_type_start..self.byte].trim().to_string();

        if raw_entry_type.is_empty() {
            file.diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-type",
                "entry command is missing its type",
                command_start,
            ));
            self.recover_to_next_command(command_start_byte + 1);
            return;
        }

        self.skip_whitespace();
        let Some(open) = self.peek() else {
            file.diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-body",
                "entry command ended before its body",
                command_start,
            ));
            return;
        };
        let Some(close) = matching_close_delimiter(open) else {
            file.diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-body",
                "entry command is missing a braced or parenthesized body",
                command_start,
            ));
            self.recover_to_next_command(command_start_byte + 1);
            return;
        };
        self.bump();

        match normalize_lookup_name(&raw_entry_type).as_str() {
            "comment" | "preamble" | "string" => {
                if !self.skip_enclosed_command(open, close) {
                    file.diagnostics.push(self.file_diagnostic(
                        DiagnosticSeverity::Error,
                        "unclosed-command",
                        "command body was not closed",
                        command_start,
                    ));
                }
            }
            _ => {
                if let Some(entry) = self.parse_entry(
                    command_start,
                    command_start_byte,
                    raw_entry_type,
                    close,
                    &mut file.diagnostics,
                ) {
                    file.entries.push(entry);
                }
            }
        }
    }

    fn parse_entry(
        &mut self,
        command_start: SourcePosition,
        command_start_byte: usize,
        raw_entry_type: String,
        close: char,
        file_diagnostics: &mut Vec<Diagnostic>,
    ) -> Option<BibliographyEntry> {
        self.skip_whitespace();
        let key_start = self.position();
        let key_start_byte = self.byte;

        while let Some(ch) = self.peek() {
            if ch == ',' || ch == close {
                break;
            }
            self.bump();
        }

        let key = self.input[key_start_byte..self.byte].trim().to_string();
        if key.is_empty() {
            file_diagnostics.push(self.file_diagnostic(
                DiagnosticSeverity::Error,
                "missing-entry-key",
                "entry is missing its key",
                key_start,
            ));
            self.recover_to_entry_boundary(close);
            return None;
        }

        let id = EntryId::new(self.path.clone(), key);
        let mut diagnostics = Vec::new();
        let mut fields = Vec::new();

        match self.peek() {
            Some(',') => {
                self.bump();
                fields = self.parse_fields(close, &id, &mut diagnostics);
            }
            Some(ch) if ch == close => {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Warning,
                    "missing-key-field-separator",
                    "entry key is not followed by a comma",
                    &id,
                    self.position(),
                ));
                self.bump();
            }
            None => diagnostics.push(self.entry_diagnostic(
                DiagnosticSeverity::Error,
                "unclosed-entry",
                "entry ended before its closing delimiter",
                &id,
                command_start,
            )),
            _ => {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "missing-key-field-separator",
                    "entry key is not followed by a comma",
                    &id,
                    self.position(),
                ));
                self.recover_to_entry_boundary(close);
            }
        }

        let entry_end = self.position();
        let raw_text = self.input[command_start_byte..self.byte].to_string();
        let names = name_lists_from_fields(&fields);
        let dates = dates_from_fields(&fields);
        let resources = fields
            .iter()
            .filter_map(ResourceField::from_field)
            .collect::<Vec<_>>();

        Some(BibliographyEntry {
            id,
            entry_type: normalize_lookup_name(&raw_entry_type),
            raw: RawEntry {
                text: raw_text,
                source: self.span_between(command_start, entry_end),
            },
            fields,
            names,
            dates,
            resources,
            diagnostics,
        })
    }

    fn parse_fields(
        &mut self,
        close: char,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
    ) -> Vec<BibliographyField> {
        let mut fields = Vec::new();

        loop {
            self.skip_field_padding();

            if self.is_eof() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-entry",
                    "entry ended before its closing delimiter",
                    id,
                    self.position(),
                ));
                break;
            }

            if self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-entry",
                    "entry appears to end before its closing delimiter",
                    id,
                    self.position(),
                ));
                break;
            }

            if self.peek() == Some(close) {
                self.bump();
                break;
            }

            let field_start = self.position();
            let field_name_start = self.byte;
            if !self.peek().is_some_and(is_field_name_start_char) {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "expected-field-name",
                    "expected a field name",
                    id,
                    field_start,
                ));
                self.recover_to_field_boundary(close);
                continue;
            }

            while self.peek().is_some_and(is_field_name_char) {
                self.bump();
            }
            let raw_name = self.input[field_name_start..self.byte].to_string();

            self.skip_whitespace();
            if self.peek() != Some('=') {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "expected-field-equals",
                    "field name is not followed by '='",
                    id,
                    field_start,
                ));
                self.recover_to_field_boundary(close);
                continue;
            }
            self.bump();

            let value_start = self.position();
            let value_start_byte = self.byte;
            let value_finished = self.consume_field_value(close, id, diagnostics);
            let value_end = self.position();
            let value = self.input[value_start_byte..self.byte].trim().to_string();

            if value.is_empty() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Warning,
                    "empty-field-value",
                    "field has an empty value",
                    id,
                    value_start,
                ));
            }

            fields.push(BibliographyField::new(
                raw_name,
                value,
                Some(self.span_between(field_start, value_end)),
            ));

            if !value_finished || self.starts_new_command() {
                if self.starts_new_command() {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "unclosed-entry",
                        "entry appears to end before its closing delimiter",
                        id,
                        self.position(),
                    ));
                }
                break;
            }

            self.skip_whitespace();
            match self.peek() {
                Some(',') => {
                    self.bump();
                }
                Some(ch) if ch == close => {
                    self.bump();
                    break;
                }
                None => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "unclosed-entry",
                        "entry ended before its closing delimiter",
                        id,
                        self.position(),
                    ));
                    break;
                }
                _ => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "expected-field-boundary",
                        "field value is not followed by a comma or entry delimiter",
                        id,
                        self.position(),
                    ));
                    self.recover_to_field_boundary(close);
                }
            }
        }

        fields
    }

    fn consume_field_value(
        &mut self,
        close: char,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
    ) -> bool {
        loop {
            self.skip_whitespace();

            if self.is_eof() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-field-value",
                    "field value ended before a boundary",
                    id,
                    self.position(),
                ));
                return false;
            }

            if self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-field-value",
                    "field value appears to end before a boundary",
                    id,
                    self.position(),
                ));
                return false;
            }

            let ch = self.peek().expect("checked EOF above");
            if ch == ',' || ch == close {
                return true;
            }

            let atom_start = self.position();
            let atom_finished = match ch {
                '{' => self.consume_braced_atom(id, diagnostics, atom_start),
                '"' => self.consume_quoted_atom(id, diagnostics, atom_start),
                '#' => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "expected-value-atom",
                        "concatenation marker is missing a value atom",
                        id,
                        atom_start,
                    ));
                    self.bump();
                    false
                }
                _ => self.consume_bare_atom(close),
            };

            if !atom_finished {
                return false;
            }

            self.skip_whitespace();
            match self.peek() {
                Some('#') => {
                    self.bump();
                }
                Some(ch) if ch == ',' || ch == close => return true,
                None => return false,
                _ => {
                    diagnostics.push(self.entry_diagnostic(
                        DiagnosticSeverity::Error,
                        "expected-value-boundary",
                        "value atom is not followed by '#', a comma, or the entry delimiter",
                        id,
                        self.position(),
                    ));
                    self.recover_to_field_boundary(close);
                    return false;
                }
            }
        }
    }

    fn consume_braced_atom(
        &mut self,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
        atom_start: SourcePosition,
    ) -> bool {
        let mut depth = 0_u32;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if depth > 0 && self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-braced-value",
                    "braced value appears to end before its closing brace",
                    id,
                    atom_start,
                ));
                return false;
            }

            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '{' {
                depth += 1;
            } else if ch == '}' {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return true;
                }
            }
        }

        diagnostics.push(self.entry_diagnostic(
            DiagnosticSeverity::Error,
            "unclosed-braced-value",
            "braced value ended before its closing brace",
            id,
            atom_start,
        ));
        false
    }

    fn consume_quoted_atom(
        &mut self,
        id: &EntryId,
        diagnostics: &mut Vec<Diagnostic>,
        atom_start: SourcePosition,
    ) -> bool {
        self.bump();
        let mut brace_depth = 0_u32;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if self.starts_new_command() {
                diagnostics.push(self.entry_diagnostic(
                    DiagnosticSeverity::Error,
                    "unclosed-quoted-value",
                    "quoted value appears to end before its closing quote",
                    id,
                    atom_start,
                ));
                return false;
            }

            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '{' {
                brace_depth += 1;
            } else if ch == '}' && brace_depth > 0 {
                brace_depth -= 1;
            } else if ch == '"' && brace_depth == 0 {
                return true;
            }
        }

        diagnostics.push(self.entry_diagnostic(
            DiagnosticSeverity::Error,
            "unclosed-quoted-value",
            "quoted value ended before its closing quote",
            id,
            atom_start,
        ));
        false
    }

    fn consume_bare_atom(&mut self, close: char) -> bool {
        let start = self.byte;

        while let Some(ch) = self.peek() {
            if ch.is_whitespace() || ch == ',' || ch == close || ch == '#' {
                break;
            }
            if self.starts_new_command() {
                break;
            }
            self.bump();
        }

        self.byte > start
    }

    fn skip_enclosed_command(&mut self, open: char, close: char) -> bool {
        let mut depth = 1_u32;
        let mut quoted = false;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '"' {
                quoted = !quoted;
                continue;
            }
            if quoted {
                continue;
            }
            if ch == open {
                depth += 1;
            } else if ch == close {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return true;
                }
            }
        }

        false
    }

    fn skip_field_padding(&mut self) {
        loop {
            self.skip_whitespace();
            if self.peek() == Some(',') {
                self.bump();
            } else {
                break;
            }
        }
    }

    fn recover_to_field_boundary(&mut self, close: char) {
        let mut brace_depth = 0_u32;
        let mut quoted = false;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if !quoted
                && brace_depth == 0
                && (ch == ',' || ch == close || self.starts_new_command())
            {
                return;
            }
            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '"' {
                quoted = !quoted;
                continue;
            }
            if quoted {
                continue;
            }
            if ch == '{' {
                brace_depth += 1;
            } else if ch == '}' && brace_depth > 0 {
                brace_depth -= 1;
            }
        }
    }

    fn recover_to_entry_boundary(&mut self, close: char) {
        let mut brace_depth = 0_u32;
        let mut quoted = false;
        let mut escaped = false;

        while let Some(ch) = self.peek() {
            if !quoted && brace_depth == 0 && ch == close {
                self.bump();
                return;
            }
            if !quoted && brace_depth == 0 && self.starts_new_command() {
                return;
            }
            self.bump();

            if escaped {
                escaped = false;
                continue;
            }
            if ch == '\\' {
                escaped = true;
                continue;
            }
            if ch == '"' {
                quoted = !quoted;
                continue;
            }
            if quoted {
                continue;
            }
            if ch == '{' {
                brace_depth += 1;
            } else if ch == '}' && brace_depth > 0 {
                brace_depth -= 1;
            }
        }
    }

    fn recover_to_next_command(&mut self, minimum_byte: usize) {
        while let Some(ch) = self.peek() {
            if ch == '@' && self.byte >= minimum_byte {
                return;
            }
            self.bump();
        }
    }

    fn skip_whitespace(&mut self) {
        while self.peek().is_some_and(char::is_whitespace) {
            self.bump();
        }
    }

    fn starts_new_command(&self) -> bool {
        self.peek() == Some('@') && self.column == 0
    }

    fn file_diagnostic(
        &self,
        severity: DiagnosticSeverity,
        code: impl Into<String>,
        message: impl Into<String>,
        start: SourcePosition,
    ) -> Diagnostic {
        Diagnostic::file(
            severity,
            code,
            message,
            self.path.clone(),
            Some(self.span_between(start, self.position())),
        )
    }

    fn entry_diagnostic(
        &self,
        severity: DiagnosticSeverity,
        code: impl Into<String>,
        message: impl Into<String>,
        id: &EntryId,
        start: SourcePosition,
    ) -> Diagnostic {
        Diagnostic::entry(
            severity,
            code,
            message,
            id.clone(),
            Some(self.span_between(start, self.position())),
        )
    }

    fn span_between(&self, start: SourcePosition, end: SourcePosition) -> SourceSpan {
        SourceSpan::new(self.path.clone(), start, end)
    }

    fn position(&self) -> SourcePosition {
        SourcePosition::new(self.byte as u64, self.line, self.column)
    }

    fn is_eof(&self) -> bool {
        self.byte >= self.input.len()
    }

    fn peek(&self) -> Option<char> {
        self.input[self.byte..].chars().next()
    }

    fn bump(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.byte += ch.len_utf8();
        if ch == '\n' {
            self.line += 1;
            self.column = 0;
        } else {
            self.column += 1;
        }
        Some(ch)
    }
}

fn matching_close_delimiter(open: char) -> Option<char> {
    match open {
        '{' => Some('}'),
        '(' => Some(')'),
        _ => None,
    }
}

fn is_type_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'
}

fn is_field_name_start_char(ch: char) -> bool {
    ch.is_ascii_alphabetic()
}

fn is_field_name_char(ch: char) -> bool {
    ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'
}

fn name_lists_from_fields(fields: &[BibliographyField]) -> Vec<NameList> {
    fields
        .iter()
        .filter(|field| {
            matches!(
                field.lookup_name.as_str(),
                "author" | "editor" | "translator"
            )
        })
        .map(|field| {
            let raw = display_text_from_value(&field.value);
            NameList::new(
                field.raw_name.clone(),
                raw.clone(),
                person_names_from_value(&raw),
                field.source.clone(),
            )
        })
        .collect()
}

fn dates_from_fields(fields: &[BibliographyField]) -> Vec<EntryDate> {
    fields
        .iter()
        .filter(|field| {
            matches!(
                field.lookup_name.as_str(),
                "date" | "year" | "urldate" | "eventdate" | "origdate" | "issued"
            )
        })
        .map(|field| {
            let raw = display_text_from_value(&field.value);
            EntryDate::new(
                field.raw_name.clone(),
                raw.clone(),
                date_parts_from_value(&raw),
                field.source.clone(),
            )
        })
        .collect()
}

fn person_names_from_value(value: &str) -> Vec<PersonName> {
    split_top_level_names(value)
        .into_iter()
        .filter_map(|name| person_name_from_text(name.trim()))
        .collect()
}

fn person_name_from_text(value: &str) -> Option<PersonName> {
    if value.is_empty() {
        return None;
    }

    if let Some((family, rest)) = value.split_once(',') {
        return Some(PersonName {
            given: split_name_words(rest),
            family: split_name_words(family),
            prefix: Vec::new(),
            suffix: Vec::new(),
            literal: None,
        });
    }

    let words = split_name_words(value);
    if words.len() <= 1 {
        return Some(PersonName {
            given: Vec::new(),
            family: words,
            prefix: Vec::new(),
            suffix: Vec::new(),
            literal: None,
        });
    }

    let family = words.last().cloned().into_iter().collect::<Vec<_>>();
    let given = words[..words.len() - 1].to_vec();

    Some(PersonName {
        given,
        family,
        prefix: Vec::new(),
        suffix: Vec::new(),
        literal: None,
    })
}

fn split_name_words(value: &str) -> Vec<String> {
    value
        .split_whitespace()
        .map(str::trim)
        .filter(|word| !word.is_empty())
        .map(strip_wrapping_braces)
        .map(ToOwned::to_owned)
        .collect()
}

fn split_top_level_names(value: &str) -> Vec<&str> {
    let mut names = Vec::new();
    let mut start = 0;
    let mut depth = 0_i32;
    let mut cursor = 0;

    while cursor < value.len() {
        let ch = value[cursor..].chars().next().expect("cursor is in bounds");

        if ch == '{' {
            depth += 1;
        } else if ch == '}' && depth > 0 {
            depth -= 1;
        } else if depth == 0 && value[cursor..].starts_with(" and ") {
            names.push(&value[start..cursor]);
            cursor += " and ".len();
            start = cursor;
            continue;
        }

        cursor += ch.len_utf8();
    }

    names.push(&value[start..]);
    names
}

fn date_parts_from_value(value: &str) -> DateParts {
    let mut parts = value
        .split(['-', '/'])
        .map(str::trim)
        .filter(|part| !part.is_empty());

    DateParts {
        year: parts.next().and_then(|part| part.parse::<i32>().ok()),
        month: parts.next().and_then(|part| part.parse::<u8>().ok()),
        day: parts.next().and_then(|part| part.parse::<u8>().ok()),
    }
}

fn display_text_from_value(value: &str) -> String {
    let trimmed = value.trim();
    let unwrapped =
        if trimmed.starts_with('{') && trimmed.ends_with('}') && outer_braces_wrap(trimmed) {
            &trimmed[1..trimmed.len() - 1]
        } else if trimmed.starts_with('"') && trimmed.ends_with('"') {
            &trimmed[1..trimmed.len() - 1]
        } else {
            trimmed
        };

    unwrapped.trim().to_string()
}

fn strip_wrapping_braces(value: &str) -> &str {
    let trimmed = value.trim();
    if trimmed.starts_with('{') && trimmed.ends_with('}') && outer_braces_wrap(trimmed) {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    }
}

fn outer_braces_wrap(value: &str) -> bool {
    let mut depth = 0_i32;
    let mut escaped = false;

    for (index, ch) in value.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if ch == '\\' {
            escaped = true;
            continue;
        }
        if ch == '{' {
            depth += 1;
        } else if ch == '}' {
            depth -= 1;
            if depth == 0 && index != value.len() - 1 {
                return false;
            }
        }
    }

    depth == 0
}
