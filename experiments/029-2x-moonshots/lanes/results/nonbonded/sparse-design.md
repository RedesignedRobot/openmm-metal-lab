# Sparse force ownership for the next architecture screen

The dense prototype is a control experiment. Its memory is proportional to atoms times resident SIMD groups. Capping that memory lowers parallelism most on stmv, and clearing dense slices writes locations the pair kernel never touches. Those are limits of this representation, not evidence that float ownership cannot win.

A sparse alternative can retain parallelism without device force atomics:

1. Give a threadgroup an x atom block. Its SIMD groups process that block's neighbor tiles. Each SIMD group keeps its x forces in registers. At the end, reduce the SIMD groups through a small threadgroup array and write each x atom once.
2. Store y forces in private tile records. A lane writes the record corresponding to its existing interactingAtoms entry. No other lane or threadgroup owns that record.
3. Build reverse incidence lists when the neighbor list rebuilds. Each atom's list identifies the y records contributing to it. Integer count, scan, and scatter operations occur during rebuilding, not during every force evaluation. An x-to-tile incidence list assigns work to the owning threadgroup, even when findBlocks interleaves chunks from different x rows.
4. Run one atom-owned reduction over the x result and its y records, then one fixed-point merge per atom/component into the existing long force buffer. Keep the existing kernel under DeterministicForces and on the M2.

For T neighbor tiles and N padded atoms, ordinary-tile storage is approximately 516*T + 24*N bytes, plus small scan levels and x row offsets. The 516 bytes per tile are 384 bytes of y forces, 128 bytes of y incidence indices, and 4 bytes of x incidence indices. This trades the dense N times SIMD-count representation for N plus actual tiles. Exclusion records and alignment must be included in the final cap before enabling it.

Use native SIMD prefix sums and a hierarchical integer scan for CSR offsets. Per-atom list order need not be stable in default mode because DeterministicForces takes the old path. Measure default force spread. Do not use float atomics, last-arriver reductions, inter-threadgroup spin waits, or one-at-a-time position staging.

The memory cap must not depend on unbounded worst-case neighbor allocation. If the actual tile count exceeds the capped record capacity, GPU guards must select the existing kernel and suppress the sparse reduction. This requires no new host wait, no rebuild-policy change, and no indirect dispatch. Both guarded dispatches can be encoded; measure that overhead. Record overflow must never silently drop interactions.

Open correctness work before coding: account for exclusion tiles, padded sentinel atoms, list rebuild/overflow, force-group changes, and D3 pass ordering. The force records need no full-buffer clear if every active record is overwritten and the reduction only reads active incidence entries.

Decision: use the first dense screen to separate atomics savings from dense-memory and occupancy costs. If its timings point to those costs, prototype sparse ownership as the next large architectural chunk. Cluster-pair packing is a later, separate change so its benefit is not confused with accumulation ownership. No sparse kernel has been built or measured yet.

## Integration constraints from the current encoder path

prepareInteractions already produces rebuildNeighborList before findInteractingBlocks and schedules both inside a serial encoder. A reverse-index pipeline can follow findInteractingBlocks, guarding each kernel on rebuildNeighborList without a host read. Its pipeline is count atom and x-row incidence, hierarchical exclusive scan, then scatter record indices. Scratch counters must be cleared only when rebuilding. Bounds must use min(interactionCount[0], recordCapacity); an over-capacity list selects the old force kernel for that evaluation and prevents any sparse-force read.

Exclusion tiles need their own private y records and inclusion in the inverse atom index. Their x contributions reduce with the ordinary x-row contributions. Diagonal exclusion tiles produce only x contributions. These records, count arrays, scan levels, row offsets, and allocation rounding all belong in the 1% cap. The earlier 516*T + 24*N expression is only the ordinary-tile lower bound, not the complete allocation claim.

The x-row owner can use two SIMD groups per threadgroup, each traversing alternate CSR entries. Accumulate x forces in registers over its entries, store the two SIMD results in a 192-float threadgroup array, then reduce in a fixed SIMD order. Write one x result per atom. Distinct y records need no force atomics. The final atom kernel reads x and its y incidence list and merges once into the existing fixed-point force buffer. End the concurrent force encoder before this final read, as in the dense control.

A GPU-capacity flag must guard both encoded force variants. No indirect launch, host rebuild-trigger change, or extra count download is required. DeterministicForces and older GPU families keep the old kernel and allocate none of these arrays. Integer incidence scatter order does not make default float accumulation bitwise; default spread remains a measured accuracy result.
