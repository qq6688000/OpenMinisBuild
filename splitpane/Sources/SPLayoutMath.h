#ifndef SPLITPANE_LAYOUT_MATH_H
#define SPLITPANE_LAYOUT_MATH_H

// Pure geometry: shared by the live seam gesture and host-independent tests.
static inline double SPSeamRatio(double width, double height,
                                 double x, double y, double seam) {
    const int horizontal = width > height;
    double usable = (horizontal ? width : height) - seam;
    if (usable < 1.0) usable = 1.0;
    return ((horizontal ? x : y) - seam / 2.0) / usable;
}

#endif
