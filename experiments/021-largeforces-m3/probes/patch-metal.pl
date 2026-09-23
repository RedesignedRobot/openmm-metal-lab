# Same-length patch of the embedded common.metal: drop the erf comment to make room for a
# saturating realToFixedPoint. Refuses to write unless exactly one region matches and fits.
undef $/;
my $bin = <STDIN>;
my $re = qr{/\*\*\n \* MSL has no erf\.  Near zero[^\n]*\n \*/\n(inline float erf\(float x\) \{.*?\n\}\n)\ninline long realToFixedPoint\(real x\) \{\n    return \(long\) \(x\*0x100000000\);\n\}}s;
my @m = ($bin =~ /$re/g);
die "matches: " . scalar(@m) . "\n" unless @m == 1;
$bin =~ /$re/;
my ($start, $len, $erf) = ($-[0], $+[0] - $-[0], $1);
my $new = $erf . "\ninline long realToFixedPoint(real x) {\n    real v = x*0x1p32f;\n    return v < -0x1p63f ? LONG_MIN : v >= 0x1p63f ? LONG_MAX : (long) v;\n}";
die "too long: " . length($new) . " > $len\n" if length($new) > $len;
$new .= " " x ($len - length($new));
substr($bin, $start, $len) = $new;
print STDERR "patched $len bytes at offset $start\n";
print $bin;
