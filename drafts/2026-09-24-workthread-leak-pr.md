# WorkThread leak PR

Posted 2026-09-24 ~15:40Z as https://github.com/openmm/openmm/pull/5436 from RedesignedRobot:fix-workthread-leak (8813e8542). Disclosure line per the owner: Fable 5.1.

Branch: fix-workthread-leak, commit 8813e8542 on origin/master (laptop worktree /Users/amir/code/mini/wt-workthread). Pushed to the fork.

Title: Delete the WorkThread when a ComputeContext is destroyed

Body:

Since #4833 moved to std::thread, ~ComputeContext() no longer deletes its WorkThread, so every OpenCL, CUDA and HIP Context leaks a thread. On my M2 Mac mini, a loop that creates and destroys OpenCL Contexts fails at Context 2,034 with "thread constructor failed: Resource temporarily unavailable" (macOS allows 2,048 threads per process).

This puts back the delete the pthreads version had. WorkThread's destructor already stops and joins the thread, and syncContexts() leaves its queue empty before a Context goes away.

Tested on my M2 with 3,000 Contexts created and destroyed in one process:
- OpenCL before: 507 threads after 500 Contexts, 2,007 after 2,000, then the failure above.
- OpenCL after: 7 to 11 threads the whole way.
- CPU and Reference: flat before and after.

The OpenCL Single tests give the same results before and after.

Using Claude Fable 5.1, I wrote and tested this.

## Evidence

- Pre-#4833 destructor (68c97c5bf^): `if (thread != NULL) delete thread;`. Leak in every release 8.3.0 through 8.6.1.
- Probe: scratchpad probe.cpp, proc_pidinfo pti_threadnum, DYLD_LIBRARY_PATH swap with the loaded path printed. Raw logs in the session scratchpad results/.
- ctest -R "OpenCL.*Single": 65/66 on both builds, identical per-test status; TestOpenCLAmoebaVdwForceSingle fails randomly on both (energies off about 0.1 percent).
- No upstream issue or PR found (searched WorkThread, thread leak).
