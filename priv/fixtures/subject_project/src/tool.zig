// The beast: 10 branch tokens (4 if, 2 while, 1 for, 2 and, 1 orelse)
// => complexity 11 => CRAP 132.0 at 0% coverage.
fn beast(a: u32, b: u32) u32 {
    var total: u32 = 0;
    if (a > 1 and b > 1) {
        total += 1;
    }
    if (a > 2 and b > 2) {
        total += 2;
    }
    if (a > 3) {
        total += 3;
    }
    if (a > 4) {
        total += 4;
    }
    var i: u32 = 0;
    while (i < a) : (i += 1) {
        total += 1;
    }
    while (total > 100) {
        total -= 1;
    }
    for (0..b) |_| {
        total += 1;
    }
    const safe = total orelse 0;
    return safe;
}

fn calm() void {}
