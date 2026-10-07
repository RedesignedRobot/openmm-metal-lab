# GayBerne torque PR, openmm/openmm#5441

Prior reports: none. `gh search issues/prs` on openmm/openmm for "GayBerne", "Gay-Berne", "gay berne", "GayBerneForce", "GayBerne torque", "GayBerne energy conservation", "GayBerne drift", "ellipsoid torque" returned only #1553 (the original implementation, 2016), #4312 (quaternion access) and unrelated hits. The line dates to the original implementation (Reference a783b996f 2017 rename of 2016 code, common kernel 222b3bb40 2016).

---

## Title

Fix the chi term in the GayBerneForce torque

## Body

GayBerneForce computes the wrong torque for its strength anisotropy factor chi. chi = X^2 with X = 2 u^T B12^-1 u, so its orientation derivative is 2X dX/dq. The torque code scales that term by `-4*rInv2`, which drops the 2X = 2*sqrt(chi) factor. The force path already has it: `dchidr` uses `-8*rInv2*sqrt(chi)`.

Net forces on each ellipsoid come out exact, but the torques don't. On the testEnergyConservation system they were 6 to 13% off, so energy drifts at a rate that doesn't shrink with the step size. Over 200 seeded Reference runs of that test, the worst energy error was 9.5e-5 against its 1e-4 limit, so the test passes with almost no margin. With the fix the worst is 4.6e-7.

The same line is in Reference, CPU and the common kernel that CUDA, OpenCL and HIP compile. This PR changes it in all three to `-8*rInv2*sqrt(chi)`, matching `dchidr`.

How I tested it:
- A new testForcesMatchEnergy in TestGayBerneForce.h puts two ellipsoids at unrelated orientations and compares the force norm with a finite difference of the energy along the force. Without the fix it fails on Reference and CPU (expected 50.6851, found 51.2824). With the fix it passes.
- TestReferenceGayBerneForce and TestCpuGayBerneForce pass on my Mac.
- I checked each orientation derivative in computeOneInteraction against finite differences in a numpy port. dudq and detadq match. dchidq was about half the numerical value before the fix and matches to 5 digits after.

Found and fixed with Claude Opus 5.5.
