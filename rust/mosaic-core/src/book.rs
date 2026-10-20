//! Photobook planning.
//!
//! The planner turns a set of photos into a sequence of print pages with a visual
//! rhythm: a cover, calm opening spreads, denser middle pages, and quieter endings.
//! It groups photos into events using capture-time gaps, then chooses a page layout
//! based on how many photos belong together.
//!
//! All geometry comes from the same collage engine used by the collage studio, so a
//! page preview and the exported PDF cannot disagree.

use crate::geom::Rect;
use crate::layout::{layout_collage, CollageRequest};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct BookItem {
    pub id: String,
    pub date: f64,
    pub width: u32,
    pub height: u32,
    pub theme: Option<String>,
    pub color: String,
    pub favorite: bool,
    pub quality: f32,
    /// Optional capture location. Distant captures start a new chapter even when
    /// the clock says they belong together.
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// A human-readable place for the chapter, resolved by Swift's on-device cache.
    pub place: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct BookRequest {
    pub items: Vec<BookItem>,
    /// Page width divided by height. 1.414 is A4 portrait.
    pub page_aspect: f32,
    /// Pair pages into facing spreads.
    pub spread: bool,
    /// classic, editorial, or airy.
    pub style: String,
    pub seed: u64,
    pub include_cover: bool,
    pub title: String,
    pub subtitle: String,
    pub max_per_page: usize,
    pub spacing: f32,
    pub padding: f32,
    /// Optional explicit cover photo.
    pub cover_id: Option<String>,
}

impl Default for BookRequest {
    fn default() -> Self {
        Self {
            items: Vec::new(),
            page_aspect: 1.414,
            spread: false,
            style: "editorial".into(),
            seed: 1,
            include_cover: true,
            title: String::new(),
            subtitle: String::new(),
            max_per_page: 6,
            spacing: 0.016,
            padding: 0.03,
            cover_id: None,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct BookCell {
    pub id: String,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub rotation: f32,
    pub z: i32,
    pub focus_x: f32,
    pub focus_y: f32,
}

#[derive(Clone, Debug, Serialize)]
pub struct BookPage {
    pub index: usize,
    pub kind: String,
    pub title: String,
    pub subtitle: String,
    pub event_index: Option<usize>,
    pub start_date: Option<f64>,
    pub end_date: Option<f64>,
    pub layout: String,
    pub spread_index: usize,
    /// left, right, or single.
    pub side: String,
    pub cells: Vec<BookCell>,
}

#[derive(Clone, Debug, Serialize)]
pub struct BookEvent {
    pub index: usize,
    pub title: String,
    pub start_date: f64,
    pub end_date: f64,
    pub item_count: usize,
    pub page_start: usize,
    pub page_count: usize,
    pub place: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct BookPlan {
    pub title: String,
    pub subtitle: String,
    pub page_aspect: f32,
    pub spread: bool,
    pub seed: u64,
    pub page_count: usize,
    pub photo_count: usize,
    pub events: Vec<BookEvent>,
    pub pages: Vec<BookPage>,
}

const HOUR: f64 = 3_600.0;
const DAY: f64 = 86_400.0;

pub fn plan_book(request: &BookRequest) -> Result<BookPlan, String> {
    let mut items: Vec<BookItem> = request
        .items
        .iter()
        .filter(|item| !item.id.is_empty() && item.date.is_finite())
        .cloned()
        .collect();
    items.sort_by(|left, right| {
        left.date
            .partial_cmp(&right.date)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.id.cmp(&right.id))
    });
    let page_aspect = if request.page_aspect.is_finite() {
        request.page_aspect.clamp(0.55, 2.0)
    } else {
        1.414
    };
    let style = match request.style.to_ascii_lowercase().as_str() {
        "classic" => "classic",
        "airy" => "airy",
        _ => "editorial",
    };
    let max_per_page = request.max_per_page.clamp(1, 9);
    let spacing = request.spacing.clamp(0.0, 0.05);
    let padding = request.padding.clamp(0.0, 0.1);

    let groups = group_events(&items);
    let mut pages: Vec<BookPage> = Vec::new();
    let mut events: Vec<BookEvent> = Vec::new();

    if request.include_cover && !items.is_empty() {
        let explicit = request
            .cover_id
            .as_deref()
            .and_then(|id| items.iter().find(|item| item.id == id));
        let best = explicit.unwrap_or_else(|| {
            items
                .iter()
                .max_by(|left, right| {
                    quality(left)
                        .partial_cmp(&quality(right))
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then_with(|| right.id.cmp(&left.id))
                })
                .expect("items is non-empty")
        });
        let rects = page_rects(1, page_aspect, "grid", request.seed, spacing, padding);
        let cells = rects
            .into_iter()
            .map(|rect| cell(rect, best.id.clone(), "cover"))
            .collect();
        pages.push(BookPage {
            index: 0,
            kind: "cover".into(),
            title: request.title.trim().to_string(),
            subtitle: request.subtitle.trim().to_string(),
            event_index: None,
            start_date: Some(items[0].date),
            end_date: Some(items[items.len() - 1].date),
            layout: "cover".into(),
            spread_index: 0,
            side: "single".into(),
            cells,
        });
    }

    for (event_index, group) in groups.iter().enumerate() {
        let title = event_title(group);
        let start_date = group[0].date;
        let end_date = group[group.len() - 1].date;
        let first_page = pages.len();
        let mut cursor = 0usize;
        let mut rhythm_index = 0usize;
        while cursor < group.len() {
            let remaining = group.len() - cursor;
            let target = rhythm_size(style, rhythm_index, event_index) as usize;
            rhythm_index += 1;
            let size = target.clamp(1, max_per_page).min(remaining);
            // Avoid leaving a lonely final photo when the previous page can absorb it.
            let size = if remaining > size && remaining - size == 1 && size < max_per_page {
                size + 1
            } else {
                size
            };
            let chunk = &group[cursor..cursor + size];
            let layout = page_style(size, page_aspect, style, rhythm_index);
            let rects = page_rects(
                size,
                page_aspect,
                layout,
                request.seed.wrapping_add((pages.len() as u64) * 7919),
                spacing,
                padding,
            );
            let cells: Vec<BookCell> = rects
                .into_iter()
                .enumerate()
                .filter_map(|(cell_index, rect)| {
                    chunk.get(cell_index).map(|item| {
                        let mut cell = cell(rect, item.id.clone(), "photo");
                        // The first cell of an editorial page is the visual anchor.
                        if cell_index == 0 && size >= 3 {
                            cell.z = 1;
                        }
                        cell
                    })
                })
                .collect();
            pages.push(BookPage {
                index: pages.len(),
                kind: "page".into(),
                title: if cursor == 0 {
                    title.clone()
                } else {
                    String::new()
                },
                subtitle: if cursor == 0 {
                    String::new()
                } else {
                    String::new()
                },
                event_index: Some(event_index),
                start_date: Some(chunk[0].date),
                end_date: Some(chunk[chunk.len() - 1].date),
                layout: layout.to_string(),
                spread_index: 0,
                side: "single".into(),
                cells,
            });
            cursor += size;
        }
        let (place, latitude, longitude) = event_location(group);
        events.push(BookEvent {
            index: event_index,
            title,
            start_date,
            end_date,
            item_count: group.len(),
            page_start: first_page,
            page_count: pages.len() - first_page,
            place,
            latitude,
            longitude,
        });
    }

    // Assign spreads after the page sequence is final. A cover always stands alone;
    // interior pages pair left/right. An odd final page is a quiet single.
    let mut spread_index = 0usize;
    let mut cursor = 0usize;
    while cursor < pages.len() {
        if pages[cursor].kind == "cover" {
            pages[cursor].spread_index = 0;
            pages[cursor].side = "single".into();
            cursor += 1;
            spread_index = 1;
            continue;
        }
        if request.spread {
            if cursor + 1 < pages.len() {
                pages[cursor].spread_index = spread_index;
                pages[cursor].side = "left".into();
                pages[cursor + 1].spread_index = spread_index;
                pages[cursor + 1].side = "right".into();
                cursor += 2;
            } else {
                pages[cursor].spread_index = spread_index;
                pages[cursor].side = "single".into();
                cursor += 1;
            }
        } else {
            pages[cursor].spread_index = spread_index;
            pages[cursor].side = "single".into();
            cursor += 1;
        }
        spread_index += 1;
    }

    Ok(BookPlan {
        title: request.title.clone(),
        subtitle: request.subtitle.clone(),
        page_aspect,
        spread: request.spread,
        seed: request.seed,
        page_count: pages.len(),
        photo_count: items.len(),
        events,
        pages,
    })
}

/// Group photos by capture-time gaps. A gap of more than 20 hours starts a new
/// event; unusually large events are also split by calendar day so a multi-year
/// upload without gaps does not become one endless chapter.
fn group_events(items: &[BookItem]) -> Vec<Vec<BookItem>> {
    let mut groups: Vec<Vec<BookItem>> = Vec::new();
    let mut current: Vec<BookItem> = Vec::new();
    let mut last_date = f64::NEG_INFINITY;
    for item in items {
        let gap = item.date - last_date;
        let day_change = current
            .first()
            .map(|first| same_day(first.date, item.date) == false)
            .unwrap_or(false);
        let location_jump = current
            .last()
            .and_then(|previous| distance_between(previous, item))
            .map(|meters| meters > 45_000.0)
            .unwrap_or(false);
        let start_new = !current.is_empty()
            && (gap > 20.0 * HOUR
                || (day_change && current.len() >= 28)
                || current.len() >= 60
                || location_jump);
        if start_new {
            groups.push(std::mem::take(&mut current));
        }
        current.push(item.clone());
        last_date = item.date;
    }
    if !current.is_empty() {
        groups.push(current);
    }
    groups
}

fn same_day(left: f64, right: f64) -> bool {
    (left / DAY).floor() == (right / DAY).floor()
}

fn event_title(group: &[BookItem]) -> String {
    let threshold = (group.len() as f32 * 0.45).ceil() as usize;

    // A place is more useful than a generic scene label for a chapter title, but
    // only when most of the chapter actually happened there.
    let mut places: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for item in group {
        if let Some(place) = item.place.as_deref() {
            if !place.is_empty() {
                *places.entry(place).or_default() += 1;
            }
        }
    }
    if let Some((place, count)) = places
        .into_iter()
        .max_by(|left, right| left.1.cmp(&right.1).then_with(|| right.0.cmp(left.0)))
    {
        if count >= threshold {
            return place.to_string();
        }
    }

    let mut themes: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for item in group {
        if let Some(theme) = item.theme.as_deref() {
            if !theme.is_empty() && theme != "Everyday" {
                *themes.entry(theme).or_default() += 1;
            }
        }
    }
    themes
        .into_iter()
        .max_by(|left, right| left.1.cmp(&right.1).then_with(|| right.0.cmp(left.0)))
        .filter(|(_, count)| *count >= threshold)
        .map(|(theme, _)| theme.to_string())
        .unwrap_or_default()
}

fn event_location(group: &[BookItem]) -> (Option<String>, Option<f64>, Option<f64>) {
    let mut places: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    let mut latitude = 0.0;
    let mut longitude = 0.0;
    let mut located = 0usize;
    for item in group {
        if let Some(place) = item.place.as_deref() {
            if !place.is_empty() {
                *places.entry(place).or_default() += 1;
            }
        }
        if let (Some(lat), Some(lon)) = (item.latitude, item.longitude) {
            if lat.is_finite() && lon.is_finite() {
                latitude += lat;
                longitude += lon;
                located += 1;
            }
        }
    }
    let place = places
        .into_iter()
        .max_by(|left, right| left.1.cmp(&right.1).then_with(|| right.0.cmp(left.0)))
        .map(|(place, _)| place.to_string());
    if located > 0 {
        (
            place,
            Some(latitude / located as f64),
            Some(longitude / located as f64),
        )
    } else {
        (place, None, None)
    }
}

/// Great-circle distance in metres. Equirectangular is accurate enough at the
/// chapter scale and avoids trigonometry in the common case.
fn distance_between(left: &BookItem, right: &BookItem) -> Option<f64> {
    let (lat1, lon1) = (left.latitude?, left.longitude?);
    let (lat2, lon2) = (right.latitude?, right.longitude?);
    if !lat1.is_finite() || !lon1.is_finite() || !lat2.is_finite() || !lon2.is_finite() {
        return None;
    }
    let mean_latitude = ((lat1 + lat2) / 2.0).to_radians();
    let dx = (lon2 - lon1) * mean_latitude.cos() * 111_320.0;
    let dy = (lat2 - lat1) * 110_540.0;
    Some((dx * dx + dy * dy).sqrt())
}

fn quality(item: &BookItem) -> f32 {
    let megapixels = (item.width as f32 * item.height as f32) / 1_000_000.0;
    let resolution = (megapixels.max(0.1).log10() / 1.3).clamp(0.0, 1.0);
    (item.quality * 0.6 + resolution * 0.25 + if item.favorite { 0.15 } else { 0.0 })
        .clamp(0.0, 1.0)
}

fn rhythm_size(style: &str, index: usize, event_index: usize) -> usize {
    let pattern: &[usize] = match style {
        "classic" => &[4, 3, 2, 4, 3, 2],
        "airy" => &[2, 1, 2, 3, 1, 2],
        _ => &[1, 3, 2, 4, 2, 5, 3],
    };
    // Every event opens a little quieter than the pattern would otherwise suggest,
    // which gives the book a breathing point between chapters.
    if index == 0 && event_index > 0 {
        pattern[0].min(2)
    } else {
        pattern[index % pattern.len()]
    }
}

fn page_style(count: usize, aspect: f32, style: &str, rhythm: usize) -> &'static str {
    if count <= 1 {
        return "grid";
    }
    match style {
        "classic" => {
            if count == 2 {
                "triptych"
            } else if count == 3 {
                "triptych"
            } else {
                "grid"
            }
        }
        "airy" => {
            if count <= 3 {
                "hero"
            } else {
                "grid"
            }
        }
        _ => match count {
            2 => {
                if aspect > 1.0 {
                    "triptych"
                } else {
                    "hero"
                }
            }
            3 => "triptych",
            4 => "grid",
            5..=9 => {
                if rhythm % 3 == 0 {
                    "hero"
                } else {
                    "mosaic"
                }
            }
            _ => "grid",
        },
    }
}

fn page_rects(
    count: usize,
    aspect: f32,
    style: &str,
    seed: u64,
    spacing: f32,
    padding: f32,
) -> Vec<Rect> {
    let request = CollageRequest {
        count,
        aspect,
        style: style.into(),
        seed,
        spacing,
        padding,
        items: Vec::new(),
    };
    layout_collage(&request)
        .map(|layout| {
            layout
                .cells
                .into_iter()
                .map(|cell| Rect::new(cell.x, cell.y, cell.w, cell.h))
                .collect()
        })
        .unwrap_or_else(|_| vec![Rect::unit()])
}

fn cell(rect: Rect, id: String, role: &str) -> BookCell {
    BookCell {
        id,
        x: rect.x,
        y: rect.y,
        w: rect.w,
        h: rect.h,
        rotation: 0.0,
        z: if role == "cover" { 0 } else { 0 },
        focus_x: 0.5,
        focus_y: 0.5,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(count: usize, spread: bool) -> BookRequest {
        let items = (0..count)
            .map(|index| BookItem {
                id: format!("p{index}"),
                date: 1_700_000_000.0 + index as f64 * 60.0,
                width: 4032,
                height: 3024,
                theme: Some("Nature".into()),
                color: "Green".into(),
                favorite: index % 8 == 0,
                quality: 0.6,
                latitude: None,
                longitude: None,
                place: None,
            })
            .collect();
        BookRequest {
            items,
            spread,
            seed: 5,
            title: "Summer".into(),
            subtitle: "A family book".into(),
            ..Default::default()
        }
    }

    #[test]
    fn every_photo_appears_exactly_once_in_pages() {
        for count in [1usize, 2, 3, 5, 9, 17, 40] {
            let plan = plan_book(&request(count, true)).unwrap();
            let mut ids: Vec<String> = plan
                .pages
                .iter()
                .filter(|page| page.kind == "page")
                .flat_map(|page| page.cells.iter().map(|cell| cell.id.clone()))
                .collect();
            ids.sort();
            let mut expected: Vec<String> = (0..count).map(|index| format!("p{index}")).collect();
            expected.sort();
            assert_eq!(ids, expected, "count {count}");
        }
    }

    #[test]
    fn pages_respect_the_maximum() {
        let mut request = request(30, false);
        request.max_per_page = 4;
        let plan = plan_book(&request).unwrap();
        for page in plan.pages.iter().filter(|page| page.kind == "page") {
            assert!(page.cells.len() <= 4);
            assert!(!page.cells.is_empty());
        }
    }

    #[test]
    fn spreads_pair_interior_pages() {
        let plan = plan_book(&request(12, true)).unwrap();
        for page in plan.pages.iter().filter(|page| page.kind == "page") {
            if page.side == "left" {
                assert!(plan
                    .pages
                    .iter()
                    .any(|other| other.spread_index == page.spread_index && other.side == "right"));
            }
        }
    }

    #[test]
    fn cover_and_titles_survive() {
        let plan = plan_book(&request(5, false)).unwrap();
        assert_eq!(plan.pages[0].kind, "cover");
        assert_eq!(plan.pages[0].title, "Summer");
        assert_eq!(plan.pages[0].subtitle, "A family book");
        assert_eq!(plan.pages[0].cells.len(), 1);
    }

    #[test]
    fn explicit_cover_overrides_quality() {
        let mut request = request(5, false);
        request.cover_id = Some("p3".into());
        let plan = plan_book(&request).unwrap();
        assert_eq!(plan.pages[0].cells[0].id, "p3");
    }

    #[test]
    fn empty_library_is_valid() {
        let plan = plan_book(&BookRequest::default()).unwrap();
        assert_eq!(plan.page_count, 0);
        assert_eq!(plan.photo_count, 0);
        assert!(plan.pages.is_empty());
    }

    #[test]
    fn long_library_paginates_for_50k() {
        let mut request = request(0, false);
        request.items = (0..50_000)
            .map(|index| BookItem {
                id: format!("p{index}"),
                date: 1_600_000_000.0 + index as f64 * 3_600.0,
                width: 4032,
                height: 3024,
                theme: None,
                color: "Blue".into(),
                favorite: false,
                quality: 0.5,
                latitude: None,
                longitude: None,
                place: None,
            })
            .collect();
        let plan = plan_book(&request).unwrap();
        assert_eq!(plan.photo_count, 50_000);
        let total: usize = plan
            .pages
            .iter()
            .filter(|page| page.kind == "page")
            .map(|page| page.cells.len())
            .sum();
        assert_eq!(total, 50_000);
    }
}
