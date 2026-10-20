#ifndef MOSAIC_CORE_H
#define MOSAIC_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque, incrementally updated visual index. Create once per app session.
typedef struct MosaicIndex MosaicIndex;

MosaicIndex *mosaic_index_new(void);
void mosaic_index_free(MosaicIndex *index);

/// Frees any string returned by this library.
void mosaic_string_free(char *value);

/// Semantic version of the Rust engine.
char *mosaic_core_version(void);

/// All calls accept UTF-8 JSON and return `{ "ok": true, "result": ... }` or
/// `{ "ok": false, "error": "..." }`. The caller owns the returned string.
char *mosaic_index_upsert(MosaicIndex *index, const char *json);
char *mosaic_index_remove(MosaicIndex *index, const char *json);
char *mosaic_index_clear(MosaicIndex *index);
char *mosaic_index_query(MosaicIndex *index, const char *json);
char *mosaic_index_clusters(MosaicIndex *index, const char *json);
char *mosaic_index_select(MosaicIndex *index, const char *json);
char *mosaic_index_duplicates(MosaicIndex *index, const char *json);
char *mosaic_index_stats(MosaicIndex *index, const char *json);

char *mosaic_collage_layout(const char *json);
char *mosaic_book_plan(const char *json);

#ifdef __cplusplus
}
#endif

#endif
