//! Collage layout generation.
//!
//! A layout is a list of normalized rectangles plus a little presentation metadata
//! (rotation and stacking order for the freeform styles). The engine deliberately
//! does not draw anything: SwiftUI previews and the high-resolution exporter share
//! the exact same geometry, so what someone arranges is what they share.

use crate::geom::Rect;
use crate::rng::Rng;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct LayoutItem {
    pub id: String,
    pub width: u32,
    pub height: u32,
    pub date: f64,
    pub favorite: bool,
    pub quality: f32,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct CollageRequest {
    pub count: usize,
    /// Canvas width divided by height. `1.0` is square, `1.5` is a landscape print.
    pub aspect: f32,
    /// grid, hero, magazine, mosaic, filmstrip, scatter, stack, triptych.
    pub style: String,
    pub seed: u64,
    /// Gap between cells as a fraction of canvas width.
    pub spacing: f32,
    /// Outer margin as a fraction of canvas width.
    pub padding: f32,
    pub items: Vec<LayoutItem>,
}

impl Default for CollageRequest {
    fn default() -> Self {
        Self {
            count: 0,
            aspect: 1.0,
            style: "mosaic".into(),
            seed: 1,
            spacing: 0.018,
            padding: 0.025,
            items: Vec::new(),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct CollageCell {
    pub id: Option<String>,
    pub index: usize,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
    pub rotation: f32,
    pub z: i32,
    pub role: String,
    /// Normalized focal point. Swift uses it when the image aspect does not match
    /// the cell, so eyes and horizons are less likely to be cropped away.
    pub focus_x: f32,
    pub focus_y: f32,
}

#[derive(Clone, Debug, Serialize)]
pub struct CollageLayout {
    pub style: String,
    pub aspect: f32,
    pub width: f32,
    pub height: f32,
    pub seed: u64,
    pub cells: Vec<CollageCell>,
}

const STYLES: &[&str] = &[
    "grid",
    "hero",
    "magazine",
    "mosaic",
    "filmstrip",
    "scatter",
    "stack",
    "triptych",
];

pub fn layout_collage(request: &CollageRequest) -> Result<CollageLayout, String> {
    let count = request.count.max(request.items.len()).clamp(1, 80);
    let aspect = if request.aspect.is_finite() {
        request.aspect.clamp(0.4, 2.6)
    } else {
        1.0
    };
    let style = request.style.trim().to_ascii_lowercase();
    let style = if STYLES.contains(&style.as_str()) {
        style
    } else {
        "mosaic".to_string()
    };
    let mut rng = Rng::new(request.seed);
    let spacing = request.spacing.clamp(0.0, 0.06);
    let padding = request.padding.clamp(0.0, 0.14);
    let content = Rect::unit().inset(padding);

    let mut cells: Vec<CollageCell>;
    match style.as_str() {
        "grid" => cells = rects_to_cells(grid_rects(count, aspect), spacing, "cell"),
        "hero" => {
            let rects = hero_rects(count, aspect, &mut rng);
            cells = rects_to_cells(rects, spacing, "cell");
            if let Some(first) = cells.first_mut() {
                first.role = if count == 1 { "cell".into() } else { "hero".into() };
            }
        }
        "magazine" => cells = rects_to_cells(magazine_rects(count, aspect, &mut rng), spacing, "cell"),
        "mosaic" => cells = rects_to_cells(mosaic_rects(count, aspect, &mut rng), spacing, "cell"),
        "filmstrip" => cells = rects_to_cells(filmstrip_rects(count, aspect), spacing, "cell"),
        "scatter" => cells = freeform_rects(count, aspect, &mut rng, false),
        "stack" => cells = freeform_rects(count, aspect, &mut rng, true),
        "triptych" => cells = rects_to_cells(triptych_rects(count), spacing, "cell"),
        _ => unreachable!("style was validated above"),
    }

    // Map the normalized composition into the padded content area. Spacing was
    // applied before this step so outer cells also keep a calm margin.
    for cell in &mut cells {
        cell.x = content.x + cell.x * content.w;
        cell.y = content.y + cell.y * content.h;
        cell.w *= content.w;
        cell.h *= content.h;
    }

    // Stable assignment: the caller decides the order (for hero layouts the first
    // item is the intended hero). Missing items leave the cell as a pleasant blank.
    for (index, cell) in cells.iter_mut().enumerate() {
        cell.index = index;
        cell.id = request.items.get(index).map(|item| item.id.clone());
    }

    Ok(CollageLayout {
        style,
        aspect,
        width: aspect,
        height: 1.0,
        seed: request.seed,
        cells,
    })
}

fn rects_to_cells(rects: Vec<Rect>, spacing: f32, role: &str) -> Vec<CollageCell> {
    let gap = spacing * 0.5;
    rects
        .into_iter()
        .enumerate()
        .map(|(index, rect)| {
            let inner = Rect::new(
                rect.x + gap,
                rect.y + gap,
                (rect.w - gap * 2.0).max(0.001),
                (rect.h - gap * 2.0).max(0.001),
            );
            CollageCell {
                id: None,
                index,
                x: inner.x,
                y: inner.y,
                w: inner.w,
                h: inner.h,
                rotation: 0.0,
                z: index as i32,
                role: role.to_string(),
                focus_x: 0.5,
                focus_y: 0.5,
            }
        })
        .collect()
}

fn freeform_rects(count: usize, aspect: f32, rng: &mut Rng, stacked: bool) -> Vec<CollageCell> {
    let mut cells = Vec::with_capacity(count);
    if stacked {
        // A deck of prints: each card is offset along a golden-angle path and
        // rotated slightly, with the first card on top.
        let card_w = (0.62 * aspect.min(1.4)).clamp(0.45, 0.78);
        let card_h = (card_w / aspect).clamp(0.42, 0.82);
        for index in 0..count {
            let t = index as f32;
            let angle = t * 2.399_963_1;
            let radius = 0.018 * t.sqrt();
            let x = (0.5 - card_w * 0.5 + angle.cos() * radius * 0.12).clamp(0.01, 0.99 - card_w);
            let y = (0.5 - card_h * 0.5 + angle.sin() * radius * 0.12).clamp(0.01, 0.99 - card_h);
            cells.push(CollageCell {
                id: None,
                index,
                x,
                y,
                w: card_w * rng.range(0.96, 1.04),
                h: card_h * rng.range(0.96, 1.04),
                rotation: rng.range(-9.0, 9.0),
                z: (count - index) as i32,
                role: "card".into(),
                focus_x: 0.5,
                focus_y: 0.5,
            });
        }
    } else {
        // Loose prints scattered with a golden-angle spiral, then gently jittered.
        let base = (0.72 / (count as f32).sqrt()).clamp(0.16, 0.46);
        for index in 0..count {
            let t = index as f32 + 0.5;
            let angle = t * 2.399_963_1;
            let radius = (0.46 * (t / count as f32).sqrt()).min(0.45);
            let w = (base * rng.range(0.84, 1.18) * aspect.sqrt()).clamp(0.12, 0.48);
            let h = (base * rng.range(0.84, 1.18) / aspect.sqrt()).clamp(0.12, 0.48);
            let x = (0.5 + angle.cos() * radius - w * 0.5).clamp(0.015, 0.985 - w);
            let y = (0.5 + angle.sin() * radius - h * 0.5).clamp(0.015, 0.985 - h);
            cells.push(CollageCell {
                id: None,
                index,
                x,
                y,
                w,
                h,
                rotation: rng.range(-11.0, 11.0),
                z: index as i32,
                role: "card".into(),
                focus_x: 0.5,
                focus_y: 0.5,
            });
        }
        // Smaller cards sit above larger ones so nothing important is hidden by a
        // large neighbour.
        cells.sort_by(|a, b| {
            (b.w * b.h)
                .partial_cmp(&(a.w * a.h))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        for (z, cell) in cells.iter_mut().enumerate() {
            cell.z = z as i32;
        }
    }
    cells
}

fn grid_rects(count: usize, aspect: f32) -> Vec<Rect> {
    if count == 1 {
        return vec![Rect::unit()];
    }
    let aspect = aspect.max(0.05);
    // Pick columns so cells are close to square: cols/rows ~= canvas aspect.
    let cols = ((count as f32 * aspect).sqrt().round() as usize).clamp(1, count);
    let rows = (count + cols - 1) / cols;
    let mut result = Vec::with_capacity(count);
    for index in 0..count {
        let row = index / cols;
        let in_row = if row + 1 == rows {
            count - row * cols
        } else {
            cols
        };
        let column = index % cols;
        result.push(Rect::new(
            column as f32 / in_row as f32,
            row as f32 / rows as f32,
            1.0 / in_row as f32,
            1.0 / rows as f32,
        ));
    }
    result
}

fn hero_rects(count: usize, aspect: f32, rng: &mut Rng) -> Vec<Rect> {
    if count <= 1 {
        return grid_rects(count, aspect);
    }
    let mut result = Vec::with_capacity(count);
    let hero_share = if count <= 3 { 0.66 } else { 0.58 };
    if aspect >= 1.0 {
        let (hero, rest) = Rect::unit().split_vertical(hero_share);
        result.push(hero);
        result.extend(map_into(rest, grid_rects(count - 1, rest.w / rest.h)));
    } else {
        let (hero, rest) = Rect::unit().split_horizontal(hero_share);
        result.push(hero);
        result.extend(map_into(rest, grid_rects(count - 1, rest.w / rest.h)));
    }
    // A little breathing room between the hero and the supporting grid is handled
    // by spacing. The RNG is intentionally unused here so the hero remains stable.
    let _ = rng;
    result
}

fn magazine_rects(count: usize, aspect: f32, rng: &mut Rng) -> Vec<Rect> {
    if count <= 3 {
        return grid_rects(count, aspect);
    }
    let mut groups: Vec<Vec<usize>> = Vec::new();
    let pattern = if aspect >= 1.0 {
        [2usize, 3, 2, 4, 3, 2, 3]
    } else {
        [1usize, 2, 3, 2, 2, 3, 2]
    };
    let mut cursor = 0;
    let mut pattern_index = 0;
    while cursor < count {
        let mut size = pattern[pattern_index % pattern.len()];
        pattern_index += 1;
        if count - cursor <= 3 {
            size = count - cursor;
        }
        size = size.min(count - cursor);
        groups.push((cursor..cursor + size).collect());
        cursor += size;
    }
    let weights: Vec<f32> = groups
        .iter()
        .map(|group| {
            // Dense rows are allowed to be shorter than solo rows, which keeps the
            // page from reading as one flat grid.
            let density = group.len() as f32;
            (1.0 / density) * 0.75 + 0.32
        })
        .collect();
    let total: f32 = weights.iter().sum();
    let mut result = Vec::with_capacity(count);
    let mut y = 0.0;
    for (group, weight) in groups.iter().zip(weights.iter()) {
        let height = weight / total;
        let mut x = 0.0;
        let widths = varied_widths(group.len(), rng);
        for (slot, width) in widths.iter().enumerate() {
            result.push(Rect::new(x, y, *width, height));
            x += width;
            if slot + 1 == widths.len() {
                // Absorb floating-point drift into the last cell of the row.
                if let Some(last) = result.last_mut() {
                    last.w = (1.0 - last.x).max(0.001);
                }
            }
        }
        y += height;
    }
    result
}

fn varied_widths(count: usize, rng: &mut Rng) -> Vec<f32> {
    if count == 0 {
        return Vec::new();
    }
    let base = [1.35f32, 0.85, 1.05, 1.2, 0.9, 1.1];
    let mut weights: Vec<f32> = (0..count)
        .map(|index| base[(index + rng.below(base.len())) % base.len()] * rng.range(0.94, 1.06))
        .collect();
    let total: f32 = weights.iter().sum();
    for weight in &mut weights {
        *weight /= total;
    }
    weights
}

fn mosaic_rects(count: usize, aspect: f32, rng: &mut Rng) -> Vec<Rect> {
    if count <= 1 {
        return vec![Rect::unit()];
    }
    let mut result = Vec::with_capacity(count);
    split_mosaic(Rect::unit(), count, aspect, rng, &mut result);
    result
}

fn split_mosaic(rect: Rect, count: usize, aspect: f32, rng: &mut Rng, out: &mut Vec<Rect>) {
    if count <= 1 {
        out.push(rect);
        return;
    }
    let left_count = if count == 2 {
        1
    } else {
        let ideal = (count as f32 * rng.range(0.4, 0.6)).round() as usize;
        ideal.clamp(1, count - 1)
    };
    let fraction = (left_count as f32 / count as f32) * rng.range(0.88, 1.12);
    let vertical = if rect.w > rect.h * 1.18 {
        true
    } else if rect.h > rect.w * 1.18 {
        false
    } else {
        rng.unit() < 0.5
    };
    let _ = aspect;
    let (a, b) = if vertical {
        rect.split_vertical(fraction)
    } else {
        rect.split_horizontal(fraction)
    };
    split_mosaic(a, left_count, aspect, rng, out);
    split_mosaic(b, count - left_count, aspect, rng, out);
}

fn filmstrip_rects(count: usize, aspect: f32) -> Vec<Rect> {
    if count <= 2 {
        return grid_rects(count, aspect);
    }
    let top_count = (count + 1) / 2;
    let bottom_count = count - top_count;
    let mut result = Vec::with_capacity(count);
    let bands = if aspect >= 1.0 { 2 } else { 2 };
    for band in 0..bands {
        let band_count = if band == 0 { top_count } else { bottom_count };
        if band_count == 0 {
            continue;
        }
        let y = band as f32 / bands as f32;
        let weights: Vec<f32> = (0..band_count)
            .map(|index| [1.35f32, 0.9, 1.15, 0.85, 1.3, 1.0][index % 6])
            .collect();
        let total: f32 = weights.iter().sum();
        let mut x = 0.0;
        for (index, weight) in weights.iter().enumerate() {
            let width = weight / total;
            result.push(Rect::new(x, y, width, 1.0 / bands as f32));
            x += width;
            if index + 1 == weights.len() {
                if let Some(last) = result.last_mut() {
                    last.w = (1.0 - last.x).max(0.001);
                }
            }
        }
    }
    result
}

fn triptych_rects(count: usize) -> Vec<Rect> {
    if count <= 3 {
        if count == 0 {
            return Vec::new();
        }
        let width = 1.0 / count as f32;
        return (0..count)
            .map(|index| Rect::new(index as f32 * width, 0.0, width, 1.0))
            .collect();
    }
    grid_rects(count, 1.6)
}

fn map_into(container: Rect, rects: Vec<Rect>) -> Vec<Rect> {
    rects
        .into_iter()
        .map(|rect| {
            Rect::new(
                container.x + rect.x * container.w,
                container.y + rect.y * container.h,
                rect.w * container.w,
                rect.h * container.h,
            )
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(style: &str, count: usize, aspect: f32) -> CollageRequest {
        CollageRequest {
            count,
            aspect,
            style: style.into(),
            seed: 77,
            spacing: 0.018,
            padding: 0.025,
            items: Vec::new(),
        }
    }

    #[test]
    fn every_style_fills_and_stays_in_bounds() {
        for style in STYLES {
            for count in 1..=24 {
                for aspect in [0.8f32, 1.0, 1.5] {
                    let layout = layout_collage(&request(style, count, aspect)).unwrap();
                    assert_eq!(layout.cells.len(), count, "{style} {count} {aspect}");
                    for cell in &layout.cells {
                        assert!(cell.x >= -0.001 && cell.y >= -0.001, "{style} {count}");
                        assert!(cell.x + cell.w <= 1.001, "{style} {count}");
                        assert!(cell.y + cell.h <= 1.001, "{style} {count}");
                        assert!(cell.w > 0.0 && cell.h > 0.0, "{style} {count}");
                    }
                }
            }
        }
    }

    #[test]
    fn structured_styles_do_not_overlap() {
        for style in ["grid", "hero", "magazine", "mosaic", "filmstrip", "triptych"] {
            for count in 1..=16 {
                let layout = layout_collage(&request(style, count, 1.2)).unwrap();
                for left in 0..layout.cells.len() {
                    for right in left + 1..layout.cells.len() {
                        let a = Rect::new(
                            layout.cells[left].x,
                            layout.cells[left].y,
                            layout.cells[left].w,
                            layout.cells[left].h,
                        );
                        let b = Rect::new(
                            layout.cells[right].x,
                            layout.cells[right].y,
                            layout.cells[right].w,
                            layout.cells[right].h,
                        );
                        // Spacing insets both cells, so any overlap would indicate a
                        // generator bug rather than intentional layering.
                        assert!(!a.overlaps(b), "{style} {count}: {a:?} overlaps {b:?}");
                    }
                }
            }
        }
    }

    #[test]
    fn structured_styles_cover_most_of_the_canvas() {
        for style in ["grid", "hero", "magazine", "mosaic", "filmstrip", "triptych"] {
            for count in [1usize, 3, 5, 9, 16] {
                let layout = layout_collage(&request(style, count, 1.0)).unwrap();
                let area: f32 = layout.cells.iter().map(|cell| cell.w * cell.h).sum();
                assert!(area > 0.72, "{style} {count} covers {area}");
            }
        }
    }

    #[test]
    fn same_seed_is_deterministic() {
        let a = layout_collage(&request("mosaic", 11, 1.2)).unwrap();
        let b = layout_collage(&request("mosaic", 11, 1.2)).unwrap();
        for (left, right) in a.cells.iter().zip(b.cells.iter()) {
            assert!((left.x - right.x).abs() < f32::EPSILON);
            assert!((left.rotation - right.rotation).abs() < f32::EPSILON);
        }
    }

    #[test]
    fn hero_is_the_first_and_largest_cell() {
        let layout = layout_collage(&request("hero", 7, 1.3)).unwrap();
        let hero = &layout.cells[0];
        assert_eq!(hero.role, "hero");
        let hero_area = hero.w * hero.h;
        for cell in &layout.cells[1..] {
            assert!(cell.w * cell.h < hero_area);
        }
    }

    #[test]
    fn item_ids_follow_the_requested_order() {
        let mut request = request("grid", 3, 1.0);
        request.items = vec![
            LayoutItem {
                id: "a".into(),
                ..Default::default()
            },
            LayoutItem {
                id: "b".into(),
                ..Default::default()
            },
            LayoutItem {
                id: "c".into(),
                ..Default::default()
            },
        ];
        let layout = layout_collage(&request).unwrap();
        let ids: Vec<_> = layout.cells.iter().filter_map(|cell| cell.id.as_deref()).collect();
        assert_eq!(ids, vec!["a", "b", "c"]);
    }
}
