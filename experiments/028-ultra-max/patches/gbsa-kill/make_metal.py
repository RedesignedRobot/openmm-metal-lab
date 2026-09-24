import re, sys
src = open("gbsaObc.orig.cc").read()

def sub(old, new, count):
    global src
    n = src.count(old)
    assert n == count, (old, n)
    src = src.replace(old, new)

header = ("/**\n"
          " * Metal version of platforms/common/src/kernels/gbsaObc.cc. computeGBSAForce1 uses\n"
          " * one fast reciprocal square root per pair and a per-atom reciprocal Born radius\n"
          " * in place of a precise square root and three divisions.\n"
          " */\n\n")
src = header + src

sub("""    real fx, fy, fz, fw;
    real bornRadius;
} AtomData2;""", """    real fx, fy, fz, fw;
    real bornRadius, invBornRadius;
    real padding; // Keeps the stride an odd number of words.
} AtomData2;""", 1)

sub("""
        real bornRadius1 = global_bornRadii[atom1];
""", """
        real bornRadius1 = global_bornRadii[atom1];
        real invBornRadius1 = RECIP(bornRadius1);
""", 1)
sub("""
            real bornRadius1 = global_bornRadii[atom1];
""", """
            real bornRadius1 = global_bornRadii[atom1];
            real invBornRadius1 = RECIP(bornRadius1);
""", 1)
sub("""            localData[LOCAL_ID].bornRadius = bornRadius1;
""", """            localData[LOCAL_ID].bornRadius = bornRadius1;
            localData[LOCAL_ID].invBornRadius = invBornRadius1;
""", 1)
for indent in ("            ", "                "):
    sub("\n" + indent + "localData[LOCAL_ID].bornRadius = global_bornRadii[j];\n",
        "\n" + indent + "real tempBornRadius = global_bornRadii[j];\n" +
        indent + "localData[LOCAL_ID].bornRadius = tempBornRadius;\n" +
        indent + "localData[LOCAL_ID].invBornRadius = RECIP(tempBornRadius);\n", 1)

old_pair = """{i}real invR = RSQRT(r2);
{i}real r = r2*invR;
{i}real bornRadius2 = localData[{k}].bornRadius;
{i}real alpha2_ij = bornRadius1*bornRadius2;
{i}real D_ij = r2*RECIP(4.0f*alpha2_ij);
{i}real expTerm = EXP(-D_ij);
{i}real denominator2 = r2 + alpha2_ij*expTerm;
{i}real denominator = SQRT(denominator2);
{i}real scaledChargeProduct = PREFACTOR*charge1*charge2;
{i}real tempEnergy = scaledChargeProduct*RECIP(denominator);
{i}real Gpol = tempEnergy*RECIP(denominator2);
"""
new_pair = """{i}real bornRadius2 = localData[{k}].bornRadius;
{i}real alpha2_ij = bornRadius1*bornRadius2;
{i}real D_ij = 0.25f*r2*invBornRadius1*localData[{k}].invBornRadius;
{i}real expTerm = EXP(-D_ij);
{i}real denominator2 = r2 + alpha2_ij*expTerm;
{i}real invDenominator = RSQRT(denominator2);
{i}real scaledChargeProduct = PREFACTOR*charge1*charge2;
{i}real tempEnergy = scaledChargeProduct*invDenominator;
{i}real Gpol = tempEnergy*invDenominator*invDenominator;
"""
sites = [(" "*24, "tbx+j", 1), (" "*24, "tbx+tj", 1), (" "*28, "tbx+tj", 2)]
for i, k, c in sites:
    sub(old_pair.format(i=i, k=k), new_pair.format(i=i, k=k), c)

assert "RECIP(denominator" not in src and " SQRT(denominator2)" not in src and src.count("RSQRT(denominator2)") == 4
open("gbsaObc.metal", "w").write(src)
print("ok", src.count("\n"), "lines")
