#ifndef DP_EDGE_SHELF_GEOMETRY_H
#define DP_EDGE_SHELF_GEOMETRY_H

#include <math.h>

// View-space only. Reference: ZengNiu / 曾牛分屏 v1.7.4 parked-thumbnail
// packing and the supplied screenshot. Duo packs its current pair, not apps.
typedef struct { double x, y, width, height; } DPEdgeCardRect;

static inline DPEdgeCardRect DPEdgeCardFrame(double safeX, double safeY, double safeWidth,
                                             double safeHeight, unsigned count, unsigned index) {
    DPEdgeCardRect r = {0};
    if (!count || index >= count || safeWidth < 1 || safeHeight < 1 ||
        !isfinite(safeWidth) || !isfinite(safeHeight)) return r;
    const double aspect = .445, gap = 5;
    double usable = safeHeight - gap * (count - 1);
    if (usable < count) return r;
    r.width = floor(fmin(60, fmin(safeWidth * .144, usable * aspect / count)));
    r.height = floor(r.width / aspect);
    r.x = safeX;
    r.y = safeY + index * (r.height + gap);
    return r;
}
#endif
