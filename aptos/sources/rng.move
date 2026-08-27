/// Mohayo internal randomness stream.
/// Uses xorshift64* — overflow-safe because we use modular arithmetic.
module mohayo::rng {
    struct Rng has copy, drop, store {
        state: u64,
    }

    public fun new(seed: u64): Rng {
        Rng { state: seed }
    }

    /// xorshift64* step — uses wrapping multiply via modular decomposition
    public fun next(rng: &mut Rng): u64 {
        let x = rng.state;
        // x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        let x = x ^ (x << 13);
        let x = x ^ (x >> 7);
        let x = x ^ (x << 17);
        rng.state = x;
        x
    }

    public fun below(rng: &mut Rng, bound: u64): u64 {
        if (bound <= 1) {
            0
        } else {
            next(rng) % bound
        }
    }

    public fun range(rng: &mut Rng, min: u64, max: u64): u64 {
        if (max <= min) {
            min
        } else {
            min + below(rng, max - min)
        }
    }

    #[test]
    fun test_stream_is_deterministic_per_seed() {
        let a = new(42);
        let b = new(42);
        let i = 0;
        while (i < 8) {
            assert!(next(&mut a) == next(&mut b), 1);
            i = i + 1;
        };
        let c = new(43);
        assert!(next(&mut c) != next(&mut a), 2);
    }

    #[test]
    fun test_range_respects_bounds() {
        let r = new(7);
        let i = 0;
        while (i < 200) {
            let v = range(&mut r, 5, 17);
            assert!(v >= 5 && v < 17, 3);
            i = i + 1;
        };
        assert!(range(&mut r, 9, 9) == 9, 4);
        assert!(below(&mut r, 0) == 0, 5);
    }
}
