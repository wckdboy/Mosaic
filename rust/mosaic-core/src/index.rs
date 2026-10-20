//! Incremental similarity index, clustering, duplicate discovery, and curation.
//!
//! The app's Swift layer owns persistence and metadata. This module owns the heavy,
//! repeatedly executed work: projecting Apple Vision feature prints into a compact
//! signature, cosine search over tens of thousands of items, locality-sensitive
//! bucketing for near-duplicates, and diversity-aware selection.
//!
//! Design constraints:
//!
//! * 50k items must remain interactive. Features are projected once on insert and
//!   stored as `i8`, giving roughly 200 bytes per item including metadata.
//! * Work is incremental. Upserting one descriptor never rebuilds the library.
//! * Results are deterministic: ties break by identifier, so a redraw never
//!   reshuffles a canvas or a book.
//! * No panic may cross the C boundary. The FFI wrapper catches unwinds.

use crate::rng::{splitmix64, Rng};
use base64::Engine;
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

/// Projected visual feature length. 192 bytes per item is small enough for 50k
/// photos (~10 MB) while preserving enough of Vision's 2048-d vector to rank
/// visually related media reliably.
pub const FEATURE_DIM: usize = 192;
/// Projected semantic/word-vector length.
pub const MEANING_DIM: usize = 96;
/// Fixed projection seed shared by indexing and external queries. Changing it
/// invalidates persisted signatures, so treat it as a cache format version.
const PROJECTION_SEED: u64 = 0x4D4F_5341_4943;
/// Number of LSH bands and bits per band. Four 16-bit bands keep candidate lists
/// tiny even at 50k items (average bucket occupancy well below one).
const LSH_BANDS: usize = 4;
const LSH_BITS: usize = 16;

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default)]
pub struct IndexItem {
    pub id: String,
    /// Original or display filename, used for name grouping.
    pub name: String,
    /// Seconds since the Unix epoch.
    pub date: f64,
    pub width: u32,
    pub height: u32,
    pub favorite: bool,
    pub kind: String,
    pub color: String,
    pub theme: Option<String>,
    pub labels: Vec<String>,
    /// Perceptual difference hash, encoded as a decimal string to avoid JSON's
    /// 53-bit integer limit.
    pub hash: String,
    /// Base64 of Vision's quantized Int8 feature print.
    pub feature: Option<String>,
    /// Base64 of the averaged word-embedding vector.
    pub meaning: Option<String>,
    pub palette: Vec<u32>,
    pub quality: f32,
    pub detailed: bool,
    pub source_modified: Option<f64>,
}

#[derive(Clone, Debug)]
struct StoredItem {
    meta: IndexItem,
    feature: Option<Vec<i8>>,
    meaning: Option<Vec<i8>>,
    #[allow(dead_code)]
    hash: u64,
    quality: f32,
    bands: [u16; LSH_BANDS],
}

impl StoredItem {
    fn new(mut meta: IndexItem) -> Self {
        let feature = meta
            .feature
            .as_deref()
            .and_then(decode_feature)
            .and_then(|feature| project(&feature, FEATURE_DIM, PROJECTION_SEED));
        let meaning = meta
            .meaning
            .as_deref()
            .and_then(decode_feature)
            .and_then(|meaning| project(&meaning, MEANING_DIM, PROJECTION_SEED ^ 0xA5A5_5A5A));
        let hash = meta.hash.parse::<u64>().unwrap_or(0);
        let quality = if meta.quality.is_finite() {
            meta.quality.clamp(0.0, 1.0)
        } else {
            default_quality(&meta)
        };
        let bands = feature.as_deref().map(band_keys).unwrap_or([0; LSH_BANDS]);
        // Drop the base64 payloads; keeping them would double memory for 50k items.
        meta.feature = None;
        meta.meaning = None;
        Self {
            meta,
            feature,
            meaning,
            hash,
            quality,
            bands,
        }
    }

    fn has_feature(&self) -> bool {
        self.feature.is_some()
    }
}

fn default_quality(item: &IndexItem) -> f32 {
    let megapixels = (item.width as f32 * item.height as f32) / 1_000_000.0;
    let resolution = (megapixels.max(0.1).log10() / 1.3).clamp(0.0, 1.0);
    let labels = (item.labels.len() as f32 / 8.0).clamp(0.0, 1.0);
    let detailed = if item.detailed { 0.08 } else { 0.0 };
    (resolution * 0.52 + labels * 0.15 + detailed).clamp(0.0, 1.0)
}

fn decode_feature(encoded: &str) -> Option<Vec<i8>> {
    if encoded.is_empty() {
        return None;
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .or_else(|_| base64::engine::general_purpose::STANDARD_NO_PAD.decode(encoded))
        .ok()?;
    if bytes.len() < 8 {
        return None;
    }
    Some(bytes.into_iter().map(|value| value as i8).collect())
}

/// Project a normalized Int8 vector into a shorter, L2-normalized signature with a
/// deterministic sparse random projection. Each input dimension contributes to two
/// outputs, which is several times cheaper than a dense projection matrix while
/// preserving cosine similarity closely enough for ranking and clustering.
fn project(data: &[i8], dimension: usize, seed: u64) -> Option<Vec<i8>> {
    if data.len() < 8 {
        return None;
    }
    let mut accumulator = vec![0.0f32; dimension];
    for (index, value) in data.iter().enumerate() {
        let value = *value as f32;
        if value == 0.0 {
            continue;
        }
        let base = splitmix64(index as u64 ^ seed);
        let slot = (base as usize) % dimension;
        let sign = if base & (1 << 63) != 0 { -1.0 } else { 1.0 };
        accumulator[slot] += value * sign;

        let second = splitmix64(base ^ 0xD1B5_4A32_D192_ED03);
        let slot = (second as usize) % dimension;
        let sign = if second & (1 << 63) != 0 { -1.0 } else { 1.0 };
        accumulator[slot] += value * sign;
    }
    let norm = accumulator.iter().map(|v| v * v).sum::<f32>().sqrt();
    if !norm.is_finite() || norm <= 0.0 {
        return None;
    }
    Some(
        accumulator
            .into_iter()
            .map(|value| ((value / norm) * 127.0).round().clamp(-127.0, 127.0) as i8)
            .collect(),
    )
}

fn band_keys(feature: &[i8]) -> [u16; LSH_BANDS] {
    let mut keys = [0u16; LSH_BANDS];
    for band in 0..LSH_BANDS {
        let mut key = 0u16;
        for bit in 0..LSH_BITS {
            let index = band * LSH_BITS + bit;
            if feature.get(index).copied().unwrap_or(0) > 0 {
                key |= 1 << bit;
            }
        }
        keys[band] = key;
    }
    keys
}

/// Cosine similarity in -1...1 for normalized projections.
fn dot(a: &[i8], b: &[i8]) -> f32 {
    if a.len() != b.len() {
        return -1.0;
    }
    let mut sum = 0i32;
    // Eight independent accumulators let LLVM vectorize the loop and break the
    // serial dependency chain on `sum`.
    let chunks = a.len() / 8;
    let mut lane = [0i32; 8];
    for chunk in 0..chunks {
        let offset = chunk * 8;
        for index in 0..8 {
            lane[index] += (a[offset + index] as i32) * (b[offset + index] as i32);
        }
    }
    for value in lane {
        sum += value;
    }
    for index in chunks * 8..a.len() {
        sum += (a[index] as i32) * (b[index] as i32);
    }
    (sum as f32 / (127.0 * 127.0)).clamp(-1.0, 1.0)
}

fn combined_similarity(left: &StoredItem, right: &StoredItem) -> f32 {
    let visual = match (&left.feature, &right.feature) {
        (Some(a), Some(b)) => dot(a, b),
        _ => -1.0,
    };
    let semantic = match (&left.meaning, &right.meaning) {
        (Some(a), Some(b)) => dot(a, b),
        _ => -1.0,
    };
    match (visual >= 0.0, semantic >= 0.0) {
        (true, true) => visual * 0.82 + semantic * 0.18,
        (true, false) => visual,
        (false, true) => semantic,
        (false, false) => -1.0,
    }
}

fn visual_similarity(left: &StoredItem, right: &StoredItem) -> f32 {
    match (&left.feature, &right.feature) {
        (Some(a), Some(b)) => dot(a, b),
        _ => -1.0,
    }
}

#[derive(Default)]
struct IndexData {
    slots: Vec<Option<StoredItem>>,
    positions: HashMap<String, usize>,
    free: Vec<usize>,
    inserted: u64,
    removed: u64,
    updated: u64,
}

impl IndexData {
    fn active(&self) -> impl Iterator<Item = (usize, &StoredItem)> {
        self.slots
            .iter()
            .enumerate()
            .filter_map(|(index, item)| item.as_ref().map(|item| (index, item)))
    }

    fn upsert(&mut self, meta: IndexItem) -> bool {
        let existing = self.positions.get(&meta.id).copied();
        if let Some(index) = existing {
            self.slots[index] = Some(StoredItem::new(meta));
            self.updated += 1;
            true
        } else {
            let stored = StoredItem::new(meta.clone());
            let index = if let Some(index) = self.free.pop() {
                self.slots[index] = Some(stored);
                index
            } else {
                self.slots.push(Some(stored));
                self.slots.len() - 1
            };
            self.positions.insert(meta.id, index);
            self.inserted += 1;
            false
        }
    }

    fn remove(&mut self, id: &str) -> bool {
        if let Some(index) = self.positions.remove(id) {
            self.slots[index] = None;
            self.free.push(index);
            self.removed += 1;
            true
        } else {
            false
        }
    }
}

pub struct MosaicIndex {
    inner: Mutex<IndexData>,
}

impl Default for MosaicIndex {
    fn default() -> Self {
        Self::new()
    }
}

impl MosaicIndex {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(IndexData::default()),
        }
    }

    pub fn upsert(&self, items: Vec<IndexItem>) -> Result<UpsertResult, String> {
        let mut data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        let mut added = 0usize;
        let mut updated = 0usize;
        for item in items {
            if item.id.is_empty() {
                continue;
            }
            if data.upsert(item) {
                updated += 1;
            } else {
                added += 1;
            }
        }
        Ok(UpsertResult {
            count: data.positions.len(),
            added,
            updated,
        })
    }

    pub fn remove(&self, ids: &[String]) -> Result<usize, String> {
        let mut data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        Ok(ids.iter().filter(|id| data.remove(id)).count())
    }

    pub fn clear(&self) -> Result<(), String> {
        let mut data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        *data = IndexData::default();
        Ok(())
    }

    pub fn len(&self) -> usize {
        self.inner
            .lock()
            .map(|data| data.positions.len())
            .unwrap_or(0)
    }

    pub fn stats(&self) -> Result<Stats, String> {
        let data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        let count = data.positions.len();
        let mut analyzed = 0;
        let mut semantic = 0;
        let mut quality = 0.0f32;
        let mut dates = Vec::with_capacity(count);
        for (_, item) in data.active() {
            if item.has_feature() {
                analyzed += 1;
            }
            if item.meaning.is_some() {
                semantic += 1;
            }
            quality += item.quality;
            if item.meta.date.is_finite() {
                dates.push(item.meta.date);
            }
        }
        dates.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let bytes = count * (FEATURE_DIM + MEANING_DIM + 260);
        Ok(Stats {
            count,
            analyzed,
            semantic,
            average_quality: if count == 0 {
                0.0
            } else {
                quality / count as f32
            },
            oldest: dates.first().copied(),
            newest: dates.last().copied(),
            feature_dimension: FEATURE_DIM,
            estimated_bytes: bytes,
            inserted: data.inserted,
            updated: data.updated,
            removed: data.removed,
        })
    }

    pub fn query(&self, request: &QueryRequest) -> Result<Vec<QueryResult>, String> {
        let data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        // Stored items already hold projected signatures; external queries arrive as
        // full-length Int8 vectors and are projected once, here.
        let (query_feature, query_meaning) = if let Some(id) = &request.id {
            let stored = data
                .positions
                .get(id)
                .and_then(|index| data.slots[*index].as_ref())
                .ok_or_else(|| format!("unknown item: {id}"))?;
            (stored.feature.clone(), stored.meaning.clone())
        } else {
            let feature = request
                .feature
                .as_deref()
                .and_then(decode_feature)
                .and_then(|feature| project(&feature, FEATURE_DIM, request.projection_seed));
            let meaning = request
                .meaning
                .as_deref()
                .and_then(decode_feature)
                .and_then(|meaning| {
                    project(&meaning, MEANING_DIM, request.projection_seed ^ 0xA5A5_5A5A)
                });
            (feature, meaning)
        };
        if query_feature.is_none() && query_meaning.is_none() {
            return Err("query has no visual or semantic feature".into());
        }
        let limit = request.limit.clamp(1, 5_000);
        let exclude: HashSet<&str> = request.exclude_ids.iter().map(String::as_str).collect();
        let include: Option<HashSet<&str>> = request
            .ids
            .as_ref()
            .map(|ids| ids.iter().map(String::as_str).collect());
        let kinds: Option<HashSet<&str>> = request
            .kinds
            .as_ref()
            .map(|kinds| kinds.iter().map(String::as_str).collect());
        let mut results: Vec<QueryResult> = data
            .active()
            .par_bridge()
            .filter_map(|(_, item)| {
                if request.id.as_deref() == Some(item.meta.id.as_str()) {
                    return None;
                }
                if exclude.contains(item.meta.id.as_str()) {
                    return None;
                }
                if let Some(include) = &include {
                    if !include.contains(item.meta.id.as_str()) {
                        return None;
                    }
                }
                if let Some(kinds) = &kinds {
                    if !kinds.contains(item.meta.kind.as_str()) {
                        return None;
                    }
                }
                if let Some(from) = request.date_from {
                    if item.meta.date < from {
                        return None;
                    }
                }
                if let Some(to) = request.date_to {
                    if item.meta.date > to {
                        return None;
                    }
                }
                let visual = query_feature
                    .as_deref()
                    .and_then(|query| item.feature.as_deref().map(|feature| dot(query, feature)));
                let semantic = query_meaning
                    .as_deref()
                    .and_then(|query| item.meaning.as_deref().map(|meaning| dot(query, meaning)));
                let similarity = match request.mode {
                    QueryMode::Visual => visual.unwrap_or(-1.0),
                    QueryMode::Meaning => semantic.unwrap_or(-1.0),
                    QueryMode::Combined => match (visual, semantic) {
                        (Some(visual), Some(semantic)) => visual * 0.82 + semantic * 0.18,
                        (Some(visual), None) => visual,
                        (None, Some(semantic)) => semantic,
                        (None, None) => -1.0,
                    },
                };
                if !similarity.is_finite() || similarity < request.min_similarity {
                    return None;
                }
                Some(QueryResult {
                    id: item.meta.id.clone(),
                    similarity,
                    visual,
                    semantic,
                })
            })
            .collect();
        results.sort_by(|left, right| {
            right
                .similarity
                .partial_cmp(&left.similarity)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| left.id.cmp(&right.id))
        });
        results.truncate(limit);
        Ok(results)
    }

    pub fn clusters(&self, request: &ClusterRequest) -> Result<Vec<Cluster>, String> {
        let data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        let mut items: Vec<(usize, &StoredItem)> = data.active().collect();
        let requested: Option<HashSet<&str>> = request
            .ids
            .as_ref()
            .map(|ids| ids.iter().map(String::as_str).collect());
        if let Some(requested) = &requested {
            items.retain(|(_, item)| requested.contains(item.meta.id.as_str()));
        }
        match request.mode {
            ClusterMode::Color => Ok(cluster_by(
                &items,
                |item| {
                    if item.meta.color.is_empty() {
                        "Not analyzed".to_string()
                    } else {
                        item.meta.color.clone()
                    }
                },
                Some(color_rank),
            )),
            ClusterMode::Theme => Ok(cluster_by(
                &items,
                |item| {
                    item.meta
                        .theme
                        .clone()
                        .filter(|theme| !theme.is_empty())
                        .unwrap_or_else(|| "Not analyzed".into())
                },
                None,
            )),
            ClusterMode::Name => Ok(cluster_by(&items, |item| name_group(&item.meta.name), None)),
            ClusterMode::Similar => Ok(similar_clusters(&items, request.budget, request.threshold)),
        }
    }

    pub fn select(&self, request: &SelectRequest) -> Result<Vec<Selection>, String> {
        let data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        if request.count == 0 {
            return Ok(Vec::new());
        }
        let include: Option<HashSet<&str>> = request
            .ids
            .as_ref()
            .map(|ids| ids.iter().map(String::as_str).collect());
        let exclude: HashSet<&str> = request.exclude_ids.iter().map(String::as_str).collect();
        let kinds: Option<HashSet<&str>> = request
            .kinds
            .as_ref()
            .map(|kinds| kinds.iter().map(String::as_str).collect());
        let mut candidates: Vec<(usize, &StoredItem)> = data
            .active()
            .filter(|(_, item)| {
                if exclude.contains(item.meta.id.as_str()) {
                    return false;
                }
                if let Some(include) = &include {
                    if !include.contains(item.meta.id.as_str()) {
                        return false;
                    }
                }
                if let Some(kinds) = &kinds {
                    if !kinds.contains(item.meta.kind.as_str()) {
                        return false;
                    }
                }
                if let Some(from) = request.date_from {
                    if item.meta.date < from {
                        return false;
                    }
                }
                if let Some(to) = request.date_to {
                    if item.meta.date > to {
                        return false;
                    }
                }
                true
            })
            .collect();
        if candidates.is_empty() {
            return Ok(Vec::new());
        }
        let (oldest, newest) = date_bounds(&candidates);
        let span = (newest - oldest).max(1.0);
        let query_meaning = request
            .query_meaning
            .as_deref()
            .and_then(decode_feature)
            .and_then(|meaning| project(&meaning, MEANING_DIM, PROJECTION_SEED ^ 0xA5A5_5A5A));
        let mut rng = Rng::new(request.seed);
        // A light deterministic shuffle breaks ties between equally good photos
        // (common in bursts) without making the result noisy.
        let jitter: HashMap<usize, f32> = candidates
            .iter()
            .map(|(index, _)| (*index, rng.range(0.0, 0.035)))
            .collect();
        let base_score = |item: &StoredItem| {
            let recency = ((item.meta.date - oldest) / span).clamp(0.0, 1.0);
            let recency_weight = if request.prefer_recent { 0.22 } else { 0.05 };
            let favorite = if item.meta.favorite && request.include_favorites {
                0.24
            } else {
                0.0
            };
            let label_bonus = (item.meta.labels.len() as f32 / 10.0).clamp(0.0, 0.12);
            let semantic_bonus = query_meaning
                .as_deref()
                .and_then(|query| {
                    item.meaning
                        .as_deref()
                        .map(|meaning| dot(query, meaning).max(0.0))
                })
                .unwrap_or(0.0)
                * request.query_weight.clamp(0.0, 1.0);
            (item.quality * 0.58
                + recency as f32 * recency_weight
                + favorite
                + label_bonus
                + semantic_bonus)
                .clamp(0.0, 1.2)
        };
        let prefilter = request
            .prefilter
            .unwrap_or(0)
            .max(request.count.saturating_mul(40))
            .max(1_200)
            .min(candidates.len());
        candidates.sort_by(|(left_index, left), (right_index, right)| {
            let left_score = base_score(left) + jitter.get(left_index).copied().unwrap_or(0.0);
            let right_score = base_score(right) + jitter.get(right_index).copied().unwrap_or(0.0);
            right_score
                .partial_cmp(&left_score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| left.meta.id.cmp(&right.meta.id))
        });
        candidates.truncate(prefilter);

        let count = request.count.min(candidates.len());
        let mut best_similarity = vec![0.0f32; candidates.len()];
        let mut chosen = Vec::with_capacity(count);
        let mut chosen_positions: Vec<usize> = Vec::with_capacity(count);
        let mut chosen_dates: Vec<f64> = Vec::with_capacity(count);
        let mut skipped_similar = 0usize;
        let diversity = request.diversity.clamp(0.0, 1.0);
        let min_gap = request.min_gap_seconds.max(0.0);
        while chosen.len() < count {
            let mut best: Option<(usize, f32, &'static str)> = None;
            for (position, (_, item)) in candidates.iter().enumerate() {
                if chosen_positions.contains(&position) {
                    continue;
                }
                let quality = base_score(item);
                let max_similarity = best_similarity[position];
                let mut score = quality - diversity * max_similarity * 0.72;
                let mut reason = "Strong candidate";
                if item.meta.favorite && request.include_favorites {
                    reason = "Favorite";
                } else if max_similarity < 0.35 && !chosen.is_empty() {
                    reason = "Adds variety";
                } else if item.meta.width as u64 * item.meta.height as u64 >= 8_000_000 {
                    reason = "Detailed frame";
                }
                if min_gap > 0.0
                    && chosen_dates
                        .iter()
                        .any(|date| (item.meta.date - date).abs() < min_gap)
                {
                    score -= 0.18;
                    if reason == "Strong candidate" {
                        reason = "Spaced in time";
                    }
                }
                // Candidate order already encodes quality, so an earlier position
                // wins an exact tie. This keeps selection stable across redraws.
                let is_better = match best {
                    None => true,
                    Some((best_position, best_score, _)) => {
                        score > best_score + 0.0001
                            || ((score - best_score).abs() <= 0.0001 && position < best_position)
                    }
                };
                if is_better {
                    best = Some((position, score, reason));
                }
            }
            let Some((position, score, reason)) = best else {
                break;
            };
            let (_, item) = candidates[position];
            // A near-identical photo from the same second is almost always a burst
            // duplicate. Prefer the higher-quality frame already selected.
            let duplicate = chosen.iter().any(|selected: &Selection| {
                selected.id != item.meta.id && {
                    let other = data
                        .positions
                        .get(&selected.id)
                        .and_then(|index| data.slots[*index].as_ref());
                    other.is_some_and(|other| {
                        (other.meta.date - item.meta.date).abs() <= 4.0
                            && combined_similarity(other, item) >= 0.93
                    })
                }
            });
            if duplicate {
                skipped_similar += 1;
            } else {
                chosen.push(Selection {
                    id: item.meta.id.clone(),
                    score,
                    reason: reason.to_string(),
                });
                chosen_dates.push(item.meta.date);
            }
            chosen_positions.push(position);
            // Update the running diversity distance once, rather than recomputing
            // every pair on every iteration.
            for (other_position, (_, other)) in candidates.iter().enumerate() {
                if chosen_positions.contains(&other_position) {
                    continue;
                }
                let similarity = combined_similarity(item, other).max(0.0);
                if similarity > best_similarity[other_position] {
                    best_similarity[other_position] = similarity;
                }
            }
            if chosen_positions.len() >= candidates.len() {
                break;
            }
        }
        let _ = skipped_similar;
        Ok(chosen)
    }

    pub fn duplicates(&self, request: &DuplicateRequest) -> Result<Vec<DuplicateGroup>, String> {
        let data = self.inner.lock().map_err(|_| "index lock poisoned")?;
        let threshold = request.threshold.clamp(0.5, 0.999);
        let max_gap = request.max_gap_seconds.max(0.0);
        let mut parent: Vec<usize> = (0..data.slots.len()).collect();
        fn find(parent: &mut Vec<usize>, mut value: usize) -> usize {
            while parent[value] != value {
                parent[value] = parent[parent[value]];
                value = parent[value];
            }
            value
        }
        fn union(parent: &mut Vec<usize>, left: usize, right: usize) {
            let left = find(parent, left);
            let right = find(parent, right);
            if left != right {
                parent[right] = left;
            }
        }
        let mut buckets: HashMap<u16, Vec<usize>> =
            HashMap::with_capacity(data.positions.len() / 4);
        let mut best: HashMap<(usize, usize), f32> = HashMap::new();
        let mut matches = 0usize;
        for (index, item) in data.active() {
            if !item.has_feature() {
                continue;
            }
            let mut candidates = Vec::new();
            for band in 0..LSH_BANDS {
                if let Some(bucket) = buckets.get(&item.bands[band]) {
                    for other in bucket {
                        candidates.push(*other);
                    }
                }
            }
            candidates.sort_unstable();
            candidates.dedup();
            for other_index in candidates {
                let Some(other) = data.slots[other_index].as_ref() else {
                    continue;
                };
                if max_gap > 0.0 && (item.meta.date - other.meta.date).abs() > max_gap {
                    continue;
                }
                let similarity = combined_similarity(item, other);
                if similarity >= threshold {
                    union(&mut parent, index, other_index);
                    let key = if index < other_index {
                        (index, other_index)
                    } else {
                        (other_index, index)
                    };
                    best.entry(key)
                        .and_modify(|value| *value = value.max(similarity))
                        .or_insert(similarity);
                    matches += 1;
                }
            }
            for band in 0..LSH_BANDS {
                buckets.entry(item.bands[band]).or_default().push(index);
            }
        }
        if matches == 0 {
            return Ok(Vec::new());
        }
        let mut groups: HashMap<usize, Vec<(usize, &StoredItem)>> = HashMap::new();
        for (index, item) in data.active() {
            if !item.has_feature() {
                continue;
            }
            let root = find(&mut parent, index);
            groups.entry(root).or_default().push((index, item));
        }
        let min_group = request.min_group.max(2);
        let mut result: Vec<DuplicateGroup> = groups
            .into_values()
            .filter(|group| group.len() >= min_group)
            .map(|mut group| {
                group.sort_by(|left, right| {
                    right
                        .1
                        .quality
                        .partial_cmp(&left.1.quality)
                        .unwrap_or(std::cmp::Ordering::Equal)
                        .then_with(|| left.1.meta.id.cmp(&right.1.meta.id))
                });
                let ids = group.iter().map(|(_, item)| item.meta.id.clone()).collect();
                let mut similarity = 0.0f32;
                for left in 0..group.len() {
                    for right in left + 1..group.len() {
                        let key = if group[left].0 < group[right].0 {
                            (group[left].0, group[right].0)
                        } else {
                            (group[right].0, group[left].0)
                        };
                        if let Some(value) = best.get(&key) {
                            similarity = similarity.max(*value);
                        }
                    }
                }
                DuplicateGroup {
                    item_ids: ids,
                    similarity,
                }
            })
            .collect();
        result.sort_by(|left, right| {
            right
                .item_ids
                .len()
                .cmp(&left.item_ids.len())
                .then_with(|| left.item_ids.first().cmp(&right.item_ids.first()))
        });
        result.truncate(request.limit.clamp(1, 2_000));
        Ok(result)
    }
}

fn date_bounds(items: &[(usize, &StoredItem)]) -> (f64, f64) {
    let mut oldest = f64::INFINITY;
    let mut newest = f64::NEG_INFINITY;
    for (_, item) in items {
        if item.meta.date.is_finite() {
            oldest = oldest.min(item.meta.date);
            newest = newest.max(item.meta.date);
        }
    }
    if !oldest.is_finite() || !newest.is_finite() {
        (0.0, 1.0)
    } else {
        (oldest, newest)
    }
}

fn color_rank(color: &str) -> usize {
    const ORDER: &[&str] = &[
        "Red", "Orange", "Brown", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink", "Light",
        "Neutral", "Dark",
    ];
    ORDER
        .iter()
        .position(|candidate| candidate.eq_ignore_ascii_case(color))
        .unwrap_or(ORDER.len())
}

fn cluster_by<F>(
    items: &[(usize, &StoredItem)],
    key: F,
    rank: Option<fn(&str) -> usize>,
) -> Vec<Cluster>
where
    F: Fn(&StoredItem) -> String,
{
    let mut groups: HashMap<String, Vec<&StoredItem>> = HashMap::new();
    for (_, item) in items {
        groups.entry(key(item)).or_default().push(item);
    }
    let mut clusters: Vec<Cluster> = groups
        .into_iter()
        .map(|(title, mut members)| {
            members.sort_by(|left, right| {
                right
                    .meta
                    .date
                    .partial_cmp(&left.meta.date)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| left.meta.id.cmp(&right.meta.id))
            });
            Cluster {
                id: title.clone(),
                title,
                item_ids: members
                    .into_iter()
                    .map(|item| item.meta.id.clone())
                    .collect(),
            }
        })
        .collect();
    clusters.sort_by(|left, right| {
        if left.id == "Not analyzed" {
            return std::cmp::Ordering::Greater;
        }
        if right.id == "Not analyzed" {
            return std::cmp::Ordering::Less;
        }
        match rank {
            Some(rank) => rank(&left.id)
                .cmp(&rank(&right.id))
                .then_with(|| left.title.cmp(&right.title)),
            None => right
                .item_ids
                .len()
                .cmp(&left.item_ids.len())
                .then_with(|| left.title.cmp(&right.title)),
        }
    });
    clusters
}

fn name_group(id: &str) -> String {
    // Files and Photos identifiers usually carry the original filename after a
    // prefix. Keep the first meaningful word so a wall of IMG_1234-style names does
    // not become one giant group.
    let file = id.rsplit('/').next().unwrap_or(id);
    let stem = file.split('.').next().unwrap_or(file);
    let cleaned: String = stem
        .chars()
        .map(|character| {
            if character.is_alphanumeric() {
                character
            } else {
                ' '
            }
        })
        .collect();
    let first = cleaned
        .split_whitespace()
        .find(|word| !word.chars().all(|character| character.is_ascii_digit()));
    first
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => "Other names".into(),
            }
        })
        .unwrap_or_else(|| "Other names".into())
}

fn similar_clusters(items: &[(usize, &StoredItem)], budget: usize, threshold: f32) -> Vec<Cluster> {
    let budget = budget.clamp(2, 240);
    let threshold = threshold.clamp(0.3, 0.95);
    let mut ordered: Vec<&StoredItem> = items
        .iter()
        .filter(|(_, item)| item.has_feature())
        .map(|(_, item)| *item)
        .collect();
    ordered.sort_by(|left, right| {
        right
            .meta
            .date
            .partial_cmp(&left.meta.date)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| left.meta.id.cmp(&right.meta.id))
    });
    let mut leaders: Vec<&StoredItem> = Vec::new();
    let mut groups: Vec<Vec<&StoredItem>> = Vec::new();
    let mut buckets: HashMap<u16, Vec<usize>> = HashMap::new();
    let mut other: Vec<&StoredItem> = Vec::new();
    for item in &ordered {
        let mut candidates = Vec::new();
        for band in 0..LSH_BANDS {
            if let Some(bucket) = buckets.get(&item.bands[band]) {
                candidates.extend(bucket.iter().copied());
            }
        }
        candidates.sort_unstable();
        candidates.dedup();
        let mut best: Option<(usize, f32)> = None;
        for leader_index in candidates {
            let leader = leaders[leader_index];
            let similarity = visual_similarity(item, leader);
            if similarity >= threshold && best.is_none_or(|(_, current)| similarity > current) {
                best = Some((leader_index, similarity));
            }
        }
        if let Some((leader_index, _)) = best {
            groups[leader_index].push(item);
        } else if leaders.len() < budget {
            let leader_index = leaders.len();
            leaders.push(item);
            groups.push(vec![item]);
            for band in 0..LSH_BANDS {
                buckets
                    .entry(item.bands[band])
                    .or_default()
                    .push(leader_index);
            }
        } else {
            other.push(item);
        }
    }
    let mut result: Vec<Cluster> = groups
        .into_iter()
        .enumerate()
        .map(|(index, mut members)| {
            members.sort_by(|left, right| {
                right
                    .meta
                    .date
                    .partial_cmp(&left.meta.date)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| left.meta.id.cmp(&right.meta.id))
            });
            Cluster {
                id: format!("group-{index}"),
                title: cluster_title(&members),
                item_ids: members
                    .into_iter()
                    .map(|item| item.meta.id.clone())
                    .collect(),
            }
        })
        .collect();
    result.sort_by(|left, right| {
        right
            .item_ids
            .len()
            .cmp(&left.item_ids.len())
            .then_with(|| left.id.cmp(&right.id))
    });
    let mut singles = Vec::new();
    result.retain(|cluster| {
        if cluster.item_ids.len() == 1 {
            singles.push(cluster.item_ids[0].clone());
            false
        } else {
            true
        }
    });
    singles.extend(other.into_iter().map(|item| item.meta.id.clone()));
    if !singles.is_empty() {
        result.push(Cluster {
            id: "other".into(),
            title: "Other compositions".into(),
            item_ids: singles,
        });
    }
    if items.iter().any(|(_, item)| !item.has_feature()) {
        let ids = items
            .iter()
            .filter(|(_, item)| !item.has_feature())
            .map(|(_, item)| item.meta.id.clone())
            .collect();
        result.push(Cluster {
            id: "not-analyzed".into(),
            title: "Not analyzed".into(),
            item_ids: ids,
        });
    }
    result
}

fn cluster_title(members: &[&StoredItem]) -> String {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    for item in members.iter().take(64) {
        if let Some(label) = item.meta.labels.first() {
            *counts.entry(label.as_str()).or_default() += 1;
        }
    }
    let color = members
        .first()
        .map(|item| item.meta.color.as_str())
        .unwrap_or("Neutral");
    if let Some((label, _)) = counts
        .into_iter()
        .max_by(|left, right| left.1.cmp(&right.1).then_with(|| right.0.cmp(left.0)))
    {
        return format!("{} · {}", title_case(&label.replace('_', " ")), color);
    }
    let theme = members
        .first()
        .and_then(|item| item.meta.theme.clone())
        .unwrap_or_default();
    if theme.is_empty() || theme == "Everyday" {
        format!("{color} compositions")
    } else {
        format!("{theme} · {color}")
    }
}

fn title_case(value: &str) -> String {
    value
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Clone, Debug, Serialize)]
pub struct UpsertResult {
    pub count: usize,
    pub added: usize,
    pub updated: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct Stats {
    pub count: usize,
    pub analyzed: usize,
    pub semantic: usize,
    pub average_quality: f32,
    pub oldest: Option<f64>,
    pub newest: Option<f64>,
    pub feature_dimension: usize,
    pub estimated_bytes: usize,
    pub inserted: u64,
    pub updated: u64,
    pub removed: u64,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum QueryMode {
    #[default]
    Visual,
    Meaning,
    Combined,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct QueryRequest {
    pub id: Option<String>,
    pub feature: Option<String>,
    pub meaning: Option<String>,
    pub limit: usize,
    pub ids: Option<Vec<String>>,
    pub exclude_ids: Vec<String>,
    pub min_similarity: f32,
    pub mode: QueryMode,
    pub kinds: Option<Vec<String>>,
    pub date_from: Option<f64>,
    pub date_to: Option<f64>,
    pub projection_seed: u64,
}

impl Default for QueryRequest {
    fn default() -> Self {
        Self {
            id: None,
            feature: None,
            meaning: None,
            limit: 120,
            ids: None,
            exclude_ids: Vec::new(),
            min_similarity: 0.0,
            mode: QueryMode::Combined,
            kinds: None,
            date_from: None,
            date_to: None,
            projection_seed: PROJECTION_SEED,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct QueryResult {
    pub id: String,
    pub similarity: f32,
    pub visual: Option<f32>,
    pub semantic: Option<f32>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ClusterMode {
    #[default]
    Similar,
    Color,
    Theme,
    Name,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct ClusterRequest {
    pub mode: ClusterMode,
    pub budget: usize,
    pub threshold: f32,
    pub ids: Option<Vec<String>>,
}

impl Default for ClusterRequest {
    fn default() -> Self {
        Self {
            mode: ClusterMode::Similar,
            budget: 40,
            threshold: 0.55,
            ids: None,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Cluster {
    pub id: String,
    pub title: String,
    pub item_ids: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct SelectRequest {
    pub count: usize,
    pub ids: Option<Vec<String>>,
    pub exclude_ids: Vec<String>,
    pub diversity: f32,
    pub include_favorites: bool,
    pub kinds: Option<Vec<String>>,
    pub min_gap_seconds: f64,
    pub date_from: Option<f64>,
    pub date_to: Option<f64>,
    pub seed: u64,
    pub prefilter: Option<usize>,
    pub prefer_recent: bool,
    /// Optional semantic query (base64 Int8 word vector) used to favor a story
    /// focus such as "ocean", "family", or "celebration".
    pub query_meaning: Option<String>,
    pub query_weight: f32,
}

impl Default for SelectRequest {
    fn default() -> Self {
        Self {
            count: 24,
            ids: None,
            exclude_ids: Vec::new(),
            diversity: 0.62,
            include_favorites: true,
            kinds: None,
            min_gap_seconds: 0.0,
            date_from: None,
            date_to: None,
            seed: 1,
            prefilter: None,
            prefer_recent: true,
            query_meaning: None,
            query_weight: 0.4,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Selection {
    pub id: String,
    pub score: f32,
    pub reason: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct DuplicateRequest {
    pub threshold: f32,
    pub max_gap_seconds: f64,
    pub min_group: usize,
    pub limit: usize,
}

impl Default for DuplicateRequest {
    fn default() -> Self {
        Self {
            threshold: 0.9,
            max_gap_seconds: 900.0,
            min_group: 2,
            limit: 200,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct DuplicateGroup {
    pub item_ids: Vec<String>,
    pub similarity: f32,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, vector: &[i8], date: f64, quality: f32) -> IndexItem {
        IndexItem {
            id: id.into(),
            name: format!("{id}.jpg"),
            date,
            width: 4032,
            height: 3024,
            favorite: false,
            kind: "photo".into(),
            color: "Blue".into(),
            theme: Some("Nature".into()),
            labels: vec!["beach".into(), "sea".into()],
            hash: "0".into(),
            feature: Some(
                base64::engine::general_purpose::STANDARD
                    .encode(vector.iter().map(|value| *value as u8).collect::<Vec<_>>()),
            ),
            meaning: None,
            palette: vec![0x336699],
            quality,
            detailed: false,
            source_modified: None,
        }
    }

    fn vector(index: usize, dimension: usize) -> Vec<i8> {
        let mut values = vec![0i8; dimension];
        values[index % dimension] = 100;
        values[(index * 7 + 3) % dimension] = 60;
        values
    }

    #[test]
    fn upsert_query_and_remove() {
        let index = MosaicIndex::new();
        index
            .upsert(vec![
                item("a", &vector(1, 512), 100.0, 0.8),
                item("b", &vector(2, 512), 200.0, 0.7),
                item("c", &vector(1, 512), 300.0, 0.6),
            ])
            .unwrap();
        assert_eq!(index.len(), 3);
        let result = index
            .query(&QueryRequest {
                id: Some("a".into()),
                mode: QueryMode::Visual,
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(result.first().unwrap().id, "c");
        assert!(result.first().unwrap().similarity > 0.9);
        assert_eq!(index.remove(&["b".into()]).unwrap(), 1);
        assert_eq!(index.len(), 2);
    }

    #[test]
    fn duplicates_find_bursts() {
        let index = MosaicIndex::new();
        let base = vector(5, 512);
        index
            .upsert(vec![
                item("one", &base, 1_000.0, 0.8),
                item("two", &base, 1_002.0, 0.7),
                item("three", &vector(99, 512), 1_003.0, 0.6),
            ])
            .unwrap();
        let groups = index.duplicates(&DuplicateRequest::default()).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].item_ids.len(), 2);
        assert!(groups[0].item_ids.contains(&"one".into()));
    }

    #[test]
    fn selection_respects_count_and_favorites() {
        let index = MosaicIndex::new();
        let mut items: Vec<IndexItem> = (0..30)
            .map(|value| item(&format!("p{value}"), &vector(value, 512), value as f64, 0.5))
            .collect();
        items[4].favorite = true;
        index.upsert(items).unwrap();
        let selected = index
            .select(&SelectRequest {
                count: 8,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(selected.len(), 8);
        assert!(selected.iter().any(|selection| selection.id == "p4"));
        let unique: HashSet<_> = selected
            .iter()
            .map(|selection| selection.id.clone())
            .collect();
        assert_eq!(unique.len(), 8);
    }

    #[test]
    fn semantic_query_favors_a_story_focus() {
        let index = MosaicIndex::new();
        let positive: Vec<i8> = (0..512)
            .map(|value| if value % 2 == 0 { 120 } else { -40 })
            .collect();
        let negative: Vec<i8> = positive.iter().map(|value| -*value).collect();
        let positive_encoded = base64::engine::general_purpose::STANDARD.encode(
            positive
                .iter()
                .map(|value| *value as u8)
                .collect::<Vec<_>>(),
        );
        let negative_encoded = base64::engine::general_purpose::STANDARD.encode(
            negative
                .iter()
                .map(|value| *value as u8)
                .collect::<Vec<_>>(),
        );
        let mut first = item("summer", &positive, 1_000.0, 0.5);
        first.meaning = Some(positive_encoded.clone());
        first.feature = None;
        let mut second = item("winter", &negative, 1_000.0, 0.5);
        second.meaning = Some(negative_encoded);
        second.feature = None;
        index.upsert(vec![first, second]).unwrap();
        let selected = index
            .select(&SelectRequest {
                count: 1,
                diversity: 0.0,
                query_meaning: Some(positive_encoded),
                query_weight: 1.0,
                min_gap_seconds: 0.0,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].id, "summer");
    }

    #[test]
    fn location_jump_splits_a_book_chapter() {
        // Two captures an hour apart but a hundred kilometres away should not share
        // one chapter, even though the clock alone would join them.
        let items = vec![
            super::tests::book_item("home", 1_700_000_000.0, 55.67, 12.56),
            super::tests::book_item("away", 1_700_003_600.0, 56.16, 10.20),
        ];
        let plan = crate::book::plan_book(&crate::book::BookRequest {
            items,
            include_cover: false,
            ..Default::default()
        })
        .unwrap();
        assert_eq!(plan.events.len(), 2);
    }

    fn book_item(id: &str, date: f64, latitude: f64, longitude: f64) -> crate::book::BookItem {
        crate::book::BookItem {
            id: id.into(),
            date,
            width: 4032,
            height: 3024,
            theme: None,
            color: "Blue".into(),
            favorite: false,
            quality: 0.6,
            latitude: Some(latitude),
            longitude: Some(longitude),
            place: None,
        }
    }

    #[test]
    fn clusters_are_deterministic_and_cover_items() {
        let index = MosaicIndex::new();
        let items: Vec<IndexItem> = (0..40)
            .map(|value| {
                let mut item = item(
                    &format!("p{value}"),
                    &vector(value % 5, 512),
                    value as f64,
                    0.5,
                );
                item.color = ["Red", "Blue", "Green", "Yellow"][value % 4].into();
                item
            })
            .collect();
        index.upsert(items).unwrap();
        let first = index
            .clusters(&ClusterRequest {
                mode: ClusterMode::Similar,
                ..Default::default()
            })
            .unwrap();
        let second = index
            .clusters(&ClusterRequest {
                mode: ClusterMode::Similar,
                ..Default::default()
            })
            .unwrap();
        let ids = |clusters: &[Cluster]| {
            let mut all: Vec<String> = clusters
                .iter()
                .flat_map(|cluster| cluster.item_ids.clone())
                .collect();
            all.sort();
            all
        };
        assert_eq!(ids(&first), ids(&second));
        assert_eq!(ids(&first).len(), 40);
    }
}
