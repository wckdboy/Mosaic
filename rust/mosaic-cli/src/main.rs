use base64::Engine;
use mosaic_core::index::{
    ClusterMode, ClusterRequest, DuplicateRequest, IndexItem, MosaicIndex, QueryMode, QueryRequest,
    SelectRequest,
};
use std::time::Instant;

fn main() {
    let command = std::env::args().nth(1).unwrap_or_else(|| "scale".into());
    match command.as_str() {
        "scale" => {
            let count = std::env::args()
                .nth(2)
                .and_then(|value| value.parse().ok())
                .unwrap_or(50_000);
            scale(count);
        }
        "layout" => {
            let request = mosaic_core::layout::CollageRequest {
                count: 9,
                aspect: 1.0,
                style: "mosaic".into(),
                seed: 4,
                spacing: 0.018,
                padding: 0.02,
                items: Vec::new(),
            };
            println!(
                "{}",
                serde_json::to_string_pretty(&mosaic_core::layout::layout_collage(&request).unwrap())
                    .unwrap()
            );
        }
        other => eprintln!("unknown command: {other} (try scale or layout)"),
    }
}

fn synthetic(index: usize, dimension: usize) -> Vec<i8> {
    // A stable, dense signature with clusters: nearby indices share most values.
    let mut values = vec![0i8; dimension];
    for (position, value) in values.iter_mut().enumerate() {
        let hash = mosaic_core::rng::splitmix64((index / 12) as u64 * 131 + position as u64);
        *value = if hash & 0x8000_0000_0000_0000 != 0 {
            96
        } else {
            -96
        };
    }
    let noise = mosaic_core::rng::splitmix64(index as u64);
    for step in 0..12 {
        let slot = ((noise >> (step % 16)) as usize + step * 31) % dimension;
        values[slot] = values[slot].saturating_add(20);
    }
    values
}

fn item(index: usize, dimension: usize) -> IndexItem {
    let feature = synthetic(index, dimension);
    IndexItem {
        id: format!("asset-{index:06}"),
        name: format!("IMG_{index:05}.jpg"),
        date: 1_600_000_000.0 + index as f64 * 900.0,
        width: 4032,
        height: 3024,
        favorite: index % 97 == 0,
        kind: if index % 20 == 0 { "video" } else { "photo" }.into(),
        color: ["Blue", "Green", "Red", "Yellow", "Teal"][index % 5].into(),
        theme: Some(["Nature", "People", "Food & Drink", "City & Places"][index % 4].into()),
        labels: vec!["outdoor".into(), "day".into(), "sky".into()],
        hash: "0".into(),
        feature: Some(
            base64::engine::general_purpose::STANDARD
                .encode(feature.iter().map(|value| *value as u8).collect::<Vec<_>>()),
        ),
        meaning: None,
        palette: vec![0x3366AA],
        quality: 0.55 + (index % 40) as f32 / 100.0,
        detailed: index % 15 == 0,
        source_modified: None,
    }
}

fn scale(count: usize) {
    let dimension = 2_048;
    let index = MosaicIndex::new();
    let started = Instant::now();
    let batch = 1_000;
    let mut cursor = 0;
    while cursor < count {
        let size = batch.min(count - cursor);
        let items = (cursor..cursor + size)
            .map(|value| item(value, dimension))
            .collect();
        index.upsert(items).unwrap();
        cursor += size;
    }
    println!(
        "upsert {count} items: {:?} ({:.0} items/s)",
        started.elapsed(),
        count as f64 / started.elapsed().as_secs_f64()
    );

    let seed = "asset-000123".to_string();
    let started = Instant::now();
    let results = index
        .query(&QueryRequest {
            id: Some(seed.clone()),
            mode: QueryMode::Combined,
            limit: 200,
            ..Default::default()
        })
        .unwrap();
    println!(
        "query top-200: {:?} ({} results, top {:?})",
        started.elapsed(),
        results.len(),
        results.first().map(|result| (result.id.as_str(), result.similarity))
    );

    let started = Instant::now();
    let selected = index
        .select(&SelectRequest {
            count: 80,
            diversity: 0.65,
            min_gap_seconds: 30.0,
            ..Default::default()
        })
        .unwrap();
    println!("select 80 from {count}: {:?} ({} picks)", started.elapsed(), selected.len());

    let started = Instant::now();
    let clusters = index
        .clusters(&ClusterRequest {
            mode: ClusterMode::Similar,
            ..Default::default()
        })
        .unwrap();
    println!(
        "similar clusters: {:?} ({} clusters, largest {})",
        started.elapsed(),
        clusters.len(),
        clusters.first().map(|cluster| cluster.item_ids.len()).unwrap_or(0)
    );

    let started = Instant::now();
    let duplicates = index
        .duplicates(&DuplicateRequest {
            threshold: 0.9,
            max_gap_seconds: 900.0,
            ..Default::default()
        })
        .unwrap();
    println!(
        "duplicate groups: {:?} ({} groups)",
        started.elapsed(),
        duplicates.len()
    );

    let started = Instant::now();
    let stats = index.stats().unwrap();
    println!(
        "stats: {:?} (analyzed {}, ~{:.1} MB)",
        started.elapsed(),
        stats.analyzed,
        stats.estimated_bytes as f64 / 1_048_576.0
    );
}
