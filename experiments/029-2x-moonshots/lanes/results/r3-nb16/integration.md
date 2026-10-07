# 16x32 format and integration boundary

Status: rejected at the pre-registered force-loop gate on 2026-09-27. Do not integrate
this candidate. Total instructions increased 13.3 percent and force time increased
85.2 percent on identical apoa1rf coordinates. No GPU emitter was implemented.
The branch preserves a diagnostic prototype, not a production list implementation.

## Format

Each `tiles[p]` is `2*xBlock+half`. Each packet holds 32 y atom indices in
`interactingAtoms[32*p:32*p+32]`. The first sixteen SIMD lanes and the second sixteen
hold the same x atoms, `16*tiles[p] + lane%16`. They rotate their separate sixteen y
states sixteen times. Each lane keeps one x state, one y state and the y force.
A SIMD shuffle combines the two x forces after the loop. Only the lower half writes
x forces. Every lane executes the shuffle. No SIMD barrier depends on lane identity.

Packets for an x half are contiguous. Fixed-point x sums persist across packets in
the dispatch's range and flush at the x-half or range boundary. A y force flushes per
packet. Both prewrapped and general periodic branches follow the current template.
Exceptional/diagonal tiles and sparse single pairs use the existing loops and arrays.
The sentinel y index is the padded atom count. A partial x half still occupies sixteen
lanes, with the existing atom validity checks excluding padded atoms.

The CPU emitter retains y atoms at the padded radius and sorts each half's receivers
by atom index before forming packets. Sorting is needed for deterministic packet
membership when GPU list construction emits ordinary tiles in a different order.
A GPU emitter cannot replace it with scheduling-dependent atomic append and claim
bitwise rebuild determinism without further proof.

## Host patch

The diagnostic adds an optional template parameter to `createInteractionKernel`,
a compact force-function cache in `KernelSet`, and `computeCompactInteractions`.
The latter substitutes the independent tiles, counts, capacity and atom arrays in a
copy of the established argument vector. It does not resize or overwrite live arrays.
The existing nonbonded template receives one conditional insertion point around its
ordinary tile loop. It uses the same generated parameter and interaction code.
The default force, energy and force/energy kernels keep the original template path.

No change was made to `findInteractingBlocks`, pruning, rebuild scheduling, or
`prepareInteractions`. If the counter gates pass, the next patch is an independent
emit pass after the current builder. That pass goes after the active
list prune once the dual-list work is ready. Per-system selection must use measured q or
an established density proxy. Atom count cannot separate the passing apoa1 systems
from the failing cellulose and stmv lists.

## Remaining conditions if the force loop survives

- GPU emission must account for all list overflow and padding, preserve the skin's
  lifetime, and expose the new packet count without a per-step host synchronization.
- Its timing must be added to force time before applying the ten percent gate.
- Parameter updates and force-group caches must invalidate the compact function as
  needed. The replay cache is only exercised with one fixed parameter state.
- Complete the requested pathological-box, exclusion, partial-block, parameter-update,
  mixed-precision, trajectory/list coverage, deterministic-rebuild and final quick gate.
- Obtain the host keep measurements. This diagnostic claims no host speedup.

## Evidence limits

The first force comparison used `DeterministicForces=true`. The Metal property's only
runtime use outside platform setup is selecting fixed-point PME charge spreading;
it does not change the direct-force loop or its launch dimensions. apoa1rf has no PME.
Bitwise repeated dispatches are proven only for one fixed emitted list. Determinism
across rebuilds is a remaining acceptance condition, not a claim from this check.

The census at step 100 describes a fresh compact list for that snapshot. It does not
prove that a compact list emitted at step 0 remains valid for 100 steps. A production
emitter must share the builder's reference coordinates and rebuild/prune guarantees.

## Emitter design review while awaiting counters

The existing `MetalSort` sorts its allocated length. A common sentinel for all unused
records would put those records in one bucket. Its oversized-bucket path runs a global
bitonic sort in one workgroup. It also has no rebuild flag to skip its dispatches.
Using it unchanged is therefore a poor fit for a capacity-sized, rebuild-only emitter.

A separate emitter can instead retain two 32-bit selection masks per original tile,
count receivers per x half, prefix-sum packet counts, scatter receivers into each row,
and sort each row by atom index. The mask pass evaluates distances once; the scatter
uses those masks without repeating pair distances. Masks belong only to emission.
The force format remains dense and has no mask interpreter. A row sort makes the
packet membership canonical after arbitrary atomic append order.

Every emission kernel must use the same GPU rebuild flag as the source list. The mask
pass uses the padded radius at the builder's reference coordinates. A compact list
made from later positions cannot inherit an earlier list's skin lifetime. Storage can
be bounded by twice the original tile capacity because each old tile contributes at
most one packet to each x half. The q decision can be downloaded once during initial
warmup; a host download on every force step would defeat the optimization.
