//! Crate docs with `code`.
use std::collections::HashMap;
use std::fmt::{self, Display};

/// A point in two dimensions.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point<T: Copy> {
    pub x: T,
    pub y: T,
}

pub enum Shape {
    Circle { center: Point<f64>, radius: f64 },
    Polygon(Vec<Point<f64>>),
    Empty,
}

impl<T: Copy + Display> Display for Point<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "({}, {})", self.x, self.y)
    }
}

trait Area {
    fn area(&self) -> f64;
}

impl Area for Shape {
    fn area(&self) -> f64 {
        match self {
            Shape::Circle { radius, .. } => std::f64::consts::PI * radius * radius,
            Shape::Polygon(points) if points.len() < 3 => 0.0,
            Shape::Polygon(points) => {
                let mut sum = 0.0_f64;
                for (i, p) in points.iter().enumerate() {
                    let q = points[(i + 1) % points.len()];
                    sum += p.x * q.y - q.x * p.y;
                }
                (sum / 2.0).abs()
            }
            Shape::Empty => 0.0,
        }
    }
}

macro_rules! square {
    ($x:expr) => {
        $x * $x
    };
}

async fn load<'a>(names: &'a [&str]) -> Result<HashMap<&'a str, usize>, Box<dyn std::error::Error>> {
    let mut map = HashMap::new();
    for name in names {
        map.insert(*name, name.len());
    }
    /* block
       comment */
    let raw = r#"raw "string" \n"#;
    let bytes = b"bytes\x7f";
    let c = '\u{1F600}';
    let n = 0xFF_u8 as usize + 1_000 + 0b1010 + 0o17 + square!(3);
    let _ = (raw, bytes, c, n, 1e-3, true, None::<i32>);
    Ok(map)
}

const LIMIT: usize = 64;
static mut COUNTER: u32 = 0;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn origin() {
        let p = Point { x: 0, y: 0 };
        assert_eq!(p.to_string(), "(0, 0)");
    }
}
