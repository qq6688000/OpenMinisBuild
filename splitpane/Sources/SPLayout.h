// Pure geometry helpers shared by UIKit layout and the portable regression tests.
#ifndef SP_LAYOUT_H
#define SP_LAYOUT_H
#include <math.h>

typedef struct {
    double first;
    double gap;
    double second;
} SPPaneLayout;

static inline double SPClampPaneRatio(double ratio) {
    if (!isfinite(ratio)) return 0.5;
    return fmin(0.95, fmax(0.05, ratio));
}

static inline SPPaneLayout SPLayoutForExtent(double extent, double ratio) {
    if (!isfinite(extent) || extent < 0.0) extent = 0.0;
    double gap = fmin(26.0, extent);
    double usable = extent - gap;
    double first = fmin(usable, fmax(0.0, round(usable * SPClampPaneRatio(ratio))));
    return (SPPaneLayout){first, gap, usable - first};
}

static inline double SPMovedPaneRatio(double initial, double translation, double extent) {
    if (!isfinite(translation) || !isfinite(extent) || extent <= 26.0)
        return SPClampPaneRatio(initial);
    return SPClampPaneRatio(initial + translation / (extent - 26.0));
}
#endif
