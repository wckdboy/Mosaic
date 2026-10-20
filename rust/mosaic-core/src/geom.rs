//! Normalized composition geometry.
//!
//! Every layout works in a unit square. Coordinates are converted to device points
//! by Swift, which keeps the layout engine independent of screen size and lets the
//! same project render at thumbnail, preview, or 8K export resolution.

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    pub fn new(x: f32, y: f32, w: f32, h: f32) -> Self {
        Self { x, y, w, h }
    }

    pub fn unit() -> Self {
        Self::new(0.0, 0.0, 1.0, 1.0)
    }

    pub fn inset(self, amount: f32) -> Self {
        let a = amount.max(0.0).min(0.45);
        Self {
            x: self.x + self.w * a,
            y: self.y + self.h * a,
            w: (self.w * (1.0 - a * 2.0)).max(0.001),
            h: (self.h * (1.0 - a * 2.0)).max(0.001),
        }
    }

    pub fn inset_xy(self, x_amount: f32, y_amount: f32) -> Self {
        let ax = x_amount.max(0.0).min(0.45);
        let ay = y_amount.max(0.0).min(0.45);
        Self {
            x: self.x + self.w * ax,
            y: self.y + self.h * ay,
            w: (self.w * (1.0 - ax * 2.0)).max(0.001),
            h: (self.h * (1.0 - ay * 2.0)).max(0.001),
        }
    }

    pub fn split_vertical(self, fraction: f32) -> (Self, Self) {
        let f = fraction.clamp(0.05, 0.95);
        let left = Self::new(self.x, self.y, self.w * f, self.h);
        let right = Self::new(self.x + self.w * f, self.y, self.w * (1.0 - f), self.h);
        (left, right)
    }

    pub fn split_horizontal(self, fraction: f32) -> (Self, Self) {
        let f = fraction.clamp(0.05, 0.95);
        let top = Self::new(self.x, self.y, self.w, self.h * f);
        let bottom = Self::new(self.x, self.y + self.h * f, self.w, self.h * (1.0 - f));
        (top, bottom)
    }

    pub fn area(self) -> f32 {
        self.w * self.h
    }

    pub fn is_horizontal(self) -> bool {
        self.w >= self.h
    }

    /// True when two rectangles overlap by more than a tiny tolerance. Used by tests
    /// to guarantee that non-overlapping styles never produce stacked cells.
    pub fn overlaps(self, other: Self) -> bool {
        let epsilon = 0.0001;
        self.x + self.w > other.x + epsilon
            && other.x + other.w > self.x + epsilon
            && self.y + self.h > other.y + epsilon
            && other.y + other.h > self.y + epsilon
    }
}

#[cfg(test)]
mod tests {
    use super::Rect;

    #[test]
    fn splitting_covers_the_parent() {
        let (a, b) = Rect::unit().split_vertical(0.37);
        assert!((a.area() + b.area() - 1.0).abs() < 0.0001);
        let (c, d) = Rect::unit().split_horizontal(0.61);
        assert!((c.area() + d.area() - 1.0).abs() < 0.0001);
    }

    #[test]
    fn insets_never_invert() {
        let rect = Rect::new(0.0, 0.0, 0.01, 0.01).inset(0.5);
        assert!(rect.w > 0.0 && rect.h > 0.0);
    }
}
