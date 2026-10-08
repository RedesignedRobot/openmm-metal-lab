# Accumulation decision record

Dense private slices scale as 3 float components x padded atoms x two SIMD groups x threadgroups. With the 1% working-set cap, the 60-core M3 Ultra can launch only 85 threadgroups for cellulose and 32 for STMV. Their measured speeds are 0.327x and 0.182x int028. This invalidates the dense design under the memory constraint. It does not establish that removing pair-kernel atomics is itself unprofitable.

Private tile records change storage from O(atoms x threadgroups) to O(neighbor tiles). Each coarse tile owns 64 endpoint records, each with three floats, plus 64 uint reverse-incidence entries: 1024 bytes per tile. Per-atom counts/offsets and hierarchical scan buffers complete the representation. The M3 Ultra budget fits approximately 0.8 million coarse tiles while retaining the original 2400 threadgroups. The GPU builds the reverse index only on the existing neighbor-list rebuild flag. Pair work writes each endpoint once; a separate per-atom gather performs the final force merge. No host rebuild or dispatch trigger is changed.

The record prototype must be interpreted with its capacity guard. A list larger than the budget falls back to the original pair-kernel force atomics. A near-baseline timing alone would not prove that the atomics-free path is slow. If the screen is ambiguous, a one-shot diagnostic must report the live tile count and capacity before assigning an architectural verdict. The initial force gate and smoke prove numerical validity on their inputs, not capacity coverage on the two large timing targets.

If records are alive, the next layout experiment should reduce record traffic and gather indirection while retaining enough parallel work. A possible design assigns each x block to one contiguous tile owner, accumulates x forces in registers, and emits only y endpoint records. That approximately halves tile storage, at the cost of a more constrained work partition. This is a design argument, not an implemented or measured result. A cluster-pair prototype remains conditional on the record screen providing evidence to proceed.

The final merge into the shared force buffer remains atomic. Ending the current encoder is not sufficient evidence that another queue's PME work cannot still write the same buffer. Removing those final per-atom atomics would require explicit cross-queue ownership proof and is not part of this probe.

DeterministicForces uses the original fixed-point path. The record reverse index is built with integer incidence atomics, so its order is stable within a list but may vary between rebuilds or processes. No claim of bitwise default forces is made for this path without fresh-process measurements.

## Conditional cluster-pair step

GROMACS documents spatially binned atom clusters, a cluster-pair list, and an additional GPU supercluster level for data reuse. Its GPU kernels use 4x4 or 8x8 atom clusters. Source: https://raw.githubusercontent.com/gromacs/gromacs/main/docs/doxygen/lib/nbnxm.md (read 2026-09-26). Its benchmark documentation also makes the relevant tradeoff explicit: smaller clusters can improve the fraction of useful pairs while reducing total pair throughput. Source: https://manual.gromacs.org/current/onlinehelp/gmx-nonbonded-benchmark.html.

An Apple prototype could keep the current 32-atom outer tile as a supercluster and split it into four 8-atom clusters. A SIMD32 group maps to an 8x4 cluster half; subgroup shuffles perform endpoint reductions. The existing coarse neighbor list remains the rebuild authority. Subcluster bounding boxes permit uniform rejection of empty halves before their pair math. Per-tile endpoint storage can remain 64 float3 records by accumulating subcluster contributions locally before the final unique stores.

This needs an actual cluster bounding/repacking stage and endpoint reduction, not merely a different loop over the same 32x32 pairs. Without culling or reuse, subdividing the tile adds bookkeeping and cannot establish a new design. Fixed local reductions must avoid a barrier for every pair. No prototype is implemented yet; the step remains conditional on the accumulation screen.

## Landing constraints found by measurement and review

The live diagnostic confirms the record path is active on all three screened systems at steps 1 and 100. Cellulose needs approximately 223k total record tiles against an 812k capacity; STMV needs 568k against 807k. Capacity fallback does not explain cellulose's 0.848x result.

Public MTLBuffer.allocatedSize queries put the record buffers approximately 13–53 KB above the 1% device budget. Heap size estimates alone are insufficient for this strict cap. A surviving implementation needs allocation headroom or storage limited to the current neighbor-list capacity, with the existing safe fallback retained. The current record snapshot is experimental and is not memory-compliant as allocated.

Any surviving float-accumulation candidate must explicitly retain the old path in full double precision, as well as under DeterministicForces and on M2. This round measures only single and mixed force kernels. The final MAX_BITS-only source now preserves double precision explicitly; its force-specialization policy in single and mixed is unchanged from the selected measurements.

## Large-system screen verdict

Private records reach 0.848x int028 on cellulose and 0.852x on STMV, both without build overlap. Neither meets the 1.10x alive threshold. Sampled cellulose spans show computeNonbonded falling from 1722 to 1436 us per force invocation, while the new gather contributes 350 us and index scatter contributes 212 us. These spans include warm-up and minimization and overlap; they are supporting observations, not exact additive timings. Tail-window analysis remains uneven (short kernels can be absent in sampled traces) and cannot support a numerical upper bound. Source review confirms the index passes are guarded by the existing rebuild flag.

Step (b) is not justified by these screens: removing pair-kernel atomics does reduce sampled pair work, but endpoint storage and reduction erase that benefit on both large targets. These measurements do not identify a cluster-pair layout that will meet the threshold within the memory cap. No cluster prototype is claimed. The next architecture, if pursued in a new round, should combine tile ownership and spatial culling rather than retain the current endpoint record/gather representation.
