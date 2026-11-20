//! Topaz: a preview of an image that a pane names.
//!
//! Claude Code prints the path of a screenshot or figure (`Read(/tmp/x.png)`,
//! a path in prose, a markdown link) or an http(s) image URL, never the
//! picture. When the mouse rests on such a reference, Topaz draws the image
//! in a framed box beside that line: below it when there is room in the
//! pane, otherwise above it.
//!
//! The preview never writes into the pane's grid. Claude Code is an Ink
//! application that redraws regions of the screen with cursor movement, so
//! image cells or inserted lines would be overwritten or would shift its
//! layout. Instead the preview is a quad drawn by the GUI after the panes,
//! from the same glyph cache and texture atlas that draw iTerm2 and kitty
//! image cells. It is anchored to the stable rows that name the image: it
//! moves with them when the viewport scrolls, and it vanishes as soon as the
//! text of those rows changes (a redraw that rewrites them) or the mouse
//! leaves the reference.
//!
//! Where a path is looked up depends on what runs in the pane. In a local
//! pane it names a file on this machine. In a pane whose foreground job
//! runs ssh (the tabs attached to the iMac's sessions, where a shell loop
//! that reconnects the ssh leads the job) it names a file on the far host,
//! which is read with a second ssh to the same destination and options; a relative path there is resolved against the working directory
//! of the tmux session the pane attaches to, when it attaches to one.
//! Panes running mosh or et, and multiplexer domains, resolve URLs only.
//! A missing file, a file that does not decode, or a failed fetch draws
//! nothing. Files are read, and URLs fetched, on a worker thread; the image
//! is decoded and scaled down there too, so the GUI thread only uploads it.
//!
//! Every reference that would preview carries a mark, a faint dashed
//! underline drawn over the text (never into the grid), and the pointer
//! becomes a hand over it. A path on the far host is marked once its fetch
//! has succeeded, so a remote path is fetched as soon as it is on screen
//! and its preview is ready when the pointer arrives.
//!
//! A path whose file name ends in `.edit.md` names a passage Claude wants
//! Ben to edit. It is found, resolved, fetched and marked exactly as an
//! image path is, but it has no picture to preview: a plain click hands it
//! to Loupe's editor instead of Preview, through a request file that names
//! the local copy and the pane it came from.
//!
//! A file a session sends Ben (Claude Code's SendUserFile) is printed as
//! `[file]<path> (<size>)`. The path after that marker is a reference
//! whatever its name ends in: it is the message that is read, not a list
//! of file types. It is resolved, fetched and marked as the others are; an
//! image among them previews as any image does, and any other file opens
//! on a plain click in the app macOS opens its type with.

use crate::quad::{QuadTrait, TripleLayerQuadAllocator, TripleLayerQuadAllocatorTrait};
use crate::termwindow::render::paint::AllowImage;
use crate::termwindow::TermWindowNotif;
use ::window::bitmaps::atlas::OutOfTextureSpace;
use ::window::WindowOps;
use anyhow::{anyhow, Context};
use mux::domain::LocalDomain;
use mux::pane::{CachePolicy, Pane, PaneId};
use mux::tab::PositionedPane;
use mux::Mux;
use procinfo::LocalProcessInfo;
use std::collections::HashMap;
use std::convert::TryFrom;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};
use termwiz::image::{ImageData, ImageDataType};
use termwiz::surface::SequenceNo;
use wezterm_term::{Line, StableRowIndex};
use window::color::LinearRgba;

/// File name extensions that name an image the existing decoder reads.
/// SVG and PDF are left out: the image decoder behind image cells reads
/// neither, and a second rasterizer is out of scope.
const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "webp"];
/// The ending of the name of a file Claude writes for Ben to edit.
const EDIT_EXTENSION: &str = "edit.md";
/// Every file name ending that makes a path a reference, after its dot,
/// and what kind of reference it makes.
const REFERENCE_EXTENSIONS: &[(&str, ReferenceKind)] = &[
    ("png", ReferenceKind::Image),
    ("jpg", ReferenceKind::Image),
    ("jpeg", ReferenceKind::Image),
    ("gif", ReferenceKind::Image),
    ("webp", ReferenceKind::Image),
    (EDIT_EXTENSION, ReferenceKind::Edit),
];
/// Largest file or download read for a preview.
const MAX_SOURCE_BYTES: usize = 64 * 1024 * 1024;
/// Longest side of the decoded preview; larger images are scaled down on
/// the worker thread so the texture atlas holds a modest bitmap.
const MAX_DECODED_SIDE: u32 = 2048;
/// Number of previews kept; the oldest is dropped to make room.
const MAX_CACHED_IMAGES: usize = 48;
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// How many rows above and below the hovered row a wrapped reference may span.
const WRAPPED_ROWS_EACH_WAY: usize = 3;
/// Width in pixels of the frame drawn around the preview.
const FRAME_PIXELS: f32 = 2.0;
/// Longest a fetch over ssh may take, connection included.
const REMOTE_TIMEOUT: Duration = Duration::from_secs(15);
/// A remote image older than this is fetched again when the pointer comes
/// back to it (there is no modification time to watch), the old picture
/// shown meanwhile.
const REMOTE_REFRESH: Duration = Duration::from_secs(10);
/// A remote path whose fetch failed is tried again after this long, for a
/// file that is written after its name is printed.
const REMOTE_RETRY: Duration = Duration::from_secs(60);
/// The marks of a pane are found again after this long even when its text
/// has not changed, so a local file that appears or vanishes is noticed.
const MARK_RECHECK: Duration = Duration::from_secs(2);
/// Most rows joined into one logical line when looking for a reference
/// that wraps.
const MAX_JOINED_ROWS: usize = 2 * WRAPPED_ROWS_EACH_WAY + 1;
/// Most fetches over ssh running at once; a path found while they run is
/// tried again at the next look.
const MAX_REMOTE_FETCHES: usize = 4;
/// Options a fetch over ssh must not inherit: they take no value and
/// request a terminal, background the connection, open a control master,
/// run no command or a subsystem, or only print something.
const SSH_DROPPED_FLAGS: &str = "fGMNnsTtVv";
/// Options that take a value.
const SSH_FLAGS_WITH_VALUE: &str = "BbcDEeFIiJLlmOoPpQRSWw";
/// Options with a value that a fetch must not inherit: port forwards and
/// control commands.
const SSH_DROPPED_VALUE_FLAGS: &str = "DLORW";

/// What a reference names, and so what a click on it does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ReferenceKind {
    /// An image: previewed on hover, opened in Preview on a click.
    Image,
    /// A passage to edit (`.edit.md`): no preview, opened in Loupe's
    /// editor on a click.
    Edit,
    /// A file a session sent (`[file]<path>`) that is neither of the
    /// above: no preview, opened in its default app on a click.
    Sent,
}

/// True if `s` ends in `.ext` with at least one char before the dot, in
/// any case.
fn has_extension(s: &str, ext: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.len() > ext.len() + 1
        && lower.ends_with(ext)
        && lower.as_bytes()[lower.len() - ext.len() - 1] == b'.'
}

/// True if `s` ends in `.png`, `.jpg`, `.jpeg`, `.gif` or `.webp`, in any case.
pub fn has_image_extension(s: &str) -> bool {
    IMAGE_EXTENSIONS.iter().any(|ext| has_extension(s, ext))
}

/// The kind of reference a path spelling makes by the end of its name,
/// if it makes one: an image, or a file to edit (`.edit.md`, in any case).
pub fn reference_kind(s: &str) -> Option<ReferenceKind> {
    REFERENCE_EXTENSIONS
        .iter()
        .find(|(ext, _)| has_extension(s, ext))
        .map(|&(_, kind)| kind)
}

/// One spelling of a reference: where it starts (a char index into the
/// scanned text) and its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub start: usize,
    pub text: String,
}

/// An image reference found in a run of text. A path with spaces in it
/// ("Screenshot 2026-11-08 at 10.12.33 AM.png") cannot be bounded by the
/// text alone, so a path reference carries every plausible spelling, the
/// longest first; the first that names an existing file wins.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageReference {
    /// Char index one past the last char of the reference.
    pub end: usize,
    pub is_url: bool,
    pub kind: ReferenceKind,
    pub candidates: Vec<Candidate>,
}

fn is_opening_delimiter(c: char) -> bool {
    matches!(
        c,
        '(' | '[' | '{' | '"' | '\'' | '`' | '<' | '=' | '|' | '*'
    )
}

fn is_closing_delimiter(c: char) -> bool {
    matches!(
        c,
        ')' | ']' | '}' | '"' | '\'' | '`' | '>' | ',' | ';' | ':' | '|' | '*'
    )
}

/// The spaces macOS puts in file names: the plain space, and the narrow
/// no-break space before AM or PM in screenshot names.
fn is_name_space(c: char) -> bool {
    c == ' ' || c == '\u{202f}' || c == '\u{a0}'
}

fn url_stop(c: char) -> bool {
    c.is_whitespace()
        || matches!(
            c,
            '"' | '\'' | '`' | '<' | '>' | '(' | ')' | '[' | ']' | '{' | '}' | '|'
        )
}

fn starts_with_at(chars: &[char], idx: usize, prefix: &str) -> bool {
    let mut i = idx;
    for p in prefix.chars() {
        match chars.get(i) {
            Some(c) if c.to_ascii_lowercase() == p => i += 1,
            _ => return false,
        }
    }
    true
}

/// If a reference's extension starts after the dot at `dot`, and is
/// followed by the end of the text, whitespace, a closing delimiter or end
/// punctuation, returns the index one past the extension and the kind of
/// reference it makes.
fn extension_end(chars: &[char], dot: usize) -> Option<(usize, ReferenceKind)> {
    for &(ext, kind) in REFERENCE_EXTENSIONS {
        let start = dot + 1;
        let after = start + ext.len();
        if after > chars.len() {
            continue;
        }
        let matches = chars[start..after]
            .iter()
            .zip(ext.chars())
            .all(|(c, e)| c.to_ascii_lowercase() == e);
        if !matches {
            continue;
        }
        let ends_here = |i: usize| {
            i == chars.len() || chars[i].is_whitespace() || is_closing_delimiter(chars[i])
        };
        if ends_here(after) {
            return Some((after, kind));
        }
        if matches!(chars[after], '.' | '!' | '?') && ends_here(after + 1) {
            return Some((after, kind));
        }
    }
    None
}

/// Strips a `file://` prefix and rejects a spelling truncated with an
/// ellipsis, which no longer names a file.
fn normalize_candidate(mut candidate: Candidate) -> Option<Candidate> {
    if let Some(rest) = candidate.text.strip_prefix("file://") {
        candidate.text = rest.to_string();
        candidate.start += "file://".len();
    }
    if candidate.text.contains('\u{2026}') || candidate.text.starts_with("...") {
        return None;
    }
    reference_kind(&candidate.text)?;
    Some(candidate)
}

/// Finds the image paths, http(s) image URLs and paths of files to edit in
/// `text`, in order of where they end. A file to edit is only ever a path,
/// never a URL.
pub fn find_image_references(text: &str) -> Vec<ImageReference> {
    let chars: Vec<char> = text.chars().collect();
    let mut refs = vec![];
    let mut url_spans = vec![];

    let mut i = 0;
    while i < chars.len() {
        if starts_with_at(&chars, i, "https://") || starts_with_at(&chars, i, "http://") {
            let start = i;
            let mut end = i;
            while end < chars.len() && !url_stop(chars[end]) {
                end += 1;
            }
            while end > start && matches!(chars[end - 1], '.' | ',' | ';' | ':' | '!' | '?') {
                end -= 1;
            }
            url_spans.push(start..end);
            let url: String = chars[start..end].iter().collect();
            let path_part = url.split(|c| c == '?' || c == '#').next().unwrap_or("");
            if has_image_extension(path_part) {
                refs.push(ImageReference {
                    end,
                    is_url: true,
                    kind: ReferenceKind::Image,
                    candidates: vec![Candidate { start, text: url }],
                });
            }
            i = end.max(i + 1);
        } else {
            i += 1;
        }
    }

    for dot in 1..chars.len() {
        if chars[dot] != '.' || url_spans.iter().any(|span| span.contains(&dot)) {
            continue;
        }
        let prev = chars[dot - 1];
        if prev.is_whitespace() || prev == '/' || is_opening_delimiter(prev) {
            continue;
        }
        let (end, kind) = match extension_end(&chars, dot) {
            Some(found) => found,
            None => continue,
        };

        // The spelling without spaces.
        let mut token_start = dot;
        while token_start > 0
            && !chars[token_start - 1].is_whitespace()
            && !is_opening_delimiter(chars[token_start - 1])
        {
            token_start -= 1;
        }

        // Spellings that reach back across single spaces, kept only if
        // they start like an absolute or home path.
        let mut spaced = vec![];
        let mut word_start = token_start;
        for _ in 0..8 {
            if word_start < 2 || !is_name_space(chars[word_start - 1]) {
                break;
            }
            let mut k = word_start - 1;
            while k > 0 && !chars[k - 1].is_whitespace() && !is_opening_delimiter(chars[k - 1]) {
                k -= 1;
            }
            if k == word_start - 1 {
                break;
            }
            let text: String = chars[k..end].iter().collect();
            if text.starts_with('/') || text.starts_with("~/") || text.starts_with("file:///") {
                spaced.push(Candidate { start: k, text });
            }
            word_start = k;
        }
        spaced.reverse();

        let mut candidates = spaced;
        candidates.push(Candidate {
            start: token_start,
            text: chars[token_start..end].iter().collect(),
        });
        let candidates: Vec<Candidate> = candidates
            .into_iter()
            .filter_map(normalize_candidate)
            .collect();
        if !candidates.is_empty() {
            refs.push(ImageReference {
                end,
                is_url: false,
                kind,
                candidates,
            });
        }
    }

    refs.sort_by_key(|r| r.end);
    refs
}

/// The text of one screen row, one entry per char, with the column of the
/// cell that holds each char.
#[derive(Debug, Clone, Default)]
pub struct RowCells {
    pub chars: Vec<char>,
    pub cols: Vec<usize>,
    /// The terminal wrapped this row onto the next one.
    pub wrapped: bool,
}

impl RowCells {
    pub fn from_line(line: &Line) -> Self {
        let mut row = RowCells {
            wrapped: line.last_cell_was_wrapped(),
            ..Default::default()
        };
        for cell in line.visible_cells() {
            for c in cell.str().chars() {
                row.chars.push(c);
                row.cols.push(cell.cell_index());
            }
        }
        row
    }

    #[cfg(test)]
    pub fn from_str(s: &str) -> Self {
        let mut row = RowCells::default();
        for (col, c) in s.chars().enumerate() {
            row.chars.push(c);
            row.cols.push(col);
        }
        row
    }

    /// Text runs to the right edge, so it may continue on the next row:
    /// either the terminal wrapped it, or the application (Ink wraps long
    /// lines itself, with a newline) filled the row.
    fn is_full(&self, width: usize) -> bool {
        self.wrapped
            || self
                .chars
                .iter()
                .zip(&self.cols)
                .rev()
                .find(|(c, _)| !c.is_whitespace())
                .map(|(_, col)| col + 2 >= width)
                .unwrap_or(false)
    }
}

/// Joins the hovered row with the full rows around it, so a path that
/// wraps onto the next row reads as one. Continuation rows lose their
/// leading indentation. Returns the joined chars and, for each, its
/// (row index into `rows`, column).
pub fn join_wrapped_rows(
    rows: &[RowCells],
    hovered: usize,
    width: usize,
) -> (Vec<char>, Vec<(usize, usize)>) {
    let mut first = hovered;
    while first > 0 && hovered - first < WRAPPED_ROWS_EACH_WAY && rows[first - 1].is_full(width) {
        first -= 1;
    }
    let mut last = hovered;
    while last + 1 < rows.len()
        && last - hovered < WRAPPED_ROWS_EACH_WAY
        && rows[last].is_full(width)
    {
        last += 1;
    }
    join_rows(rows, first, last)
}

/// Joins `rows[first..=last]` into one run of text, dropping the trailing
/// spaces of each row but the last and the indentation of each row but
/// the first.
fn join_rows(rows: &[RowCells], first: usize, last: usize) -> (Vec<char>, Vec<(usize, usize)>) {
    let mut chars = vec![];
    let mut positions = vec![];
    for r in first..=last {
        let row = &rows[r];
        let mut end = row.chars.len();
        if r < last {
            while end > 0 && row.chars[end - 1] == ' ' {
                end -= 1;
            }
        }
        let mut start = 0;
        if r > first {
            while start < end && row.chars[start] == ' ' {
                start += 1;
            }
        }
        for k in start..end {
            chars.push(row.chars[k]);
            positions.push((r, row.cols[k]));
        }
    }
    (chars, positions)
}

/// What Claude Code prints before the path of a file a session sent.
const SENT_MARKER: &str = "[file]";
/// Most rows the line of a sent file is read across.
const MAX_SENT_ROWS: usize = 6;

/// One reading of the path on a sent file's line: its chars and, for each,
/// its (row index into the rows read, column).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SentPath {
    pub chars: Vec<char>,
    pub positions: Vec<(usize, usize)>,
}

impl SentPath {
    pub fn text(&self) -> String {
        self.chars.iter().collect()
    }

    /// The reading as a reference with one spelling. Its kind is read from
    /// the end of its name when that makes it an image or a file to edit,
    /// so those behave as they do anywhere; any other name is a sent file.
    pub fn reference(&self) -> ImageReference {
        let text = self.text();
        ImageReference {
            end: self.chars.len(),
            is_url: false,
            kind: reference_kind(&text).unwrap_or(ReferenceKind::Sent),
            candidates: vec![Candidate { start: 0, text }],
        }
    }
}

/// The index in `row` of the marker of a sent file's line: nothing but
/// spaces and symbols before it, and a path (`/` or `~`) right after it,
/// so a sentence that mentions the marker is not one.
fn sent_marker_index(row: &RowCells) -> Option<usize> {
    let marker: Vec<char> = SENT_MARKER.chars().collect();
    let chars = &row.chars;
    if chars.len() <= marker.len() {
        return None;
    }
    for m in 0..chars.len() - marker.len() {
        if chars[m].is_alphanumeric() {
            return None;
        }
        if chars[m..m + marker.len()] == marker[..] {
            return match chars[m + marker.len()] {
                '/' | '~' => Some(m),
                _ => None,
            };
        }
    }
    None
}

/// True if `tail`, the chars after an opening parenthesis, reads as a size
/// or the start of one cut by a wrap: `775 bytes)`, `306.3 KB)`, `775`.
fn is_size_start(tail: &[char]) -> bool {
    if !tail.first().map(|c| c.is_ascii_digit()).unwrap_or(false) {
        return false;
    }
    let mut i = 0;
    while i < tail.len() && (tail[i].is_ascii_digit() || tail[i] == '.' || tail[i] == ',') {
        i += 1;
    }
    if i < tail.len() && tail[i] == ' ' {
        i += 1;
    }
    while i < tail.len() && tail[i].is_ascii_alphabetic() {
        i += 1;
    }
    if i < tail.len() && tail[i] == ')' {
        i += 1;
    }
    i == tail.len()
}

/// Finds the files a session sent, each printed by Claude Code as
/// `[file]<path> (<size>)`. The path and the size are two columns: in a
/// pane too narrow for the line the path wraps inside its own column, cut
/// anywhere, and the size inside its own to the right of it,
///
/// ```text
///   › [file]/tmp/claude-1000/scratchpa (775
///           d/sent.html                bytes)
/// ```
///
/// so joining the rows as text would read the size into the path. The size
/// column starts at the last ` (` of the first row that opens a size; the
/// path is what lies between the marker and that column, on the first row
/// and on each row below it while the path fills its column.
///
/// Whether a path that ends at the edge of its column goes on below cannot
/// be told from the text, so each line gives every reading, the longest
/// first; the first that names a file is the path.
pub fn find_sent_files(rows: &[RowCells]) -> Vec<Vec<SentPath>> {
    let mut found = vec![];
    for r in 0..rows.len() {
        let row = &rows[r];
        let start = match sent_marker_index(row) {
            Some(m) => m + SENT_MARKER.chars().count(),
            None => continue,
        };
        let mut end = row.chars.len();
        while end > start && row.chars[end - 1].is_whitespace() {
            end -= 1;
        }
        let path_col = row.cols[start];

        // The space before the size, if the row has one.
        let mut split = None;
        let mut i = end;
        while i > start + 2 {
            i -= 1;
            if row.chars[i] == '(' && row.chars[i - 1] == ' ' && is_size_start(&row.chars[i + 1..end]) {
                split = Some(i - 1);
                break;
            }
        }
        let (mut path_end, size_col, mut size_closed) = match split {
            Some(space) => (space, Some(row.cols[space]), row.chars[end - 1] == ')'),
            None => (end, None, true),
        };
        while path_end > start && row.chars[path_end - 1].is_whitespace() {
            path_end -= 1;
        }
        if path_end == start {
            continue;
        }
        let mut path = SentPath {
            chars: row.chars[start..path_end].to_vec(),
            positions: (start..path_end).map(|k| (r, row.cols[k])).collect(),
        };
        let mut readings = vec![path.clone()];

        if let Some(size_col) = size_col {
            // A wide char may leave the last cell of the column empty.
            let fills = |path: &SentPath| {
                path.positions
                    .last()
                    .map(|&(_, col)| col + 2 >= size_col)
                    .unwrap_or(false)
            };
            let mut path_open = fills(&path);
            let mut k = r + 1;
            while k < rows.len() && k - r < MAX_SENT_ROWS && (path_open || !size_closed) {
                let next = &rows[k];
                if sent_marker_index(next).is_some() {
                    break;
                }
                let mut margin_blank = true;
                let mut piece: Vec<(char, usize)> = vec![];
                let mut size_piece = String::new();
                for (&c, &col) in next.chars.iter().zip(&next.cols) {
                    if col < path_col {
                        margin_blank = margin_blank && c.is_whitespace();
                    } else if col < size_col {
                        piece.push((c, col));
                    } else {
                        size_piece.push(c);
                    }
                }
                if !margin_blank {
                    break;
                }
                while piece.last().map(|(c, _)| c.is_whitespace()).unwrap_or(false) {
                    piece.pop();
                }
                let mut took = false;
                if !piece.is_empty() {
                    // A wrapped path goes on in the first cell of its column.
                    let continues = path_open && piece[0].1 == path_col && !piece[0].0.is_whitespace();
                    if !continues {
                        break;
                    }
                    for &(c, col) in &piece {
                        path.chars.push(c);
                        path.positions.push((k, col));
                    }
                    path_open = fills(&path);
                    readings.push(path.clone());
                    took = true;
                } else {
                    path_open = false;
                }
                let size_piece = size_piece.trim();
                if !size_closed && !size_piece.is_empty() {
                    size_closed = size_piece.ends_with(')');
                    took = true;
                }
                if !took {
                    break;
                }
                k += 1;
            }
        }
        readings.reverse();
        found.push(readings);
    }
    found
}

/// One row's share of a marked reference: columns `start_col..end_col` of
/// `row` (an index into the rows given to `reference_marks`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkSpan {
    pub row: usize,
    pub start_col: usize,
    pub end_col: usize,
}

fn push_spans(
    spans: &mut Vec<MarkSpan>,
    positions: &[(usize, usize)],
    start: usize,
    end: usize,
) {
    for &(row, col) in &positions[start..end] {
        match spans.last_mut() {
            Some(span) if span.row == row && span.end_col == col => span.end_col = col + 1,
            _ => spans.push(MarkSpan {
                row,
                start_col: col,
                end_col: col + 1,
            }),
        }
    }
}

/// The spans to mark on screen. Each row is read alone first, as the hover
/// does, so a path that starts a row is not glued to the word that ends
/// the row above; then each run of full rows is read joined, keeping only
/// the references that cross rows; then the lines of sent files, each by
/// its longest reading that would open. `pick` says which spelling of a
/// reference would preview, if any, by its index in `candidates`.
pub fn reference_marks(
    rows: &[RowCells],
    width: usize,
    mut pick: impl FnMut(&ImageReference) -> Option<usize>,
) -> Vec<MarkSpan> {
    let mut spans = vec![];
    for r in 0..rows.len() {
        let (chars, positions) = join_rows(rows, r, r);
        let text: String = chars.iter().collect();
        for reference in find_image_references(&text) {
            if let Some(i) = pick(&reference) {
                push_spans(&mut spans, &positions, reference.candidates[i].start, reference.end);
            }
        }
    }
    let mut first = 0;
    while first < rows.len() {
        let mut last = first;
        while last + 1 < rows.len() && last - first + 1 < MAX_JOINED_ROWS && rows[last].is_full(width)
        {
            last += 1;
        }
        if last > first {
            let (chars, positions) = join_rows(rows, first, last);
            let text: String = chars.iter().collect();
            for reference in find_image_references(&text) {
                let crosses = |start: usize| positions[start].0 != positions[reference.end - 1].0;
                if !reference.candidates.iter().any(|c| crosses(c.start)) {
                    continue;
                }
                if let Some(i) = pick(&reference) {
                    let start = reference.candidates[i].start;
                    if crosses(start) {
                        push_spans(&mut spans, &positions, start, reference.end);
                    }
                }
            }
        }
        first = last + 1;
    }
    for readings in find_sent_files(rows) {
        for path in readings {
            if pick(&path.reference()).is_some() {
                push_spans(&mut spans, &path.positions, 0, path.chars.len());
                break;
            }
        }
    }
    // A cell found twice (alone and joined) is drawn once, since the marks
    // are translucent.
    spans.sort_by_key(|span| (span.row, span.start_col));
    let mut merged: Vec<MarkSpan> = vec![];
    for span in spans {
        match merged.last_mut() {
            Some(last) if last.row == span.row && span.start_col <= last.end_col => {
                last.end_col = last.end_col.max(span.end_col);
            }
            _ => merged.push(span),
        }
    }
    merged
}

/// Resolves a path spelling to the existing image or file to edit it
/// names: `~/` against the home directory, a relative path against the
/// pane's working directory.
pub fn resolve_local_path(
    candidate: &str,
    cwd: Option<&Path>,
    home: Option<&Path>,
) -> Option<PathBuf> {
    reference_kind(candidate)?;
    local_file(candidate, cwd, home)
}

/// The existing file a path spelling names, whatever its name ends in.
fn local_file(candidate: &str, cwd: Option<&Path>, home: Option<&Path>) -> Option<PathBuf> {
    let path = if let Some(rest) = candidate.strip_prefix("~/") {
        home?.join(rest)
    } else if candidate.starts_with('/') {
        PathBuf::from(candidate)
    } else {
        cwd?.join(candidate)
    };
    if path.is_file() {
        Some(path)
    } else {
        None
    }
}

/// Quotes `s` for a POSIX shell.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// From the argument vector of an interactive ssh, the command that reaches
/// the same destination with the same options to run one command:
/// options that ask for a terminal, forward ports, background the
/// connection or control a master are dropped, and the fetch never asks a
/// question, never forwards, and gives up quickly. Returns that command
/// (without the remote command) and the remote command words of the
/// original.
pub fn ssh_fetch_command(argv: &[String]) -> Option<(Vec<String>, Vec<String>)> {
    let program = argv.first()?.clone();
    let mut kept = vec![];
    let mut destination = None;
    let mut i = 1;
    while i < argv.len() {
        let arg = &argv[i];
        i += 1;
        if arg == "--" {
            destination = Some(argv.get(i)?.clone());
            i += 1;
            break;
        }
        if !(arg.starts_with('-') && arg.len() > 1) {
            destination = Some(arg.clone());
            break;
        }
        let flags: Vec<char> = arg[1..].chars().collect();
        for (k, &flag) in flags.iter().enumerate() {
            if SSH_FLAGS_WITH_VALUE.contains(flag) {
                let value = if k + 1 < flags.len() {
                    flags[k + 1..].iter().collect()
                } else {
                    let value = argv.get(i)?.clone();
                    i += 1;
                    value
                };
                if !SSH_DROPPED_VALUE_FLAGS.contains(flag) {
                    kept.push(format!("-{flag}"));
                    kept.push(value);
                }
                break;
            }
            if !SSH_DROPPED_FLAGS.contains(flag) {
                kept.push(format!("-{flag}"));
            }
        }
    }
    let destination = destination?;
    // ssh keeps the first value it is given for an option, so these come
    // before the inherited ones.
    let mut command = vec![program];
    for option in [
        "BatchMode=yes",
        "ConnectTimeout=5",
        "ClearAllForwardings=yes",
        "RemoteCommand=none",
    ] {
        command.push("-o".to_string());
        command.push(option.to_string());
    }
    command.extend(kept);
    command.push("-T".to_string());
    command.push(destination);
    Some((command, argv[i..].to_vec()))
}

/// If the remote command attaches to a tmux session (`tmux -L pi-gate
/// attach -t =name`), shell text that changes to the working directory of
/// that session's active pane, failing when there is none.
pub fn tmux_cd_command(remote: &[String]) -> Option<String> {
    let joined = remote.join(" ");
    let words: Vec<&str> = joined.split_whitespace().collect();
    let (first, rest) = words.split_first()?;
    if Path::new(first).file_name()?.to_str()? != "tmux" {
        return None;
    }
    let mut server = vec![];
    let mut i = 0;
    while i < rest.len() && rest[i].starts_with('-') {
        if matches!(rest[i], "-L" | "-S") {
            server.push(rest[i].to_string());
            server.push(sh_quote(rest.get(i + 1)?));
            i += 1;
        } else if matches!(rest[i], "-f" | "-T" | "-c") {
            i += 1;
        }
        i += 1;
    }
    if !matches!(rest.get(i), Some(&"attach") | Some(&"attach-session") | Some(&"a") | Some(&"at")) {
        return None;
    }
    let mut target = None;
    let mut k = i + 1;
    while k < rest.len() {
        if rest[k] == "-t" {
            target = rest.get(k + 1).map(|t| t.to_string());
            k += 1;
        } else if let Some(t) = rest[k].strip_prefix("-t") {
            target = Some(t.to_string());
        }
        k += 1;
    }
    // attach names a session; display-message wants a pane, and reads a
    // bare `=name` as a pane that does not exist. `name:` is the session's
    // current window and its active pane.
    let mut target = target?;
    if !target.contains(':') {
        target.push(':');
    }
    let mut tmux = vec!["tmux".to_string()];
    tmux.extend(server);
    Some(format!(
        "d=$({} display-message -p -t {} '#{{pane_current_path}}' 2>/dev/null) && [ -n \"$d\" ] && cd -- \"$d\"",
        tmux.join(" "),
        sh_quote(&target)
    ))
}

/// The remote shell command that writes the image or file to edit a path
/// names to its output, or fails: `~/` against the remote home, a relative
/// path after `cd` (none: a relative path cannot be resolved).
pub fn remote_read_command(path: &str, cd: Option<&str>) -> Option<String> {
    reference_kind(path)?;
    remote_cat_command(path, cd)
}

/// The remote shell command that succeeds when a path names a file, and
/// sets `f` to it: the start of every command that reads one.
pub fn remote_test_command(path: &str, cd: Option<&str>) -> Option<String> {
    let test = |target: String| format!("f={target} && test -f \"$f\"");
    if let Some(rest) = path.strip_prefix("~/") {
        Some(test(format!("\"$HOME\"/{}", sh_quote(rest))))
    } else if path.starts_with('/') {
        Some(test(sh_quote(path)))
    } else {
        Some(format!("{} && {}", cd?, test(sh_quote(path))))
    }
}

/// The remote shell command that writes the file a path names to its
/// output, or fails, whatever its name ends in.
fn remote_cat_command(path: &str, cd: Option<&str>) -> Option<String> {
    remote_test_command(path, cd).map(|test| format!("{test} && exec cat -- \"$f\""))
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ImageSource {
    File(PathBuf),
    Url(String),
    /// A file on a host reached over ssh: the ssh command, the remote
    /// shell command that writes the file to its output, and the path as
    /// the pane spelled it.
    Remote {
        ssh: Vec<String>,
        command: String,
        path: String,
    },
    /// A file a session sent, on this machine, whose name makes it neither
    /// an image nor a file to edit.
    SentFile(PathBuf),
    /// Such a file on a host reached over ssh: as `Remote`, with the remote
    /// shell command that only finds whether the file is there, so that
    /// marking it reads none of it.
    SentRemote {
        ssh: Vec<String>,
        check: String,
        command: String,
        path: String,
    },
}

impl ImageSource {
    /// What the source names: a sent file by how it was found, anything
    /// else from the end of its name as the finder read it.
    pub fn kind(&self) -> ReferenceKind {
        let name = match self {
            ImageSource::File(path) => path.to_string_lossy(),
            ImageSource::Url(_) => return ReferenceKind::Image,
            ImageSource::Remote { path, .. } => path.as_str().into(),
            ImageSource::SentFile(_) | ImageSource::SentRemote { .. } => return ReferenceKind::Sent,
        };
        reference_kind(&name).unwrap_or(ReferenceKind::Image)
    }

    /// Whether the file is on a host reached over ssh.
    pub fn is_remote(&self) -> bool {
        matches!(self, ImageSource::Remote { .. } | ImageSource::SentRemote { .. })
    }
}

/// The reference the mouse rests on.
#[derive(Debug, Clone, PartialEq)]
pub struct ImageHover {
    pane_id: PaneId,
    source: ImageSource,
    /// The stable rows the reference spans.
    first_row: StableRowIndex,
    last_row: StableRowIndex,
    /// Column of the reference's first char on `first_row`.
    start_col: usize,
    /// The spelling of the path or URL as the pane showed it.
    shown: String,
    /// The text of `first_row..=last_row` when the hover began; the
    /// preview vanishes once it differs.
    row_texts: Vec<String>,
}

enum LoadState {
    Loading,
    Ready(Arc<ImageData>, u32, u32),
    /// A file to edit was read: it exists, and there is nothing to draw.
    Found,
    Failed,
}

struct LoadEntry {
    state: LoadState,
    /// Modification time of the file when the load began, so an image
    /// that is rewritten in place (a figure being iterated on) reloads.
    modified: Option<SystemTime>,
    /// When the latest load began.
    started: Instant,
    /// Which load the entry waits for; the result of an older one is
    /// dropped.
    generation: u64,
}

/// What a pane's paths name, read from what runs in it.
enum PaneFiles {
    Local {
        cwd: Option<PathBuf>,
        home: Option<PathBuf>,
    },
    Ssh {
        ssh: Vec<String>,
        cd: Option<String>,
    },
    Unreachable,
}

/// Whether a spelling would preview.
enum Found {
    Ready(ImageSource, Option<SystemTime>),
    /// A remote file still being fetched.
    Pending(ImageSource),
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct MarkKey {
    viewport_top: StableRowIndex,
    rows: usize,
    cols: usize,
    seqno: SequenceNo,
    loads_finished: u64,
}

struct PaneMarks {
    key: MarkKey,
    found_at: Instant,
    /// Spans whose `row` counts from the top of the viewport.
    spans: Vec<MarkSpan>,
}

#[derive(Default)]
pub struct ImagePreview {
    hover: Option<ImageHover>,
    loads: HashMap<ImageSource, LoadEntry>,
    next_generation: u64,
    /// Counts finished loads, so the marks are found again when one ends.
    loads_finished: u64,
    marks: HashMap<PaneId, PaneMarks>,
    /// The reference a plain left press landed on; its release opens it.
    pressed: Option<ImageHover>,
}

/// Decodes an encoded image and scales it to fit `MAX_DECODED_SIDE`.
pub fn decode_for_preview(bytes: &[u8]) -> anyhow::Result<(Arc<ImageData>, u32, u32)> {
    let image = image::load_from_memory(bytes).context("decode image")?;
    let image = if image.width() > MAX_DECODED_SIDE || image.height() > MAX_DECODED_SIDE {
        image.thumbnail(MAX_DECODED_SIDE, MAX_DECODED_SIDE)
    } else {
        image
    };
    let rgba = image.into_rgba8();
    let (width, height) = rgba.dimensions();
    anyhow::ensure!(width > 0 && height > 0, "empty image");
    let data = ImageData::with_data(ImageDataType::new_single_frame(
        width,
        height,
        rgba.into_raw(),
    ));
    Ok((Arc::new(data), width, height))
}

/// A writer that refuses to hold more than `cap` bytes.
struct CappedWriter {
    buf: Vec<u8>,
    cap: usize,
}

impl Write for CappedWriter {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        if self.buf.len() + data.len() > self.cap {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                "image is too large to preview",
            ));
        }
        self.buf.extend_from_slice(data);
        Ok(data.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn fetch_url(url: &str) -> anyhow::Result<Vec<u8>> {
    let uri = http_req::uri::Uri::try_from(url).map_err(|e| anyhow!("{url}: {e}"))?;
    let mut body = CappedWriter {
        buf: vec![],
        cap: MAX_SOURCE_BYTES,
    };
    let response = http_req::request::Request::new(&uri)
        .timeout(FETCH_TIMEOUT)
        .header("User-Agent", "Loupe image preview")
        .send(&mut body)
        .map_err(|e| anyhow!("fetch {url}: {e}"))?;
    anyhow::ensure!(
        response.status_code().is_success(),
        "fetch {url}: status {:?}",
        response.status_code()
    );
    Ok(body.buf)
}

/// Runs `command` on the far host through `ssh` and returns its output,
/// killing it if it runs past `REMOTE_TIMEOUT` or writes more than
/// `MAX_SOURCE_BYTES`.
fn fetch_remote(ssh: &[String], command: &str) -> anyhow::Result<Vec<u8>> {
    let (program, args) = ssh.split_first().context("empty ssh command")?;
    let mut child = Command::new(program)
        .args(args)
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("run {program}"))?;
    let mut stdout = child.stdout.take().context("ssh output")?;
    let child = Arc::new(Mutex::new(child));
    let done = Arc::new(AtomicBool::new(false));
    {
        let child = Arc::clone(&child);
        let done = Arc::clone(&done);
        std::thread::Builder::new()
            .name("image-preview-ssh-timeout".to_string())
            .spawn(move || {
                let started = Instant::now();
                while !done.load(Ordering::Acquire) {
                    if started.elapsed() > REMOTE_TIMEOUT {
                        let _ = child.lock().unwrap().kill();
                        return;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
            })?;
    }
    let mut bytes = vec![];
    let read = (&mut stdout)
        .take(MAX_SOURCE_BYTES as u64 + 1)
        .read_to_end(&mut bytes);
    if read.is_err() || bytes.len() > MAX_SOURCE_BYTES {
        let _ = child.lock().unwrap().kill();
    }
    done.store(true, Ordering::Release);
    let status = child.lock().unwrap().wait()?;
    read.context("read ssh output")?;
    anyhow::ensure!(bytes.len() <= MAX_SOURCE_BYTES, "image is too large to preview");
    anyhow::ensure!(status.success(), "{program}: {status}");
    Ok(bytes)
}

/// Reads a source on a worker thread: an image is decoded for its preview;
/// a file to edit or a sent file is only found to exist (a remote file to
/// edit is fetched and a remote sent file only tested for, so the mark
/// appears only when the far host has it).
fn load_source(source: &ImageSource) -> anyhow::Result<LoadState> {
    if source.kind() != ReferenceKind::Image {
        match source {
            ImageSource::File(path) | ImageSource::SentFile(path) => {
                anyhow::ensure!(path.is_file(), "{} is gone", path.display())
            }
            ImageSource::Url(url) => anyhow::bail!("{url} is not a file"),
            ImageSource::Remote { ssh, command, .. } => {
                fetch_remote(ssh, command)?;
            }
            ImageSource::SentRemote { ssh, check, .. } => {
                fetch_remote(ssh, check)?;
            }
        }
        return Ok(LoadState::Found);
    }
    let bytes = match source {
        ImageSource::File(path) | ImageSource::SentFile(path) => {
            let len = std::fs::metadata(path)?.len();
            anyhow::ensure!(
                len as usize <= MAX_SOURCE_BYTES,
                "{} is too large to preview",
                path.display()
            );
            std::fs::read(path)?
        }
        ImageSource::Url(url) => fetch_url(url)?,
        ImageSource::Remote { ssh, command, .. } | ImageSource::SentRemote { ssh, command, .. } => {
            fetch_remote(ssh, command)?
        }
    };
    let (data, width, height) = decode_for_preview(&bytes)?;
    Ok(LoadState::Ready(data, width, height))
}

/// The base name of the program a process runs: its executable's, else its
/// first argument's, else its command name.
fn program_name(info: &LocalProcessInfo) -> String {
    let base = |p: &Path| p.file_name().and_then(|n| n.to_str()).map(str::to_string);
    base(&info.executable)
        .or_else(|| info.argv.first().and_then(|a| base(Path::new(a))))
        .unwrap_or_else(|| info.name.clone())
}
/// Programs whose pane shows the files of another host.
fn is_remote_client(name: &str) -> bool {
    matches!(name, "ssh" | "mosh" | "mosh-client" | "et")
}
/// The process of the pane's foreground job that decides where its paths
/// live. The terminal reports only the job's process group, whose leader
/// may be a wrapper that runs the client as its child in the same group:
/// a `sh -c` loop that reconnects an ssh when its connection drops, as the
/// tabs attached to the iMac's sessions are (Ben's `wezterm.lua`,
/// 2026-11-11). So the job's processes are searched from the leader down,
/// one generation at a time, and the shallowest generation holding a remote
/// client decides, if it holds exactly one: an ssh's own children (a
/// ProxyCommand) sit below it and never decide. A process outside the
/// group (`in_group` false) is a background job or a session of its own
/// and is passed over with its children. Without a remote client in the
/// job, the leader decides.
fn foreground_process<'a>(
    leader: &'a LocalProcessInfo,
    in_group: &dyn Fn(u32) -> bool,
) -> &'a LocalProcessInfo {
    let mut generation = vec![leader];
    while !generation.is_empty() {
        let clients: Vec<_> = generation
            .iter()
            .copied()
            .filter(|p| is_remote_client(&program_name(p)))
            .collect();
        match clients.len() {
            0 => {}
            1 => return clients[0],
            _ => return leader,
        }
        generation = generation
            .iter()
            .flat_map(|p| p.children.values())
            .filter(|child| in_group(child.pid))
            .collect();
    }
    leader
}
/// Whether `pid` is in the process group `group`.
#[cfg(unix)]
fn in_process_group(pid: u32, group: u32) -> bool {
    let pgid = unsafe { libc::getpgid(pid as libc::pid_t) };
    pgid >= 0 && pgid as u32 == group
}
#[cfg(not(unix))]
fn in_process_group(_pid: u32, _group: u32) -> bool {
    true
}
/// What the paths a pane prints name: files on this machine (a local
/// domain pane whose foreground job runs neither ssh, mosh nor et), files
/// on the far host of the ssh running in it, or nothing reachable.
fn pane_files(pane: &Arc<dyn Pane>) -> PaneFiles {
    let is_local_domain = Mux::get()
        .get_domain(pane.domain_id())
        .map(|domain| domain.downcast_ref::<LocalDomain>().is_some())
        .unwrap_or(false);
    if !is_local_domain {
        return PaneFiles::Unreachable;
    }
    if let Some(leader) = pane.get_foreground_process_info(CachePolicy::AllowStale) {
        // On unix the leader's pid is the foreground process group's id.
        let group = leader.pid;
        let info = foreground_process(&leader, &|pid| in_process_group(pid, group));
        match program_name(info).as_str() {
            "ssh" => {
                let mut argv = info.argv.clone();
                if let Some(program) = argv.first_mut() {
                    if info.executable.is_file() {
                        *program = info.executable.to_string_lossy().into_owned();
                    }
                }
                return match ssh_fetch_command(&argv) {
                    Some((ssh, remote)) => PaneFiles::Ssh {
                        cd: tmux_cd_command(&remote),
                        ssh,
                    },
                    None => PaneFiles::Unreachable,
                };
            }
            "mosh" | "mosh-client" | "et" => return PaneFiles::Unreachable,
            _ => {}
        }
    }
    PaneFiles::Local {
        cwd: pane
            .get_current_working_dir(CachePolicy::AllowStale)
            .and_then(|url| url.to_file_path().ok()),
        home: dirs_next::home_dir(),
    }
}

/// Where a remote file is saved to be opened on this machine: under the
/// cache's `Topaz/previews` for an image, `Topaz/edits` for a file to
/// edit and `Topaz/sent` for a sent file, in a folder per source so two files of one name do not collide,
/// and under the file's own name, so the viewer's title reads as usual.
fn remote_copy_path(cache: &Path, source: &ImageSource, path: &str) -> PathBuf {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    source.hash(&mut hasher);
    let (folder, fallback) = match source.kind() {
        ReferenceKind::Image => ("previews", "image.png"),
        ReferenceKind::Edit => ("edits", "passage.edit.md"),
        ReferenceKind::Sent => ("sent", "file"),
    };
    let name = Path::new(path)
        .file_name()
        .map(|n| n.to_os_string())
        .unwrap_or_else(|| fallback.into());
    cache
        .join("Loupe")
        .join(folder)
        .join(format!("{:016x}", hasher.finish()))
        .join(name)
}

/// Fetches a file on the far host afresh to its copy in the cache, written
/// beside it first and then renamed into place, and returns the copy.
fn save_remote_copy(source: &ImageSource) -> anyhow::Result<PathBuf> {
    let (ssh, command, path) = match source {
        ImageSource::Remote { ssh, command, path }
        | ImageSource::SentRemote { ssh, command, path, .. } => (ssh, command, path),
        _ => anyhow::bail!("{source:?} is not a file on the far host"),
    };
    let cache = dirs_next::cache_dir().context("no cache folder")?;
    let target = remote_copy_path(&cache, source, path);
    let bytes = fetch_remote(ssh, command)?;
    let folder = target.parent().context("cache folder")?;
    std::fs::create_dir_all(folder)?;
    let partial = folder.join(".partial");
    std::fs::write(&partial, &bytes)?;
    std::fs::rename(&partial, &target)?;
    Ok(target)
}

/// Opens a file in the image viewer: Preview on macOS, the desktop's
/// default elsewhere.
fn open_in_viewer(path: &Path) {
    let path = path.to_string_lossy();
    if cfg!(target_os = "macos") {
        wezterm_open_url::open_with(&path, "Preview");
    } else {
        wezterm_open_url::open_url(&path);
    }
}

/// The version of the request file Topaz hands to Loupe's editor.
const EDIT_REQUEST_VERSION: u32 = 1;
/// The extension of a request file; Loupe opens files of this kind.
const EDIT_REQUEST_EXTENSION: &str = "loupeedit";
/// Counts the requests written by this process, so two in one millisecond
/// get different names.
static EDIT_REQUESTS_WRITTEN: AtomicU64 = AtomicU64::new(0);

/// What a request to edit a file says, in this order: the request
/// version, the mux pane the reference was clicked in (the id `wezterm cli
/// list` reports), the absolute path of the local file to edit, the path
/// as the pane showed it, and whether the file is a copy fetched from the
/// far host of an ssh pane.
#[derive(serde::Serialize)]
struct EditRequest<'a> {
    version: u32,
    pane_id: PaneId,
    file: &'a str,
    shown: &'a str,
    remote: bool,
}

/// The JSON text of a request to edit `file`.
fn edit_request_json(pane_id: PaneId, file: &Path, shown: &str, remote: bool) -> anyhow::Result<String> {
    anyhow::ensure!(file.is_absolute(), "{} is not an absolute path", file.display());
    let file = file
        .to_str()
        .with_context(|| format!("{} is not UTF-8", file.display()))?;
    Ok(serde_json::to_string(&EditRequest {
        version: EDIT_REQUEST_VERSION,
        pane_id,
        file,
        shown,
        remote,
    })?)
}

/// Where a new request file goes: the cache's `Topaz/edits/requests`, named
/// by the time, this process and a count, so no two requests share a name.
fn edit_request_path(cache: &Path) -> PathBuf {
    let millis = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let count = EDIT_REQUESTS_WRITTEN.fetch_add(1, Ordering::Relaxed);
    cache.join("Loupe").join("edits").join("requests").join(format!(
        "{millis}-{}-{count}.{EDIT_REQUEST_EXTENSION}",
        std::process::id()
    ))
}

/// Writes a request to edit `file` under `cache`, beside its final name
/// first and then renamed into place, and returns its path.
fn write_edit_request(
    cache: &Path,
    pane_id: PaneId,
    file: &Path,
    shown: &str,
    remote: bool,
) -> anyhow::Result<PathBuf> {
    let json = edit_request_json(pane_id, file, shown, remote)?;
    let request = edit_request_path(cache);
    let folder = request.parent().context("request folder")?;
    std::fs::create_dir_all(folder)?;
    let name = request.file_name().context("request name")?.to_string_lossy();
    let partial = folder.join(format!(".{name}.partial"));
    std::fs::write(&partial, json)?;
    std::fs::rename(&partial, &request)?;
    Ok(request)
}

/// Loupe's bundle nested in this app, which holds the editor; none in a
/// build outside an app bundle, and none off macOS.
#[cfg(target_os = "macos")]
fn hud_bundle() -> Option<PathBuf> {
    crate::helpers::helper_bundle("LoupeHUD")
}

#[cfg(not(target_os = "macos"))]
fn hud_bundle() -> Option<PathBuf> {
    None
}

/// Hands a local file to Loupe's editor: writes a request naming it and the
/// pane it came from, and opens the request with Loupe.
fn open_in_editor(
    hud: &Path,
    pane_id: PaneId,
    file: &Path,
    shown: &str,
    remote: bool,
) -> anyhow::Result<()> {
    let cache = dirs_next::cache_dir().context("no cache folder")?;
    let request = write_edit_request(&cache, pane_id, file, shown, remote)?;
    let status = Command::new("/usr/bin/open")
        .arg("-a")
        .arg(hud)
        .arg(&request)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("run /usr/bin/open")?;
    anyhow::ensure!(
        status.success(),
        "open -a {} {}: {status}",
        hud.display(),
        request.display()
    );
    Ok(())
}

/// Opens a file in the app macOS (or the desktop) opens its type with.
fn open_in_default_app(path: &Path) {
    wezterm_open_url::open_url(&path.to_string_lossy());
}

/// Opens what a reference names: an image file here in the viewer, a URL
/// in the browser, a file to edit in Loupe's editor, a sent file in its
/// default app. A file on the far host is fetched afresh to the cache
/// first, on a thread, and the copy opened.
fn open_reference(hover: ImageHover) {
    let ImageHover {
        pane_id,
        source,
        shown,
        ..
    } = hover;
    let kind = source.kind();
    let hud = match kind {
        ReferenceKind::Image | ReferenceKind::Sent => None,
        ReferenceKind::Edit => {
            if !cfg!(target_os = "macos") {
                log::error!("image preview: cannot edit {shown}: the editor is macOS only");
                return;
            }
            match hud_bundle() {
                Some(hud) => Some(hud),
                None => {
                    log::error!("image preview: cannot edit {shown}: this build has no LoupeHUD.app");
                    return;
                }
            }
        }
    };
    let remote = source.is_remote();
    match source {
        ImageSource::Url(url) => wezterm_open_url::open_url(&url),
        ImageSource::File(path) if kind == ReferenceKind::Image => open_in_viewer(&path),
        ImageSource::SentFile(path) => open_in_default_app(&path),
        source => {
            let spawned = std::thread::Builder::new()
                .name("image-preview-open".to_string())
                .spawn(move || {
                    let opened = (|| -> anyhow::Result<()> {
                        let local = match &source {
                            ImageSource::File(path) => path.clone(),
                            _ => save_remote_copy(&source)?,
                        };
                        match &hud {
                            Some(hud) => open_in_editor(hud, pane_id, &local, &shown, remote)?,
                            None if kind == ReferenceKind::Sent => open_in_default_app(&local),
                            None => open_in_viewer(&local),
                        }
                        Ok(())
                    })();
                    if let Err(err) = opened {
                        log::error!("image preview: cannot open {shown}: {err:#}");
                    }
                });
            if let Err(err) = spawned {
                log::error!("image preview: cannot start a thread to open a reference: {err:#}");
            }
        }
    }
}

fn file_modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path).and_then(|m| m.modified()).ok()
}

impl crate::TermWindow {
    /// Called on every mouse event over the terminal area, with the window
    /// cell the pointer is in.
    pub fn update_image_preview_hover(&mut self, column: usize, row: i64, context: &dyn WindowOps) {
        let hover = if self.config.image_preview_on_hover {
            self.find_image_hover(column, row)
        } else {
            None
        };
        if hover != self.image_preview.hover {
            if let Some(ImageHover {
                source: source @ ImageSource::Remote { .. },
                ..
            }) = &hover
            {
                self.refresh_remote_if_stale(source);
            }
            self.image_preview.hover = hover;
            context.invalidate();
        }
    }

    /// Called when the pointer leaves the terminal area or the window.
    pub fn clear_image_preview_hover(&mut self, context: &dyn WindowOps) {
        if self.image_preview.hover.take().is_some() {
            context.invalidate();
        }
    }

    /// Whether the pointer rests on a reference that previews, or a file to
    /// edit or a sent file that exists, so it shows as a hand.
    pub fn image_preview_wants_pointer(&self) -> bool {
        let hover = match &self.image_preview.hover {
            Some(hover) => hover,
            None => return false,
        };
        // A file here to edit, or a sent file here, was found when the
        // hover began, and is never loaded.
        if matches!(hover.source, ImageSource::SentFile(_))
            || (matches!(hover.source, ImageSource::File(_)) && hover.source.kind() == ReferenceKind::Edit)
        {
            return true;
        }
        match self.image_preview.loads.get(&hover.source).map(|e| &e.state) {
            Some(LoadState::Ready(..)) | Some(LoadState::Found) => true,
            Some(LoadState::Loading) => !hover.source.is_remote(),
            _ => false,
        }
    }

    /// Takes a plain left click on a reference that previews or a file to
    /// edit: the press is held back from the pane, and the release opens
    /// what it names if the pointer is still on that reference. Returns true for an event it
    /// took, which the pane must not see.
    pub fn image_preview_click(&mut self, event: &::window::MouseEvent) -> bool {
        use ::window::{MouseEventKind, MousePress};
        let plain = event.modifiers.remove_positional_mods() == ::window::Modifiers::NONE;
        match event.kind {
            MouseEventKind::Press(MousePress::Left) if plain && self.image_preview_wants_pointer() => {
                self.image_preview.pressed = self.image_preview.hover.clone();
                true
            }
            MouseEventKind::Release(MousePress::Left) => match self.image_preview.pressed.take() {
                Some(pressed) => {
                    if self.image_preview.hover.as_ref() == Some(&pressed) {
                        open_reference(pressed);
                    }
                    true
                }
                None => false,
            },
            // A drag that began on a reference stays with it.
            MouseEventKind::Move => self.image_preview.pressed.is_some(),
            _ => false,
        }
    }

    /// Opens the image or file to edit under the pointer, if it previews or
    /// exists; true when it did. Called for the click that would open a
    /// link.
    pub fn open_hovered_image(&self) -> bool {
        if !self.image_preview_wants_pointer() {
            return false;
        }
        match &self.image_preview.hover {
            Some(hover) => {
                open_reference(hover.clone());
                true
            }
            None => false,
        }
    }

    /// Whether a spelling of a path would preview, or names a file to edit
    /// or a sent file that exists, in a pane whose paths name `files`;
    /// starts the fetch of a remote file not yet tried. `kind` is what the
    /// finder took the spelling for: a sent file may have any name.
    fn resolve_path(&mut self, files: &PaneFiles, text: &str, kind: ReferenceKind) -> Found {
        let sent = kind == ReferenceKind::Sent;
        match files {
            PaneFiles::Local { cwd, home } => {
                let path = if sent {
                    local_file(text, cwd.as_deref(), home.as_deref())
                } else {
                    resolve_local_path(text, cwd.as_deref(), home.as_deref())
                };
                match path {
                    Some(path) => {
                        let modified = file_modified(&path);
                        let source = if sent {
                            ImageSource::SentFile(path)
                        } else {
                            ImageSource::File(path)
                        };
                        Found::Ready(source, modified)
                    }
                    None => Found::Unavailable,
                }
            }
            PaneFiles::Ssh { ssh, cd } => {
                let source = if sent {
                    let check = remote_test_command(text, cd.as_deref());
                    let command = remote_cat_command(text, cd.as_deref());
                    match (check, command) {
                        (Some(check), Some(command)) => ImageSource::SentRemote {
                            ssh: ssh.clone(),
                            check,
                            command,
                            path: text.to_string(),
                        },
                        _ => return Found::Unavailable,
                    }
                } else {
                    match remote_read_command(text, cd.as_deref()) {
                        Some(command) => ImageSource::Remote {
                            ssh: ssh.clone(),
                            command,
                            path: text.to_string(),
                        },
                        None => return Found::Unavailable,
                    }
                };
                let retry = match self.image_preview.loads.get(&source) {
                    None => true,
                    Some(entry) => match entry.state {
                        LoadState::Ready(..) | LoadState::Found => {
                            return Found::Ready(source, None)
                        }
                        LoadState::Loading => return Found::Pending(source),
                        LoadState::Failed => entry.started.elapsed() > REMOTE_RETRY,
                    },
                };
                let in_flight = self
                    .image_preview
                    .loads
                    .iter()
                    .filter(|(source, entry)| {
                        source.is_remote() && matches!(entry.state, LoadState::Loading)
                    })
                    .count();
                if retry && in_flight < MAX_REMOTE_FETCHES {
                    self.start_image_load(&source, None, false);
                    Found::Pending(source)
                } else {
                    Found::Unavailable
                }
            }
            PaneFiles::Unreachable => Found::Unavailable,
        }
    }

    fn find_image_hover(&mut self, column: usize, row: i64) -> Option<ImageHover> {
        let pos = self.get_panes_to_render().into_iter().find(|pos| {
            row >= pos.top as i64
                && row < (pos.top + pos.height) as i64
                && column >= pos.left
                && column < pos.left + pos.width
        })?;
        let pane = Arc::clone(&pos.pane);
        let column = column - pos.left;
        let dims = pane.get_dimensions();
        let viewport_top = self
            .get_viewport(pane.pane_id())
            .unwrap_or(dims.physical_top);
        let stable_row = viewport_top + (row - pos.top as i64) as StableRowIndex;

        let low = (stable_row - WRAPPED_ROWS_EACH_WAY as StableRowIndex).max(0);
        let high = stable_row + WRAPPED_ROWS_EACH_WAY as StableRowIndex + 1;
        let (first_fetched, lines) = pane.get_lines(low..high);
        let hovered = usize::try_from(stable_row - first_fetched).ok()?;
        if hovered >= lines.len() {
            return None;
        }
        let rows: Vec<RowCells> = lines.iter().map(RowCells::from_line).collect();

        // What the pane's paths name; looked up only once a path covers
        // the pointer, since this runs on every mouse move.
        let mut files: Option<PaneFiles> = None;
        // A remote spelling still being fetched, used if nothing previews
        // now.
        let mut pending: Option<ImageHover> = None;

        // The hovered row alone first, so a path that starts a row is not
        // glued to the word that ends the row above; then the joined rows;
        // then the lines of sent files, each reading of one in turn.
        let single = join_rows(&rows, hovered, hovered);
        let joined = join_wrapped_rows(&rows, hovered, dims.cols);
        let under_pointer = |positions: &[(usize, usize)]| {
            positions
                .iter()
                .position(|&(r, col)| r == hovered && col == column)
        };
        let mut runs: Vec<(usize, Vec<(usize, usize)>, Vec<ImageReference>)> = vec![];
        for (chars, positions) in [single, joined] {
            if let Some(idx) = under_pointer(&positions) {
                let text: String = chars.iter().collect();
                runs.push((idx, positions, find_image_references(&text)));
            }
        }
        for path in find_sent_files(&rows).into_iter().flatten() {
            if let Some(idx) = under_pointer(&path.positions) {
                let reference = path.reference();
                runs.push((idx, path.positions, vec![reference]));
            }
        }

        for (hover_idx, positions, references) in runs {
            for reference in references {
                for candidate in &reference.candidates {
                    if !(candidate.start <= hover_idx && hover_idx < reference.end) {
                        continue;
                    }
                    let found = if reference.is_url {
                        Found::Ready(ImageSource::Url(candidate.text.clone()), None)
                    } else {
                        let files = files.get_or_insert_with(|| pane_files(&pane));
                        self.resolve_path(files, &candidate.text, reference.kind)
                    };
                    let (first_r, start_col) = positions[candidate.start];
                    let (last_r, _) = positions[reference.end - 1];
                    let make = |source: ImageSource| ImageHover {
                        pane_id: pane.pane_id(),
                        source,
                        first_row: first_fetched + first_r as StableRowIndex,
                        last_row: first_fetched + last_r as StableRowIndex,
                        start_col,
                        shown: candidate.text.clone(),
                        row_texts: lines[first_r..=last_r]
                            .iter()
                            .map(|l| l.as_str().into_owned())
                            .collect(),
                    };
                    match found {
                        Found::Ready(source, modified) => {
                            // A file here to edit, or a sent file here,
                            // has nothing to load.
                            if !source.is_remote()
                                && source.kind() == ReferenceKind::Image
                            {
                                self.ensure_image_loading(&source, modified);
                            }
                            return Some(make(source));
                        }
                        Found::Pending(source) => {
                            if pending.is_none() {
                                pending = Some(make(source));
                            }
                        }
                        Found::Unavailable => {}
                    }
                }
            }
        }
        pending
    }

    fn ensure_image_loading(&mut self, source: &ImageSource, modified: Option<SystemTime>) {
        if let Some(entry) = self.image_preview.loads.get(source) {
            if entry.modified == modified {
                return;
            }
        }
        self.start_image_load(source, modified, false);
    }

    /// Fetches a remote image again if it was loaded long enough ago,
    /// showing the old picture until the new one arrives.
    fn refresh_remote_if_stale(&mut self, source: &ImageSource) {
        let stale = matches!(
            self.image_preview.loads.get(source),
            Some(LoadEntry {
                state: LoadState::Ready(..),
                started,
                ..
            }) if started.elapsed() > REMOTE_REFRESH
        );
        if stale {
            self.start_image_load(source, None, true);
        }
    }

    /// Starts loading `source` on a worker thread. With `keep_shown`, a
    /// picture already loaded stays until the new one replaces it.
    fn start_image_load(&mut self, source: &ImageSource, modified: Option<SystemTime>, keep_shown: bool) {
        let preview = &mut self.image_preview;
        let generation = preview.next_generation;
        preview.next_generation += 1;
        let now = Instant::now();
        match preview.loads.get_mut(source) {
            Some(entry) if keep_shown && matches!(entry.state, LoadState::Ready(..)) => {
                entry.modified = modified;
                entry.started = now;
                entry.generation = generation;
            }
            _ => {
                if !preview.loads.contains_key(source) && preview.loads.len() >= MAX_CACHED_IMAGES {
                    let oldest = preview
                        .loads
                        .iter()
                        .min_by_key(|(_, entry)| entry.started)
                        .map(|(source, _)| source.clone());
                    if let Some(oldest) = oldest {
                        preview.loads.remove(&oldest);
                    }
                }
                preview.loads.insert(
                    source.clone(),
                    LoadEntry {
                        state: LoadState::Loading,
                        modified,
                        started: now,
                        generation,
                    },
                );
            }
        }
        let window = match self.window.clone() {
            Some(window) => window,
            None => return,
        };
        let source = source.clone();
        let spawned = std::thread::Builder::new()
            .name("image-preview".to_string())
            .spawn(move || {
                let result = load_source(&source);
                if let Err(err) = &result {
                    log::debug!("image preview of {source:?}: {err:#}");
                }
                window.notify(TermWindowNotif::Apply(Box::new(move |tw| {
                    if let Some(entry) = tw.image_preview.loads.get_mut(&source) {
                        if entry.generation == generation {
                            entry.state = result.unwrap_or(LoadState::Failed);
                            tw.image_preview.loads_finished += 1;
                        }
                    }
                    if let Some(window) = tw.window.as_ref() {
                        window.invalidate();
                    }
                })));
            });
        if let Err(err) = spawned {
            log::error!("image preview: cannot start a loader thread: {err:#}");
        }
    }

    /// The pixel rectangle of a pane: left, top, right, bottom.
    fn image_preview_pane_rect(&self, pos: &PositionedPane) -> anyhow::Result<(f32, f32, f32, f32)> {
        let cell_width = self.render_metrics.cell_size.width as f32;
        let cell_height = self.render_metrics.cell_size.height as f32;
        let (padding_left, padding_top) = self.padding_left_top();
        let top_bar_height = if self.show_tab_bar && !self.config.tab_bar_at_bottom {
            self.tab_bar_pixel_height()?
        } else {
            0.
        };
        let border = self.get_os_border();
        let left = padding_left + border.left.get() as f32 + pos.left as f32 * cell_width;
        let top =
            top_bar_height + padding_top + border.top.get() as f32 + pos.top as f32 * cell_height;
        Ok((
            left,
            top,
            left + pos.width as f32 * cell_width,
            top + pos.height as f32 * cell_height,
        ))
    }

    /// The marks of the references on screen in one pane.
    fn find_image_marks(
        &mut self,
        pane: &Arc<dyn Pane>,
        viewport_top: StableRowIndex,
        rows: usize,
        cols: usize,
    ) -> Vec<MarkSpan> {
        let (first, lines) = pane.get_lines(viewport_top..viewport_top + rows as StableRowIndex);
        let offset = first - viewport_top;
        let rows: Vec<RowCells> = lines.iter().map(RowCells::from_line).collect();
        let mut files: Option<PaneFiles> = None;
        let mut spans = reference_marks(&rows, cols, |reference| {
            if reference.is_url {
                return Some(0);
            }
            let files = files.get_or_insert_with(|| pane_files(pane));
            let mut picked = None;
            for (i, candidate) in reference.candidates.iter().enumerate() {
                if let Found::Ready(..) = self.resolve_path(files, &candidate.text, reference.kind) {
                    picked = Some(i);
                    break;
                }
            }
            picked
        });
        for span in &mut spans {
            span.row = (span.row as StableRowIndex + offset) as usize;
        }
        spans
    }

    /// Underlines, with a faint dash in each cell, every reference on
    /// screen that previews. Drawn over the panes, never into their grids.
    pub fn paint_image_marks(&mut self, layers: &mut TripleLayerQuadAllocator) -> anyhow::Result<()> {
        if !self.config.image_preview_on_hover || !self.config.image_preview_underline {
            self.image_preview.marks.clear();
            return Ok(());
        }
        let panes = self.get_panes_to_render();
        self.image_preview
            .marks
            .retain(|id, _| panes.iter().any(|pos| pos.pane.pane_id() == *id));
        let cell_width = self.render_metrics.cell_size.width as f32;
        let cell_height = self.render_metrics.cell_size.height as f32;
        let underline_top = self.render_metrics.descender_row as f32;
        let underline_height = self.render_metrics.underline_height.max(1) as f32;
        for pos in &panes {
            let pane_id = pos.pane.pane_id();
            let dims = pos.pane.get_dimensions();
            let viewport_top = self.get_viewport(pane_id).unwrap_or(dims.physical_top);
            let key = MarkKey {
                viewport_top,
                rows: dims.viewport_rows,
                cols: dims.cols,
                seqno: pos.pane.get_current_seqno(),
                loads_finished: self.image_preview.loads_finished,
            };
            let fresh = matches!(
                self.image_preview.marks.get(&pane_id),
                Some(marks) if marks.key == key && marks.found_at.elapsed() < MARK_RECHECK
            );
            if !fresh {
                let spans = self.find_image_marks(&pos.pane, viewport_top, dims.viewport_rows, dims.cols);
                // A fetch that finished while looking changes nothing found.
                let key = MarkKey {
                    loads_finished: self.image_preview.loads_finished,
                    ..key
                };
                self.image_preview.marks.insert(
                    pane_id,
                    PaneMarks {
                        key,
                        found_at: Instant::now(),
                        spans,
                    },
                );
            }
            let spans = match self.image_preview.marks.get(&pane_id) {
                Some(marks) if !marks.spans.is_empty() => marks.spans.clone(),
                _ => continue,
            };
            let (pane_left, pane_top, _, _) = self.image_preview_pane_rect(pos)?;
            let color = pos.pane.palette().foreground.to_linear().mul_alpha(0.45);
            for span in spans {
                if span.row >= pos.height {
                    continue;
                }
                let y = pane_top + span.row as f32 * cell_height + underline_top;
                for col in span.start_col..span.end_col.min(pos.width) {
                    let x = pane_left + col as f32 * cell_width + cell_width * 0.2;
                    self.filled_rectangle(
                        layers,
                        2,
                        euclid::rect(x, y, cell_width * 0.6, underline_height),
                        color,
                    )?;
                }
            }
        }
        Ok(())
    }

    /// Draws the preview for the hovered reference, on top of the panes.
    pub fn paint_image_preview(
        &mut self,
        layers: &mut TripleLayerQuadAllocator,
    ) -> anyhow::Result<()> {
        if !self.config.image_preview_on_hover || self.allow_images == AllowImage::No {
            return Ok(());
        }
        let hover = match self.image_preview.hover.clone() {
            Some(hover) => hover,
            None => return Ok(()),
        };
        let (data, image_width, image_height) = match self.image_preview.loads.get(&hover.source) {
            Some(LoadEntry {
                state: LoadState::Ready(data, width, height),
                ..
            }) => (Arc::clone(data), *width as f32, *height as f32),
            _ => return Ok(()),
        };
        let pos = match self
            .get_panes_to_render()
            .into_iter()
            .find(|pos| pos.pane.pane_id() == hover.pane_id)
        {
            Some(pos) => pos,
            None => return Ok(()),
        };

        // The rows that named the image were rewritten: draw nothing.
        let (_, lines) = pos.pane.get_lines(hover.first_row..hover.last_row + 1);
        let unchanged = lines.len() == hover.row_texts.len()
            && lines
                .iter()
                .zip(&hover.row_texts)
                .all(|(line, text)| line.as_str() == text.as_str());
        if !unchanged {
            self.image_preview.hover = None;
            return Ok(());
        }

        let dims = pos.pane.get_dimensions();
        let viewport_top = self
            .get_viewport(hover.pane_id)
            .unwrap_or(dims.physical_top);
        let first_screen_row = hover.first_row - viewport_top;
        let last_screen_row = hover.last_row - viewport_top;
        if last_screen_row < 0 || first_screen_row >= dims.viewport_rows as StableRowIndex {
            return Ok(());
        }

        let cell_width = self.render_metrics.cell_size.width as f32;
        let cell_height = self.render_metrics.cell_size.height as f32;
        let (pane_left, pane_top, pane_right, pane_bottom) = self.image_preview_pane_rect(&pos)?;

        let max_height = (self.config.image_preview_max_rows as f32 * cell_height)
            .min(pos.height as f32 * cell_height - 2. * FRAME_PIXELS);
        let max_width = pos.width as f32 * cell_width - 2. * FRAME_PIXELS;
        if max_height < cell_height || max_width < cell_width {
            return Ok(());
        }
        let scale = (max_width / image_width)
            .min(max_height / image_height)
            .min(1.0);
        let width = (image_width * scale).floor();
        let height = (image_height * scale).floor();

        let below = pane_top + (last_screen_row + 1) as f32 * cell_height + FRAME_PIXELS;
        let above = pane_top + first_screen_row as f32 * cell_height - FRAME_PIXELS - height;
        let y = if below + height + FRAME_PIXELS <= pane_bottom {
            below
        } else if above - FRAME_PIXELS >= pane_top {
            above
        } else {
            (pane_bottom - FRAME_PIXELS - height).max(pane_top + FRAME_PIXELS)
        };
        let x = (pane_left + hover.start_col as f32 * cell_width + FRAME_PIXELS)
            .min(pane_right - FRAME_PIXELS - width)
            .max(pane_left + FRAME_PIXELS);

        let gl_state = self.render_state.as_ref().unwrap();
        let cached = gl_state
            .glyph_cache
            .borrow_mut()
            .cached_image(&data, None, self.allow_images);
        let sprite = match cached {
            Ok((sprite, next_due, _)) => {
                self.update_next_frame_time(next_due);
                sprite
            }
            Err(err) => {
                if err
                    .root_cause()
                    .downcast_ref::<OutOfTextureSpace>()
                    .is_some()
                {
                    // paint_impl grows the atlas and paints again
                    return Err(err);
                }
                log::warn!("image preview of {:?}: {err:#}", hover.source);
                if let Some(entry) = self.image_preview.loads.get_mut(&hover.source) {
                    entry.state = LoadState::Failed;
                }
                return Ok(());
            }
        };

        let palette = pos.pane.palette();
        self.filled_rectangle(
            layers,
            2,
            euclid::rect(
                x - FRAME_PIXELS,
                y - FRAME_PIXELS,
                width + 2. * FRAME_PIXELS,
                height + 2. * FRAME_PIXELS,
            ),
            palette.foreground.to_linear().mul_alpha(0.5),
        )?;
        self.filled_rectangle(
            layers,
            2,
            euclid::rect(x, y, width, height),
            palette.background.to_linear(),
        )?;

        let left_offset = self.dimensions.pixel_width as f32 / 2.;
        let top_offset = self.dimensions.pixel_height as f32 / 2.;
        let mut quad = layers.allocate(2)?;
        quad.set_position(
            x - left_offset,
            y - top_offset,
            x + width - left_offset,
            y + height - top_offset,
        );
        quad.set_texture(sprite.texture_coords());
        quad.set_fg_color(LinearRgba::with_components(1., 1., 1., 1.));
        quad.set_hsv(None);
        quad.set_has_color(true);
        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;

    fn texts(line: &str) -> Vec<Vec<String>> {
        find_image_references(line)
            .into_iter()
            .map(|r| r.candidates.into_iter().map(|c| c.text).collect())
            .collect()
    }

    #[test]
    fn extensions() {
        assert!(has_image_extension("a.png"));
        assert!(has_image_extension("A.JPEG"));
        assert!(has_image_extension("x/y.webp"));
        assert!(has_image_extension("y.gif"));
        assert!(!has_image_extension(".png"));
        assert!(!has_image_extension("a.pngx"));
        assert!(!has_image_extension("a.svg"));
        assert!(!has_image_extension("png"));
    }

    #[test]
    fn claude_code_read_tool_line() {
        assert_eq!(
            texts("\u{23fa} Read(/tmp/dnq/g-3.png)"),
            vec![vec!["/tmp/dnq/g-3.png".to_string()]]
        );
        assert_eq!(
            texts("\u{23fa} Read(outputs/explore/fig_stitch_cascade.png)"),
            vec![vec!["outputs/explore/fig_stitch_cascade.png".to_string()]]
        );
        // The result line names no file.
        assert!(texts("  \u{23bf}  Read image (52.3KB)").is_empty());
    }

    #[test]
    fn prose_markdown_and_backticks() {
        assert_eq!(
            texts("Saved the figure to `~/Projects/x/fig1.PNG`, see it."),
            vec![vec!["~/Projects/x/fig1.PNG".to_string()]]
        );
        assert_eq!(
            texts("![chart](figures/chart.jpg) and **out/b.jpeg**."),
            vec![
                vec!["figures/chart.jpg".to_string()],
                vec!["out/b.jpeg".to_string()]
            ]
        );
        assert_eq!(
            texts("Wrote /tmp/a.png."),
            vec![vec!["/tmp/a.png".to_string()]]
        );
        assert_eq!(
            texts("open file:///tmp/a%20b.png"),
            vec![vec!["/tmp/a%20b.png".to_string()]]
        );
    }

    #[test]
    fn not_images() {
        assert!(texts("main.rs foo.pngs a.png_old .png e.g. v1.2").is_empty());
        assert!(texts("see plot.svg and paper.pdf").is_empty());
    }

    #[test]
    fn truncated_with_ellipsis_is_dropped() {
        assert!(texts("Read(\u{2026}/sheets/x1_01.png)").is_empty());
    }

    #[test]
    fn names_with_spaces_offer_longest_first() {
        let line = "Read(/Users/b/Desktop/Screenshot 2026-11-08 at 10.12.33\u{202f}AM.png)";
        assert_eq!(
            texts(line),
            vec![vec![
                "/Users/b/Desktop/Screenshot 2026-11-08 at 10.12.33\u{202f}AM.png".to_string(),
                "AM.png".to_string(),
            ]]
        );
        let line = "cp /tmp/a.png /tmp/b c.png";
        assert_eq!(
            texts(line),
            vec![
                vec!["/tmp/a.png".to_string()],
                vec![
                    "/tmp/a.png /tmp/b c.png".to_string(),
                    "/tmp/b c.png".to_string(),
                    "c.png".to_string()
                ]
            ]
        );
    }

    #[test]
    fn urls() {
        assert_eq!(
            texts("see https://example.com/img/cat.png?size=2 now"),
            vec![vec!["https://example.com/img/cat.png?size=2".to_string()]]
        );
        assert_eq!(
            texts("[x](https://example.com/a.webp)."),
            vec![vec!["https://example.com/a.webp".to_string()]]
        );
        // A page, not an image; and the image name inside it is not a path.
        assert!(texts("https://example.com/a.png/view https://claude.ai/x").is_empty());
    }

    #[test]
    fn spans_point_at_the_reference() {
        let refs = find_image_references("ab Read(/x/y.png) z");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].candidates[0].start, 8);
        assert_eq!(refs[0].end, 16);
    }

    #[test]
    fn wrapped_path_joins_across_rows() {
        let width = 20;
        let rows = vec![
            RowCells::from_str("\u{23fa} Read(/Users/bb/Pr"),
            RowCells::from_str("  ojects/fig.png)"),
            RowCells::from_str("  \u{23bf}  Read image"),
        ];
        // The first row is full, so rows 0 and 1 join; row 1 is not full,
        // so row 2 stays out.
        for hovered in [0, 1] {
            let (chars, positions) = join_wrapped_rows(&rows, hovered, width);
            let text: String = chars.iter().collect();
            assert_eq!(text, "\u{23fa} Read(/Users/bb/Projects/fig.png)");
            let refs = find_image_references(&text);
            assert_eq!(refs[0].candidates[0].text, "/Users/bb/Projects/fig.png");
            // The reference starts on row 0, column 7 and ends on row 1.
            assert_eq!(positions[refs[0].candidates[0].start], (0, 7));
            assert_eq!(positions[refs[0].end - 1].0, 1);
        }
        let (chars, _) = join_wrapped_rows(&rows, 2, width);
        assert_eq!(chars.iter().collect::<String>(), "  \u{23bf}  Read image");
    }

    #[test]
    fn resolves_relative_home_and_absolute() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("out");
        std::fs::create_dir(&sub).unwrap();
        let file = sub.join("Screenshot 1\u{202f}AM.png");
        std::fs::write(&file, b"x").unwrap();
        assert_eq!(
            resolve_local_path("out/Screenshot 1\u{202f}AM.png", Some(dir.path()), None),
            Some(file.clone())
        );
        assert_eq!(
            resolve_local_path("~/out/Screenshot 1\u{202f}AM.png", None, Some(dir.path())),
            Some(file.clone())
        );
        let absolute = file.to_str().unwrap().to_string();
        assert_eq!(resolve_local_path(&absolute, None, None), Some(file));
        assert_eq!(
            resolve_local_path("out/missing.png", Some(dir.path()), None),
            None
        );
        assert_eq!(resolve_local_path("out", Some(dir.path()), None), None);
        assert_eq!(resolve_local_path("relative.png", None, None), None);
    }

    fn strings(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| w.to_string()).collect()
    }

    #[test]
    fn ssh_fetch_keeps_destination_and_options() {
        let argv = strings(&[
            "/usr/bin/ssh",
            "-t",
            "-p",
            "2222",
            "-L8080:localhost:80",
            "-i",
            "/k/id",
            "imac",
            "tmux -L pi-gate attach -t =rc-x",
        ]);
        let (ssh, remote) = ssh_fetch_command(&argv).unwrap();
        assert_eq!(
            ssh,
            strings(&[
                "/usr/bin/ssh",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "-o",
                "ClearAllForwardings=yes",
                "-o",
                "RemoteCommand=none",
                "-p",
                "2222",
                "-i",
                "/k/id",
                "-T",
                "imac",
            ])
        );
        assert_eq!(remote, strings(&["tmux -L pi-gate attach -t =rc-x"]));
        let (ssh, remote) = ssh_fetch_command(&strings(&["ssh", "-tA", "host"])).unwrap();
        assert_eq!(ssh.last().unwrap(), "host");
        assert!(ssh.contains(&"-A".to_string()));
        assert!(!ssh.contains(&"-t".to_string()));
        assert!(remote.is_empty());
        assert_eq!(ssh_fetch_command(&strings(&["ssh", "-p"])), None);
        assert_eq!(ssh_fetch_command(&strings(&["ssh", "-V"])), None);
    }

    fn process(pid: u32, argv: &[&str], children: Vec<LocalProcessInfo>) -> LocalProcessInfo {
        LocalProcessInfo {
            pid,
            ppid: 0,
            name: String::new(),
            executable: PathBuf::from(argv[0]),
            argv: strings(argv),
            cwd: PathBuf::new(),
            status: procinfo::LocalProcessStatus::Run,
            start_time: 0,
            #[cfg(windows)]
            console: 0,
            children: children.into_iter().map(|c| (c.pid, c)).collect(),
        }
    }
    #[test]
    fn foreground_ssh_is_found_under_a_wrapper() {
        let attach = ["/usr/bin/ssh", "-t", "imac", "tmux -L pi-gate attach -t =rc-x"];
        // The reconnect loop leads the job; its ssh is the client.
        let ssh = process(11, &attach, vec![process(12, &["/bin/sh", "-c", "nc"], vec![])]);
        let leader = process(10, &["/bin/sh", "-c", "while :; do ssh; done"], vec![ssh]);
        let all = |_: u32| true;
        let found = foreground_process(&leader, &all);
        assert_eq!(found.pid, 11);
        // ssh leading the job decides; its ProxyCommand child never does.
        let proxied = process(11, &attach, vec![process(12, &["/usr/bin/ssh", "-W", "x"], vec![])]);
        assert_eq!(foreground_process(&proxied, &all).pid, 11);
        // Between tries the loop sleeps: no client, the leader decides.
        let sleeping = process(10, &["/bin/sh", "-c", "loop"], vec![process(13, &["sleep", "3"], vec![])]);
        assert_eq!(foreground_process(&sleeping, &all).pid, 10);
        // A background ssh of an interactive shell is outside the group.
        let shell = process(20, &["-zsh"], vec![process(21, &["/usr/bin/ssh", "-N", "tunnel"], vec![])]);
        assert_eq!(foreground_process(&shell, &|pid| pid == 20).pid, 20);
        // Two clients in one generation: no single far host, the leader decides.
        let two = process(
            30,
            &["/bin/sh"],
            vec![process(31, &["/usr/bin/ssh", "a"], vec![]), process(32, &["/usr/bin/ssh", "b"], vec![])],
        );
        assert_eq!(foreground_process(&two, &all).pid, 30);
    }
    #[test]
    fn tmux_cd_finds_the_attached_session() {
        assert_eq!(
            tmux_cd_command(&strings(&["tmux -L pi-gate attach -t =rc-x"])).unwrap(),
            "d=$(tmux -L 'pi-gate' display-message -p -t '=rc-x:' '#{pane_current_path}' 2>/dev/null) && [ -n \"$d\" ] && cd -- \"$d\""
        );
        assert!(tmux_cd_command(&strings(&["/usr/bin/tmux", "a", "-tmain"]))
            .unwrap()
            .contains("-t 'main:'"));
        assert_eq!(tmux_cd_command(&strings(&["tmux", "new", "-s", "x"])), None);
        assert_eq!(tmux_cd_command(&strings(&["htop"])), None);
        assert_eq!(tmux_cd_command(&[]), None);
    }

    #[test]
    fn remote_read_quotes_the_path() {
        assert_eq!(
            remote_read_command("/tmp/it's.png", None).unwrap(),
            "f='/tmp/it'\\''s.png' && test -f \"$f\" && exec cat -- \"$f\""
        );
        assert_eq!(
            remote_read_command("~/a b.png", None).unwrap(),
            "f=\"$HOME\"/'a b.png' && test -f \"$f\" && exec cat -- \"$f\""
        );
        assert_eq!(remote_read_command("out/x.png", None), None);
        assert_eq!(
            remote_read_command("out/x.png", Some("cd /w")).unwrap(),
            "cd /w && f='out/x.png' && test -f \"$f\" && exec cat -- \"$f\""
        );
        assert_eq!(remote_read_command("/tmp/x.txt", None), None);
    }

    #[test]
    fn remote_read_runs_in_a_shell() {
        let dir = tempfile::tempdir().unwrap();
        let name = "it's here.png";
        std::fs::write(dir.path().join(name), b"bytes").unwrap();
        let path = dir.path().join(name).to_string_lossy().into_owned();
        let run = |command: String| {
            std::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .output()
                .unwrap()
        };
        let out = run(remote_read_command(&path, None).unwrap());
        assert!(out.status.success());
        assert_eq!(out.stdout, b"bytes");
        let cd = format!("cd -- {}", sh_quote(&dir.path().to_string_lossy()));
        let out = run(remote_read_command(name, Some(&cd)).unwrap());
        assert_eq!(out.stdout, b"bytes");
        let out = run(remote_read_command("/nonexistent/x.png", None).unwrap());
        assert!(!out.status.success());
    }

    #[test]
    fn marks_cover_each_reference_once() {
        let width = 20;
        let rows: Vec<RowCells> = [
            "see /tmp/a.png ok   ",
            "xx /tmp/long/path/to",
            "/b.png and c.txt",
        ]
        .iter()
        .map(|r| RowCells::from_str(r))
        .collect();
        let spans = reference_marks(&rows, width, |_| Some(0));
        assert_eq!(
            spans,
            vec![
                MarkSpan { row: 0, start_col: 4, end_col: 14 },
                MarkSpan { row: 1, start_col: 3, end_col: 20 },
                // Found alone and as the end of the joined path; drawn once.
                MarkSpan { row: 2, start_col: 0, end_col: 6 },
            ]
        );
        assert!(reference_marks(&rows, width, |_| None).is_empty());
    }

    fn sent(rows: &[&str]) -> Vec<Vec<String>> {
        let rows: Vec<RowCells> = rows.iter().map(|r| RowCells::from_str(r)).collect();
        find_sent_files(&rows)
            .into_iter()
            .map(|readings| readings.iter().map(SentPath::text).collect())
            .collect()
    }

    #[test]
    fn a_sent_file_is_read_whatever_its_name_ends_in() {
        assert_eq!(
            sent(&["  \u{203a} [file]/home/b/site/week-02-lab.pdf (306.3 KB)"]),
            vec![vec!["/home/b/site/week-02-lab.pdf".to_string()]]
        );
        assert_eq!(
            sent(&["[file]~/out/data.csv (775 bytes)", "", "  [file]/x/Makefile (12 bytes)"]),
            vec![vec!["~/out/data.csv".to_string()], vec!["/x/Makefile".to_string()]]
        );
        // Spaces and parentheses in the name stay in the path; only the
        // last parenthesis that reads as a size is the size.
        assert_eq!(
            sent(&["  [file]/x/My Report (final) (2).docx (1.2 MB)"]),
            vec![vec!["/x/My Report (final) (2).docx".to_string()]]
        );
        // No size printed: the rest of the row is the path.
        assert_eq!(sent(&["  [file]/x/a b.txt  "]), vec![vec!["/x/a b.txt".to_string()]]);

        let rows = vec![RowCells::from_str("  \u{203a} [file]/x/y.pdf (9 bytes)")];
        let found = find_sent_files(&rows);
        assert_eq!(found[0][0].positions.first(), Some(&(0, 10)));
        assert_eq!(found[0][0].positions.last(), Some(&(0, 17)));
        let reference = found[0][0].reference();
        assert_eq!(reference.kind, ReferenceKind::Sent);
        assert_eq!(reference.end, 8);
        assert_eq!(reference.candidates, vec![Candidate { start: 0, text: "/x/y.pdf".to_string() }]);
        // An image or a file to edit that is sent keeps its own kind.
        let kind = |row: &str| find_sent_files(&[RowCells::from_str(row)])[0][0].reference().kind;
        assert_eq!(kind("[file]/x/fig.PNG (9 KB)"), ReferenceKind::Image);
        assert_eq!(kind("[file]/x/p.edit.md (9 KB)"), ReferenceKind::Edit);
    }

    #[test]
    fn a_mention_of_the_marker_is_not_a_sent_file() {
        assert!(sent(&["  follows the [file] marker as a reference of any type"]).is_empty());
        assert!(sent(&["see [file]/tmp/x.pdf (9 bytes)"]).is_empty());
        assert!(sent(&["  [file] /tmp/x.pdf (9 bytes)"]).is_empty());
        assert!(sent(&["  [file]relative.pdf (9 bytes)"]).is_empty());
        assert!(sent(&["  [file]", "[file", ""]).is_empty());
    }

    #[test]
    fn a_wrapped_sent_file_keeps_the_size_out_of_the_path() {
        // As Claude Code 2.1 drew it in a 114 column pane on 2026-11-20,
        // narrowed: the path wraps inside its column, cut inside a word,
        // and the size inside the column to its right.
        let rows = [
            "\u{25cf} Probe: the same page again",
            "",
            "  \u{203a} [file]/tmp/claude/scratchpa (775",
            "          d/loupe-sent.html     bytes)",
            "",
            "\u{25cf} One fact first",
        ];
        assert_eq!(
            sent(&rows),
            vec![vec![
                "/tmp/claude/scratchpad/loupe-sent.html".to_string(),
                "/tmp/claude/scratchpa".to_string(),
            ]]
        );
        let cells: Vec<RowCells> = rows.iter().map(|r| RowCells::from_str(r)).collect();
        let whole = &find_sent_files(&cells)[0][0];
        assert_eq!(whole.positions.first(), Some(&(2, 10)));
        assert_eq!(whole.positions[20], (2, 30));
        assert_eq!(whole.positions[21], (3, 10));
        assert_eq!(whole.positions.last(), Some(&(3, 26)));

        // Three rows of path, the size closed on the second.
        assert_eq!(
            sent(&[
                "  [file]/aaaaaaaa (775",
                "        bbbbbbbbb bytes)",
                "        cc.pdf",
                "  next line of the reply",
            ])[0][0],
            "/aaaaaaaabbbbbbbbbcc.pdf"
        );
        // The size on one row beside a path that wraps.
        assert_eq!(
            sent(&["  [file]/aaaaaaaa (775 bytes)", "        bb.pdf"])[0],
            vec!["/aaaaaaaabb.pdf".to_string(), "/aaaaaaaa".to_string()]
        );
        // A path that does not fill its column does not go on below, and
        // text below that is not in its column is not part of it.
        assert_eq!(
            sent(&["  [file]/a.pdf     (775", "        more text  bytes)"])[0],
            vec!["/a.pdf".to_string()]
        );
        assert_eq!(
            sent(&["  [file]/aaaaaaaa (775 bytes)", "  the reply goes on here"])[0],
            vec!["/aaaaaaaa".to_string()]
        );
        assert_eq!(
            sent(&["  [file]/aaaaaaaa (775 bytes)", "          indented.pdf"])[0],
            vec!["/aaaaaaaa".to_string()]
        );
        // The next sent file is its own line.
        assert_eq!(
            sent(&["  [file]/aaaaaaaa (775 bytes)", "  [file]/b.pdf (9 bytes)"]),
            vec![vec!["/aaaaaaaa".to_string()], vec!["/b.pdf".to_string()]]
        );
    }

    #[test]
    fn sizes_are_told_from_names() {
        let size = |s: &str| is_size_start(&s.chars().collect::<Vec<char>>());
        for yes in ["775 bytes)", "306.3 KB)", "1,024 KB)", "775", "1.2", "12 M", "9B)"] {
            assert!(size(yes), "{yes}");
        }
        for no in ["", "final)", "2).docx", "1) and more", "v2 draft)", "775 bytes) x"] {
            assert!(!size(no), "{no}");
        }
    }

    #[test]
    fn sent_files_are_marked_by_the_reading_that_opens() {
        let rows: Vec<RowCells> = [
            "  [file]/aaaaaaaa (775",
            "        bb.pdf    bytes)",
            "see /tmp/a.png",
        ]
        .iter()
        .map(|r| RowCells::from_str(r))
        .collect();
        // The whole path exists: both rows of it are marked, the size not.
        let spans = reference_marks(&rows, 40, |r| {
            (r.candidates[0].text == "/aaaaaaaabb.pdf" || r.kind == ReferenceKind::Image).then(|| 0)
        });
        assert_eq!(
            spans,
            vec![
                MarkSpan { row: 0, start_col: 8, end_col: 17 },
                MarkSpan { row: 1, start_col: 8, end_col: 14 },
                MarkSpan { row: 2, start_col: 4, end_col: 14 },
            ]
        );
        // Only the first row's reading exists: only it is marked.
        let spans = reference_marks(&rows, 40, |r| (r.candidates[0].text == "/aaaaaaaa").then(|| 0));
        assert_eq!(spans, vec![MarkSpan { row: 0, start_col: 8, end_col: 17 }]);
        // Neither exists: no mark.
        assert!(reference_marks(&rows, 40, |r| (r.kind != ReferenceKind::Sent).then(|| 0))
            .iter()
            .all(|span| span.row == 2));
    }

    #[test]
    fn sent_files_resolve_and_open_by_how_they_were_found() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("week 2 (lab).pdf");
        std::fs::write(&file, b"x").unwrap();
        // The finder's own check refuses a name that is not a reference;
        // a sent file is found whatever its name.
        assert_eq!(resolve_local_path("week 2 (lab).pdf", Some(dir.path()), None), None);
        assert_eq!(local_file("week 2 (lab).pdf", Some(dir.path()), None), Some(file.clone()));
        assert_eq!(local_file("~/week 2 (lab).pdf", None, Some(dir.path())), Some(file.clone()));
        assert_eq!(local_file("missing.pdf", Some(dir.path()), None), None);
        assert_eq!(local_file(&dir.path().to_string_lossy(), None, None), None, "a folder is not a file");

        assert_eq!(ImageSource::SentFile(file.clone()).kind(), ReferenceKind::Sent);
        assert_eq!(ImageSource::SentFile(PathBuf::from("/x/a.png")).kind(), ReferenceKind::Sent);
        assert!(!ImageSource::SentFile(file.clone()).is_remote());
        assert!(matches!(load_source(&ImageSource::SentFile(file)), Ok(LoadState::Found)));
        assert!(load_source(&ImageSource::SentFile(dir.path().join("gone.pdf"))).is_err());

        let remote = ImageSource::SentRemote {
            ssh: strings(&["ssh", "imac"]),
            check: remote_test_command("/x/it's.pdf", None).unwrap(),
            command: remote_cat_command("/x/it's.pdf", None).unwrap(),
            path: "/x/it's.pdf".to_string(),
        };
        assert_eq!(remote.kind(), ReferenceKind::Sent);
        assert!(remote.is_remote());
        let copy = remote_copy_path(Path::new("/c"), &remote, "/x/it's.pdf");
        assert!(copy.starts_with("/c/Loupe/sent"));
        assert_eq!(copy.file_name().unwrap(), "it's.pdf", "the copy keeps its name, so its type");
    }

    #[test]
    fn a_remote_sent_file_is_tested_for_without_reading_it() {
        assert_eq!(
            remote_test_command("/tmp/it's.pdf", None).unwrap(),
            "f='/tmp/it'\\''s.pdf' && test -f \"$f\""
        );
        assert_eq!(
            remote_test_command("~/a b.docx", None).unwrap(),
            "f=\"$HOME\"/'a b.docx' && test -f \"$f\""
        );
        assert_eq!(remote_test_command("out/x.csv", None), None);
        assert_eq!(
            remote_cat_command("out/x.csv", Some("cd /w")).unwrap(),
            "cd /w && f='out/x.csv' && test -f \"$f\" && exec cat -- \"$f\""
        );

        let dir = tempfile::tempdir().unwrap();
        let name = "it's a (draft).docx";
        std::fs::write(dir.path().join(name), b"bytes").unwrap();
        let path = dir.path().join(name).to_string_lossy().into_owned();
        let run = |command: String| {
            std::process::Command::new("sh")
                .arg("-c")
                .arg(command)
                .output()
                .unwrap()
        };
        let out = run(remote_test_command(&path, None).unwrap());
        assert!(out.status.success());
        assert!(out.stdout.is_empty(), "the test writes nothing");
        assert_eq!(run(remote_cat_command(&path, None).unwrap()).stdout, b"bytes");
        assert!(!run(remote_test_command("/nonexistent/x.docx", None).unwrap()).status.success());
        let folder = dir.path().to_string_lossy().into_owned();
        assert!(!run(remote_test_command(&folder, None).unwrap()).status.success());
    }

    #[test]
    fn remote_copy_keeps_the_name_apart_by_source() {
        let source = |command: &str| ImageSource::Remote {
            ssh: strings(&["ssh", "imac"]),
            command: command.to_string(),
            path: "out/fig 1.png".to_string(),
        };
        let a = remote_copy_path(Path::new("/c"), &source("a"), "out/fig 1.png");
        let b = remote_copy_path(Path::new("/c"), &source("b"), "out/fig 1.png");
        assert_eq!(a.file_name().unwrap(), "fig 1.png");
        assert!(a.starts_with("/c/Loupe/previews"));
        assert_ne!(a, b);
    }

    #[test]
    fn files_to_edit_are_references() {
        assert_eq!(reference_kind("/tmp/p.edit.md"), Some(ReferenceKind::Edit));
        assert_eq!(reference_kind("A.EDIT.MD"), Some(ReferenceKind::Edit));
        assert_eq!(reference_kind("a.png"), Some(ReferenceKind::Image));
        assert_eq!(reference_kind("notes.md"), None);
        assert_eq!(reference_kind("edit.md"), None);
        assert_eq!(reference_kind("a.edit.md.txt"), None);
        assert_eq!(reference_kind("a.editmd"), None);

        let found = |line: &str| -> Vec<(ReferenceKind, Vec<String>)> {
            find_image_references(line)
                .into_iter()
                .map(|r| (r.kind, r.candidates.into_iter().map(|c| c.text).collect()))
                .collect()
        };
        assert_eq!(
            found("Wrote ~/Projects/x/para 3.edit.md."),
            vec![(
                ReferenceKind::Edit,
                vec!["~/Projects/x/para 3.edit.md".to_string(), "3.edit.md".to_string()]
            )]
        );
        assert_eq!(
            found("See notes.md, edit.md.txt, a.edit.md.txt and /tmp/b.png"),
            vec![(ReferenceKind::Image, vec!["/tmp/b.png".to_string()])]
        );
        let refs = find_image_references("Edit `/tmp/ai-med/p2.edit.md` and Read(/tmp/a.png)");
        assert_eq!(refs.len(), 2);
        assert_eq!(refs[0].kind, ReferenceKind::Edit);
        assert_eq!(refs[0].candidates[0].text, "/tmp/ai-med/p2.edit.md");
        assert_eq!(refs[1].kind, ReferenceKind::Image);
        assert!(!refs[1].is_url);
        // A URL is never a file to edit.
        assert!(find_image_references("https://example.com/p.edit.md").is_empty());
    }

    #[test]
    fn files_to_edit_resolve_like_images() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("p 1.edit.md");
        std::fs::write(&file, b"text").unwrap();
        std::fs::write(dir.path().join("p.md"), b"text").unwrap();
        assert_eq!(
            resolve_local_path("p 1.edit.md", Some(dir.path()), None),
            Some(file.clone())
        );
        assert_eq!(resolve_local_path("p.md", Some(dir.path()), None), None);
        assert_eq!(
            remote_read_command("~/p.edit.md", None).unwrap(),
            "f=\"$HOME\"/'p.edit.md' && test -f \"$f\" && exec cat -- \"$f\""
        );
        assert_eq!(ImageSource::File(file).kind(), ReferenceKind::Edit);
        assert_eq!(
            ImageSource::File(PathBuf::from("/a/b.png")).kind(),
            ReferenceKind::Image
        );
        let remote = ImageSource::Remote {
            ssh: strings(&["ssh", "imac"]),
            command: "c".to_string(),
            path: "out/p 1.edit.md".to_string(),
        };
        assert_eq!(remote.kind(), ReferenceKind::Edit);
        let copy = remote_copy_path(Path::new("/c"), &remote, "out/p 1.edit.md");
        assert!(copy.starts_with("/c/Loupe/edits"));
        assert_eq!(copy.file_name().unwrap(), "p 1.edit.md");
    }

    #[test]
    fn edit_request_escapes_its_strings() {
        let file = Path::new("/c/Loupe/edits/0f/it's \"q\".edit.md");
        let shown = "out\\x\n\u{1}\u{e9}.edit.md";
        let json = edit_request_json(7, file, shown, true).unwrap();
        assert_eq!(
            json,
            r#"{"version":1,"pane_id":7,"file":"/c/Loupe/edits/0f/it's \"q\".edit.md","shown":"out\\x\n\u0001é.edit.md","remote":true}"#
        );
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(value["file"], file.to_str().unwrap());
        assert_eq!(value["shown"], shown);
        assert_eq!(value["remote"], true);
        assert!(edit_request_json(7, Path::new("rel/p.edit.md"), "p.edit.md", false).is_err());
    }

    #[test]
    fn edit_requests_get_their_own_files() {
        let cache = tempfile::tempdir().unwrap();
        let file = Path::new("/w/p.edit.md");
        let a = write_edit_request(cache.path(), 3, file, "p.edit.md", false).unwrap();
        let b = write_edit_request(cache.path(), 3, file, "p.edit.md", false).unwrap();
        assert_ne!(a, b);
        let folder = cache.path().join("Loupe").join("edits").join("requests");
        assert_eq!(a.parent().unwrap(), folder);
        assert_eq!(a.extension().unwrap(), EDIT_REQUEST_EXTENSION);
        assert_eq!(
            std::fs::read_to_string(&a).unwrap(),
            edit_request_json(3, file, "p.edit.md", false).unwrap()
        );
        // Only the two requests are left, no partial file.
        assert_eq!(std::fs::read_dir(&folder).unwrap().count(), 2);
    }

    #[test]
    fn decodes_and_scales_down() {
        let mut encoded = std::io::Cursor::new(vec![]);
        image::RgbaImage::from_pixel(4096, 1024, image::Rgba([10, 20, 30, 255]))
            .write_to(&mut encoded, image::ImageFormat::Png)
            .unwrap();
        let (_, width, height) = decode_for_preview(encoded.get_ref()).unwrap();
        assert_eq!((width, height), (2048, 512));
        assert!(decode_for_preview(b"not an image").is_err());
    }
}
