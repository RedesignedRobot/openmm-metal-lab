# Frozen candidate identities

All candidates derive from commit 7484d7bef401f813dc871c1e156578954606d4ea. Source hashes below identify dirty snapshots; no commits were made.

| Build directory | Source hash | Built UTC | Role |
|---|---|---|---|
| /tmp/openmm-metal-bench/ultra-m29-nonbonded | d13e4ffd52bff755826de2ed8efdd523e69a2b53 | 2026-09-26T17:17:16Z | Original MAX_BITS 0 on Apple9 outside LJPME; rejects cellulose. |
| /tmp/openmm-metal-bench/ultra-m29-nonbonded-blocks | 0db954c3f9100149e0684db04db003a10643b03e | 2026-09-26T17:24:08Z | Dense private float slices; dead on both large targets. |
| /tmp/openmm-metal-bench/ultra-m29-nonbonded-records | c3e9ba443b494bd81fc28e2683c20796e21c4782 | 2026-09-26T18:00:38Z | Private tile records; experimental, actual allocation slightly exceeds cap. |
| /tmp/openmm-metal-bench/ultra-m29-nonbonded-selected | eac2e78665e750192febc7c39da33d9aa04c5c9e | 2026-09-26T18:14:40Z | Selected small-system policy; measured single/mixed, M2 old path. |
| /tmp/openmm-metal-bench/ultra-m29-nonbonded-final | 1b48d296829378ba52e62fe7d0ac4177f9dd2daf | 2026-09-26T20:35:26Z | Selected policy plus preservation of full double precision; superseded by gate repair. |

The selected and final snapshots differ only in MetalNonbondedUtilities.cpp: the final condition preserves full double precision. Their single/mixed MAX_BITS decisions, generated force kernels, and buffer layouts are the same. Final-source native build, force gate, md100, detforces, and a direct M2 RF check are tracked separately.

Gate repair: `/tmp/openmm-metal-bench/ultra-m29-nonbonded-gatefix`, source `052eb211f0d0c4739bbacd08486b4cf06feeda04`. Restores single-PME pair policy; build pending, gate pending.
