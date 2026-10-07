
## Run 1
- start-date: 2026-09-25T02:18:16.751+03:00
- end-date: 2026-09-25T02:18:22.826+03:00
- duration: 6.075493
- end-reason: Target app exited
- instruments-version: 27.2 (27B5019j)
- template-name: Metal System Trace
- recording-mode: Deferred
- time-limit: 2 minutes
- intruments-recording-settings: 

### ThreadCPUUsage, 1884 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start Time | start-time | 00:00.670.000 | 00:00.680.000 | 00:00.690.000 |
| duration | Duration | duration | 10.00 ms | 10.00 ms | 10.00 ms |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| cpu-usage | CPU Usage | system-cpu-percent | 20.0% | 100.0% | 100.0% |

### metal-gpu-submission-to-command-buffer-id (documentation=Maps between Metal command buffer ID and accelerator ID), 126570 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.906.256 | 00:00.906.256 | 00:00.910.299 |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189050 | 0x154d189052 |
| gpu-submission-id | GPU Submission Id | metal-command-buffer-id | 0x4e18905a | 0x4e189059 | 0x4e189086 |
| segment-id | Segment Id | metal-command-buffer-id | 0x154e189058 | 0x154e189058 | 0x154e189084 |
| segmentlist-id | SegmentList Id | metal-command-buffer-id | 0x0 | 0x0 | 0x0 |
| encoder-id | Encoder Id | metal-command-buffer-id | 0x154d189051 | 0x154d189051 | 0x154d189053 |
| accelerator-id | Accelerator ID | uint64 | 1,463 | 1,463 | 1,463 |
| channel-id | Channel ID | metal-command-buffer-id | 0xffffffffffffffff | 0xffffffffffffffff | 0xffffffffffffffff |
| submission-type | Type | uint32 | 0 | 0 | 0 |
| metadata-1 | Metadata 1 | uint64 | 0 | 0 | 0 |
| metadata-2 | Metadata 2 | uint64 | 0 | 0 | 0 |
| pid | pid | uint32 | 99926 | 99926 | 99926 |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| model | Model | uint32 | 1 | 1 | 1 |
| commit-id | commit-id | uint64 | 0 | 0 | 0 |
| num-coalasced-encoders | # Coalasced Encoders | uint32 | 0 | 0 | 0 |

### process-info (documentation=Associates processes with their process names.), 2148 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.000.000 | 00:00.000.000 | 00:00.000.000 |
| pid | Process ID | pid | 0 | 1 | 561 |
| unique-id | Unique Process ID | uint64 | 0 | 1 | 561 |
| process | Process | process | kernel (0) | launchd (1) | logd (561) |
| process-name | Process Name | string | kernel_task | launchd | logd |

### potential-hangs (target-pid=SINGLE, hangs-threshold=100), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Start | start-time |  |
| duration | Duration | duration |  |
| hang-type | Hang Type | hang-type |  |
| thread | Thread | thread |  |
| process | Process | process |  |

### metal-application-encoders-list (target-pid=SINGLE, documentation=Denotes an a list of encoders created by the tracing Metal application.), 63228 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.900.370 | 00:00.908.800 | 00:00.920.670 |
| duration | Duration | duration | 498.88 µs | 1.45 ms | 1.43 ms |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| frame-number | Frame | gpu-frame-number | Frame 1 | Frame 2 | Frame 3 |
| cmdbuffer-label | Command Buffer | metal-object-label | Command Buffer 0 | Command Buffer 0 | Command Buffer 0 |
| cmdbuffer-label-indexed | Command Buffer (Indexed) | metal-object-label | [0] Command Buffer 0 | [0] Command Buffer 0 | [0] Command Buffer 0 |
| encoder-label | Encoder | metal-object-label | Compute Command 0 | Compute Command 0 | Compute Command 0 |
| encoder-label-indexed | Encoder (Indexed) | metal-object-label | [0] Compute Command 0 | [0] Compute Command 0 | [0] Compute Command 0 |
| event-type | Event Type | metal-event-name | Encoding | Encoding | Encoding |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189052 | 0x154d189054 |
| encoder-id | Encoder Id | metal-command-buffer-id | 0x154d189051 | 0x154d189053 | 0x154d189055 |

### metal-object-label (documentation=Metal Object Label), 95399 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.873.128 | 00:00.879.373 | 00:00.879.400 |
| object-id | object Id | uint64 | 91,487,768,604 | 91,487,768,622 | 91,487,768,623 |
| frame-number | frame | uint32 | 4294967295 | 4294967295 | 4294967295 |
| label | Label | metal-object-label | AGXHeap with guard | AGXHeap without guard | AGXHeap with guard |
| object-type | Type | uint32 | 5 | 5 | 5 |
| pid | PID | uint64 | 99,926 | 99,926 | 99,926 |

### kdebug (codes="0x85,0x92" "0x85,0x93" "0x85,0xae", documentation=Tracing the kernel and some system frameworks.), 876598 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.511.016 | 00:00.534.263 | 00:00.534.344 |
| thread | Thread | thread | thread call kernel-high #3 (0x119fe22) (kernel, pid: 0) | thread call kernel #2 (0x1194e05) (kernel, pid: 0) | thread call kernel #2 (0x1194e05) (kernel, pid: 0) |
| core-index | Core Index | core | CPU 0 (E Core) | CPU 1 (E Core) | CPU 1 (E Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x85 | 0x85 | 0x85 |
| subclass | Subclass | kdebug-subclass | 0x93 | 0x93 | 0x93 |
| code | Code | kdebug-code | 0x35a | 0x32a | 0x32a |
| function | Qualifier | kdebug-func | POINT | START | END |
| arg1 | Argument 1 | kdebug-arg | 0x1 | 0x0 | 0x0 |
| arg2 | Argument 2 | kdebug-arg | 0x17d | 0x0 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x1b80e04 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x1b80e03 | 0x0 | 0x0 |

### kdebug (codes="0x85,0xAF" "0x34,0x11" "0x34,0x0f", documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x31,0xb0" "0x31,0xd0", documentation=Tracing the kernel and some system frameworks.), 1726 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.430.903 | 00:01.253.519 | 00:01.255.815 |
| thread | Thread | thread | Main Thread (0x1a04) (WindowServer, pid: 635) | Main Thread (0x1a04) (WindowServer, pid: 635) | Main Thread (0x1a04) (WindowServer, pid: 635) |
| core-index | Core Index | core | CPU 0 (E Core) | CPU 0 (E Core) | CPU 1 (E Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x31 | 0x31 | 0x31 |
| subclass | Subclass | kdebug-subclass | 0xd0 | 0xd0 | 0xd0 |
| code | Code | kdebug-code | 0x48 | 0x1 | 0x0 |
| function | Qualifier | kdebug-func | POINT | START | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x8 | 0x0 | 0x5643 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x1 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x1d7a0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x452 | 0x0 |

### kdebug (codes="0x85,0x20" "0x31,0x80", documentation=Tracing the kernel and some system frameworks.), 17929 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.413.699 | 00:00.413.771 | 00:00.413.808 |
| thread | Thread | thread |  |  |  |
| core-index | Core Index | core | CPU 41 | CPU 41 | CPU 41 |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x31 | 0x31 | 0x31 |
| subclass | Subclass | kdebug-subclass | 0x80 | 0x80 | 0x80 |
| code | Code | kdebug-code | 0xdb | 0x5d | 0x5e |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x0 | 0x64 | 0x64 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x1 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x0 | 0x0 |

### kdebug (codes="0x2b,0x65", documentation=Tracing the kernel and some system frameworks.), 57 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.531.710 | 00:00.630.861 | 00:00.727.122 |
| thread | Thread | thread | DTServiceHub (0x11ab5bd) (DTServiceHub, pid: 99799) | DTServiceHub (0x11ab5bd) (DTServiceHub, pid: 99799) | DTServiceHub (0x11ab4ab) (DTServiceHub, pid: 99799) |
| core-index | Core Index | core | CPU 4 (P Core) | CPU 8 (P Core) | CPU 5 (P Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x2b | 0x2b | 0x2b |
| subclass | Subclass | kdebug-subclass | 0x65 | 0x65 | 0x65 |
| code | Code | kdebug-code | 0x3 | 0x3 | 0x3 |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x0 | 0x0 |

### kdebug (codes="0x07,0x00" "0x1f,0x05", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 1022 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.677.933 | 00:00.677.933 | 00:00.678.016 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 6 (P Core) | CPU 6 (P Core) | CPU 6 (P Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x1f | 0x1f | 0x1f |
| subclass | Subclass | kdebug-subclass | 0x5 | 0x5 | 0x5 |
| code | Code | kdebug-code | 0xa | 0xb | 0x5 |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x63160222eaffe6e | 0x8d5f2 | 0x5f3d6edbe5247119 |
| arg2 | Argument 2 | kdebug-arg | 0x74ceedcd755617b1 | 0x70ac0000210c90bc | 0xf3176a16061221a6 |
| arg3 | Argument 3 | kdebug-arg | 0x1823ac000 | 0x0 | 0x1054cc000 |
| arg4 | Argument 4 | kdebug-arg | 0x100000d | 0x0 | 0x1a0100000e |

### kdebug (codes="0x85,0x80", documentation=Tracing the kernel and some system frameworks.), 1026888 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.885.143 | 00:00.890.115 | 00:00.890.229 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 7 (P Core) | CPU 7 (P Core) | CPU 7 (P Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x85 | 0x85 | 0x85 |
| subclass | Subclass | kdebug-subclass | 0x80 | 0x80 | 0x80 |
| code | Code | kdebug-code | 0x100 | 0x101 | 0x100 |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x154d18901b | 0x154d18901b | 0x154d18901b |
| arg2 | Argument 2 | kdebug-arg | 0x10883dca8 | 0x10883dca8 | 0x1088360a8 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0xffffffffffffffff | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x1ea | 0x0 |

### kdebug (codes="0x85,0x92" "0x85,0x93" "0x85,0xae" "0x06,0x1b" "0x2b,0x24", documentation=Tracing the kernel and some system frameworks.), 876646 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.412.929 | 00:00.412.929 | 00:00.412.929 |
| thread | Thread | thread | com.apple.dt.instruments.dtsecur (0x11ab4b1) (com.apple.dt.i | com.apple.dt.instruments.dtsecur (0x11ab4b1) (com.apple.dt.i | com.apple.dt.instruments.dtsecur (0x11ab4b1) (com.apple.dt.i |
| core-index | Core Index | core | CPU 7 (P Core) | CPU 7 (P Core) | CPU 7 (P Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | DRIVERS (0x06) | DRIVERS (0x06) | DRIVERS (0x06) |
| subclass | Subclass | kdebug-subclass | 0x1b | 0x1b | 0x1b |
| code | Code | kdebug-code | 0xd | 0xe | 0xd |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0xfffffe189c21bc00 | 0xfffffe189c21bc00 | 0xfffffe189c21bc00 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x0 | 0x0 |

### kdebug (codes="0x85,0x3" "0x85,0x90" "0x85,0xA9", documentation=Tracing the kernel and some system frameworks.), 314678 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.907.174 | 00:00.907.198 | 00:00.907.231 |
| thread | Thread | thread |  |  |  |
| core-index | Core Index | core | CPU 65 | CPU 65 | CPU 65 |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x85 | 0x85 | 0x85 |
| subclass | Subclass | kdebug-subclass | 0x90 | 0x90 | 0x90 |
| code | Code | kdebug-code | 0x54 | 0x7 | 0x2c |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x0 | 0x4e189059 | 0x4e189059 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x0 | 0x3e00000000 |
| arg3 | Argument 3 | kdebug-arg | 0xfffffc20c0cc0000 | 0x0 | 0x2a2ab117b1b |
| arg4 | Argument 4 | kdebug-arg | 0x1c | 0xfffffc20c0cc0000 | 0x2a2ab117c67 |

### kdebug (codes="0x2b,0x2b", documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x34,0x11" "0x34,0x0f", documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x85,0xc2", documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x85,0x12", documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x85,0x30", callstack=user, documentation=Tracing the kernel and some system frameworks.), 42172 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:01.258.560 | 00:01.258.562 | 00:01.259.151 |
| thread | Thread | thread | com.apple.windowserver.root_queue (0x1191297) (WindowServer, | com.apple.windowserver.root_queue (0x1191297) (WindowServer, | com.apple.windowserver.root_queue (0x1191297) (WindowServer, |
| core-index | Core Index | core | CPU 0 (E Core) | CPU 0 (E Core) | CPU 2 (E Core) |
| thread-state | Thread State | thread-state | Running | Running | Running |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt | PC:0x1828f5914, 14 frames, 1 regs, pid: 635 | PC:0x1828f5914, 14 frames, 1 regs, pid: 635 | PC:0x1828f5914, 16 frames, 1 regs, pid: 635 |
| class | Class | kdebug-class | 0x85 | 0x85 | 0x85 |
| subclass | Subclass | kdebug-subclass | 0x30 | 0x30 | 0x30 |
| code | Code | kdebug-code | 0x3 | 0x3 | 0x4 |
| function | Qualifier | kdebug-func | START | END | START |
| arg1 | Argument 1 | kdebug-arg | 0x3ac1a69 | 0x3ac1a69 | 0x3ac1a69 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x0 | 0x0 |

### kdebug (codes="0x85,0x1" "0x85,0x8", callstack=user, documentation=Tracing the kernel and some system frameworks.), 1161855 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.872.454 | 00:00.873.125 | 00:00.873.128 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 7 (P Core) | CPU 6 (P Core) | CPU 6 (P Core) |
| thread-state | Thread State | thread-state | Running | Running | Running |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt | PC:0x1828f5914, 32 frames, 1 regs, pid: 99926 | PC:0x1828f5914, 36 frames, 1 regs, pid: 99926 | PC:0x1828f5914, 37 frames, 1 regs, pid: 99926 |
| class | Class | kdebug-class | 0x85 | 0x85 | 0x85 |
| subclass | Subclass | kdebug-subclass | 0x8 | 0x8 | 0x8 |
| code | Code | kdebug-code | 0xb | 0xe | 0x0 |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x154d18901b | 0x154d18901c | 0x154d18901c |
| arg2 | Argument 2 | kdebug-arg | 0x154d18901b | 0x10000 | 0x70ac0000210c94a8 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x5b7 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x10000 | 0x0 |

### kdebug (codes="0x85,0xc0" "0x85,0xc1" "0x31,0xca", documentation=Tracing the kernel and some system frameworks.), 17403 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.414.613 | 00:00.414.619 | 00:00.417.814 |
| thread | Thread | thread | com.apple.coreanimation.display.external-7 (0x1bc7) (WindowS | com.apple.coreanimation.display.external-7 (0x1bc7) (WindowS | com.apple.coreanimation.cursor.external-7 (0x1bce) (WindowSe |
| core-index | Core Index | core | CPU 2 (E Core) | CPU 2 (E Core) | CPU 0 (E Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x31 | 0x31 | 0x31 |
| subclass | Subclass | kdebug-subclass | 0xca | 0xca | 0xca |
| code | Code | kdebug-code | 0xa | 0x0 | 0xa |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x77da5ba940 | 0x1e3802 | 0x77da5ba800 |
| arg2 | Argument 2 | kdebug-arg | 0x2a2aa5cb8c7 | 0x2a2aa5cb8c7 | 0x2a2aa5e3f67 |
| arg3 | Argument 3 | kdebug-arg | 0x2a2aa5d1651 | 0x30d40 | 0x2a2aa5e426e |
| arg4 | Argument 4 | kdebug-arg | 0x30d40 | 0x0 | 0x30d40 |

### kdebug (codes="0x1f,0x7", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 1428 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.677.681 | 00:00.677.848 | 00:00.677.849 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 6 (P Core) | CPU 6 (P Core) | CPU 6 (P Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x1f | 0x1f | 0x1f |
| subclass | Subclass | kdebug-subclass | 0x7 | 0x7 | 0x7 |
| code | Code | kdebug-code | 0xd | 0xc | 0xc |
| function | Qualifier | kdebug-func | POINT | START | END |
| arg1 | Argument 1 | kdebug-arg | 0x0 | 0x1 | 0x1 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x0 | 0x0 |

### kdebug (codes="0x2b,0xd8", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x2b,0x87", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x1,0x25", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x2d,*", callstack=user, target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x31,0xca", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### kdebug (codes="0x07,0x00", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 134 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.867.814 | 00:00.868.595 | 00:00.878.632 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 4 (P Core) | CPU 7 (P Core) | CPU 4 (P Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | TRACE (0x07) | TRACE (0x07) | TRACE (0x07) |
| subclass | Subclass | kdebug-subclass | 0x0 | 0x0 | 0x0 |
| code | Code | kdebug-code | 0x1 | 0x1 | 0x1 |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x11ab9ef | 0x11ab9f0 | 0x11ab9f1 |
| arg2 | Argument 2 | kdebug-arg | 0x18656 | 0x18656 | 0x18656 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x28c714 | 0x28c714 | 0x28c714 |

### kdebug (codes="0x2b,0xdc", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 15 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.679.752 | 00:00.679.757 | 00:00.679.768 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 6 (P Core) | CPU 6 (P Core) | CPU 6 (P Core) |
| thread-state | Thread State | thread-state |  |  |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x2b | 0x2b | 0x2b |
| subclass | Subclass | kdebug-subclass | 0xdc | 0xdc | 0xdc |
| code | Code | kdebug-code | 0x4 | 0x4 | 0x4 |
| function | Qualifier | kdebug-func | START | POINT | POINT |
| arg1 | Argument 1 | kdebug-arg | 0x0 | 0x1 | 0x2 |
| arg2 | Argument 2 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x0 | 0x0 |

### kdebug (codes="0x85,0x9" "0x85,0x18", callstack=user, documentation=Tracing the kernel and some system frameworks.), 3025511 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.534.262 | 00:00.534.344 | 00:00.786.328 |
| thread | Thread | thread | thread call kernel #2 (0x1194e05) (kernel, pid: 0) | thread call kernel #2 (0x1194e05) (kernel, pid: 0) | thread call kernel #2 (0x1194e05) (kernel, pid: 0) |
| core-index | Core Index | core | CPU 1 (E Core) | CPU 1 (E Core) | CPU 2 (E Core) |
| thread-state | Thread State | thread-state | Running | Running | Running |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |  |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |  |  |
| class | Class | kdebug-class | 0x85 | 0x85 | 0x85 |
| subclass | Subclass | kdebug-subclass | 0x18 | 0x18 | 0x18 |
| code | Code | kdebug-code | 0x8 | 0x8 | 0x8 |
| function | Qualifier | kdebug-func | START | END | START |
| arg1 | Argument 1 | kdebug-arg | 0x1000005b7 | 0x1000005b7 | 0x1000005b7 |
| arg2 | Argument 2 | kdebug-arg | 0x61e30000 | 0x61e30000 | 0x61e30000 |
| arg3 | Argument 3 | kdebug-arg | 0x0 | 0x0 | 0x0 |
| arg4 | Argument 4 | kdebug-arg | 0x0 | 0x0 | 0x0 |

### kdebug (codes="0x85,0x2", callstack=user, documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### dyld-library-load (target-pid=SINGLE), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Start | start-time |  |
| duration | Duration | duration |  |
| thread | Thread | thread |  |
| process | Process | process |  |
| backtrace | Backtrace | tagged-backtrace |  |
| type | Type | string |  |
| uuid | Library UUID | uuid |  |
| path | Path | file-path |  |
| load-address | Load Address | address |  |
| track-containment-level | Containment Level | containment-level |  |
| color | Containment Color | event-concept |  |

### metal-visual-highlight-chain-gpu (documentation=Visual highlight for Metal System Trace), 63341 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.907.221 | 00:00.910.423 | 00:00.923.105 |
| root-id | Root ID | uint64 | 91,487,768,656 | 91,487,768,658 | 91,487,768,660 |
| block-id | Block ID | uint64 | 1 | 2 | 3 |

### gpu-shader-profiler-sample (documentation=GPU Shader Profiler Sample), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | event-time |  |
| pcs | PCs | uint64-array |  |
| num-pcs | Num PCs | uint32 |  |

### gpu-performance-state-info (requested-consistent-state=0, documentation=GPU Performance State Info), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| timestamp | Timestamp | event-time | 00:00.000.000 |
| accelerator-id | Accelerator ID | uint64 | 4,294,968,759 |
| consistent-state-available | Consistent State Available | boolean | Yes |
| consistent-state-enabled | Consistent State Enabled | boolean | No |
| consistent-state-sustained | Consistent State Sustained | boolean | No |
| consistent-state-mapping | Consistent State Mapping | uint32 | 50661376 |
| consistent-state | Consistent State | uint32 | 0 |

### hang-risks (detect-priority-inversions=0, target-pid=SINGLE), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| process | Process | process |  |
| message | Message | narrative |  |
| severity | Severity | short-string |  |
| event-type | Event Type | event-type |  |
| backtrace | Backtrace | text-backtrace |  |
| thread | Thread | thread |  |

### metal-wired-sysmem-level-interval (documentation=Denotes wired system memory level), 312 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.000.000 | 00:00.879.201 | 00:00.879.208 |
| duration | Duration | duration | 879.20 ms | 6.83 µs | 21.77 ms |
| bytes | Bytes | size-in-bytes | 0 Bytes | 1.53 GiB | 1.53 GiB |
| color | Color | render-buffer-depth | 1 | 1 | 1 |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| event-label | Description | narrative | 0 Bytes | 1.53 GiB | 1.53 GiB |
| event-type | Event Type | metal-memory-level-event | Wired System Memory | Wired System Memory | Wired System Memory |

### metal-current-allocated-size (target-pid=SINGLE, documentation=Marks the total allocated Metal device memory of the app (MTLDevice.currentAllocatedSize)), 289 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.873.125 | 00:00.873.181 | 00:00.879.281 |
| duration | Duration | duration | 55.71 µs | 6.10 ms | 7.12 µs |
| end | End | start-time | 00:00.873.181 | 00:00.879.281 | 00:00.879.288 |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| current-allocated-size | Current Allocated Size | size-in-bytes | 80.00 KiB | 208.00 KiB | 208.00 KiB |
| label | Label | formatted-label | 80.00 KiB | 208.00 KiB | 208.00 KiB |
| track-name | Track | formatted-label | python (99926) | python (99926) | python (99926) |
| color | Color | render-buffer-depth | 1 | 1 | 1 |

### display-compositor-events-interval (documentation=Shows generic compositor events), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Start Time | start-time |  |
| duration | Duration | duration |  |
| event-name | Event Name | display-compositor-event-name |  |
| vsync-id | VSync ID | displayed-surface-swap |  |
| compositor-name | Compositor Name | display-compositor-name |  |
| color | Color | render-buffer-depth |  |
| event-priority | Priority | metal-workload-priority |  |
| event-label | Description | narrative |  |
| event-depth | Depth | metal-nesting-level |  |
| connection-UUID | Connection UUID | connection-uuid64 |  |

### metal-application-intervals (target-pid=SINGLE, documentation=Denotes an interesting period of activity in the Metal applications.), 94880 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.900.359 | 00:00.900.370 | 00:00.908.795 |
| duration | Duration | duration | 517.50 µs | 498.88 µs | 1.46 ms |
| process | Owner | process | python (99926) | python (99926) | python (99926) |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| event-depth | Depth | metal-nesting-level | 14 | 15 | 14 |
| event-label | Event | formatted-label | Command Buffer 0 (Frame 1) (python (99926)) | Compute Command 0 (Main Thread (0x11ab5b7) (python, pid: 999 | Command Buffer 0 (Frame 2) (python (99926)) |
| event-priority | Priority | metal-workload-priority | 0x1 | 0x1 | 0x1 |
| connection-UUID | Connection UUID | connection-uuid64 | 17 | 23 | 33 |
| color | Color | render-buffer-depth | 0 | 0 | 0 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| event-type | Event Type | metal-event-name | Encoding | Encoding | Encoding |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189050 | 0x154d189052 |
| encoder-id | Encoder Id | metal-command-buffer-id | 0xffffffffffffffff | 0x154d189051 | 0xffffffffffffffff |

### visual-chain (content=metal-connection-chains, target-pid=SINGLE, documentation=Connects multiple objects on a graph to be treated a single, selectable chain of events.), 263701 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | sample-time | 00:00.900.869 | 00:00.900.869 | 00:00.900.869 |
| uuid | UUID | connection-uuid64 | 23 | 17 | 4229 |
| uuid-chain | UUID Chain | visual-uuid-chain | (23,17,4229,4211,1) | (23,17,4229,4211,1) | (23,17,4229,4211,1) |
| route | Route | connection-route | CB | CB | CB |

### gpu-performance-state-intervals (requested-consistent-state=0, documentation=Denotes the current and induced performance state of the device.), 7 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start | start-time | 00:00.922.304 | 00:00.929.937 | 00:00.946.138 |
| duration | Duration | duration | 5.05 ms | 5.23 ms | 7.75 ms |
| gpu-performance-state | GPU Performance State | gpu-performance-state | Minimum | Minimum | Maximum |
| track-label | Track | string | M3 Ultra | M3 Ultra | M3 Ultra |
| is-induced | Is Induced | boolean | Yes | Yes | Yes |
| narrative | Narrative | narrative | Minimum GPU Performance state due to active device condition | Minimum GPU Performance state due to active device condition | Maximum GPU Performance state due to active device condition |
| event-type | Event Type | gpu-event-name | GPU Performance State | GPU Performance State | GPU Performance State |

### metal-ar-events (documentation=Marks AR events), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | start-time |  |
| event-type | Event Type | ar-event-name |  |
| event-name | Event Name | ar-event-name |  |
| process | Process | process |  |
| thread | Thread | thread |  |
| event-icon | Event Icon | metal-event |  |
| event-label | Note | narrative |  |
| frame-number | Frame # | uint32 |  |

### gpu-aps-stream (documentation=GPU APS Stream), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | event-time |  |
| buffer-index | Buffer Index | uint32 |  |
| source-index | Source Index | uint32 |  |
| source-type | Source Type | uint32 |  |
| stream | Stream | data |  |

### device-thermal-state-intervals (documentation=Denotes the current thermal state of the device.), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| start | Start | start-time | 00:00.000.000 |
| duration | Duration | duration | 6.08 s |
| end | End | start-time | 00:06.075.493 |
| thermal-state | Thermal State | thermal-state | Nominal |
| track-label | Track | string | Current |
| is-induced | Is Induced | boolean | No |
| narrative | Narrative | narrative | Nominal thermal state |

### time-info (documentation=Raw data needed transform a mach-absolute-time to a trace relative timestamp), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| update-time | Update Time | sample-time | 00:00.000.000 |
| mabs-epoch | Run Epoch | mach-absolute-time | 2897656234073 |
| mct-epoch | Continuous Epoch | mach-continuous-time | 2897656234073 |
| timebase-info | Timebase | mach-timebase-info | 125/3 |
| trace-start-time | Trace Start Time | time-since-epoch | 25/9/26, 2:18:16 AM |

### mps-hw-intervals (target-pid=SINGLE, documentation=Denotes an interesting period of activity caused by Metal Applications.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Creation | start-time |  |
| duration | Duration | duration |  |
| channel-name | Channel Name | mps-event-name |  |
| frame-number | Frame | gpu-frame-number |  |
| start-latency | CPU to GPU Latency | duration |  |
| event-depth | Depth | metal-nesting-level |  |
| event-label | Label | formatted-label |  |
| state | State | gpu-state |  |
| connection-UUID | Connection UUID | connection-uuid64 |  |
| color | Color | render-buffer-depth |  |
| process | Process | process |  |
| gpu | Metal Device | metal-device-name |  |
| channel-subtitle | Channel Subtitle | metal-object-label |  |

### metal-gpu-state-intervals (documentation=Denotes GPU state (on/off) periods), 126682 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.907.208 | 00:00.907.221 | 00:00.910.416 |
| duration | Duration | duration | 13.83 µs | 3.19 ms | 6.83 µs |
| state | State | gpu-state | Active | Idle | Active |
| label | Label | formatted-label | 1 channels active | Idle | 1 channels active |
| color | Color | render-buffer-depth | 3 | 1000 | 3 |
| num-events | # Events | uint32 | 1 | 0 | 1 |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |

### ca-client-buffer-wait-interval (documentation=Denotes an waiting for next available drawable.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Creation | start-time |  |
| duration | Duration | duration |  |
| thread | Thread | thread |  |

### metal-object-dependency-chain-driver (track-id-base=2000, documentation=Object Dependency for Metal System Trace), 94967 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| in-time | In Time | start-time | 00:00.900.921 | 00:00.900.924 | 00:00.910.277 |
| root-id | Root ID | uint64 | 91,487,768,656 | 91,504,545,880 | 91,487,768,658 |
| out-time | Out Time | uint64 | 906,299,458 | 906,299,041 | 910,308,666 |
| block-id | Block ID | uint64 | 4,211 | 4,229 | 4,275 |
| color | Color | uint32 | 0 | 0 | 0 |
| track-id | Track | uint32 | 2000 | 2000 | 2000 |

### display-surface-swap (documentation=Describes display surface swap events.), 15 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:01.263.627 | 00:01.513.627 | 00:01.721.961 |
| delay | Delay | start-time | 00:00.004.439 | 00:00.004.143 | 00:00.004.305 |
| display-name | Display Name | display-name | Built-In Display | Built-In Display | Built-In Display |
| surface-id | Surface ID | displayed-surface-swap | 0x230 | 0x48a | 0x230 |
| framebuffer-index | Framebuffer Index | uint32 | 41 | 41 | 41 |
| swap-id | Swap ID | displayed-surface-swap | 0xe34ad | 0xe34ae | 0xe34af |
| color | Color | render-buffer-depth | 0 | 1 | 0 |
| pixel-format | Pixel Format | string |  |  |  |
| hid-time | HID Time | start-time | 00:00.000.000 | 00:00.000.000 | 00:00.000.000 |
| generation-time | Generation Time | start-time | 00:01.257.521 | 00:01.507.573 | 00:01.715.886 |
| min-quanta | Min Quanta | uint32 | 1 | 1 | 1 |
| desired-presentation-time | Desired Presentation Time | start-time | 00:01.262.084 | 00:01.512.085 | 00:01.720.419 |
| layer1-surface-id | HW Layer1 Surface ID | displayed-surface-swap |  |  |  |
| layer2-surface-id | HW Layer2 Surface ID | displayed-surface-swap |  |  |  |
| layer1-pixel-format | HW Layer1 Pixel Format | string |  |  |  |
| layer2-pixel-format | HW Layer2 Pixel Format | string |  |  |  |

### kdebug (codes="33,0x11", target=SINGLE, documentation=Tracing the kernel and some system frameworks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |
| thread-state | Thread State | thread-state |  |
| cp-kernel-callstack | CP Kernel Callstack | kperf-bt |  |
| cp-user-callstack | CP User Callstack | kperf-bt |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| arg1 | Argument 1 | kdebug-arg |  |
| arg2 | Argument 2 | kdebug-arg |  |
| arg3 | Argument 3 | kdebug-arg |  |
| arg4 | Argument 4 | kdebug-arg |  |

### metal-object-dependency-chain-app (track-id-base=1000, documentation=Object Dependency for Metal System Trace), 31652 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| in-time | In Time | start-time | 00:00.900.359 | 00:00.908.795 | 00:00.920.666 |
| root-id | Root ID | uint64 | 91,487,768,656 | 91,487,768,658 | 91,487,768,660 |
| out-time | Out Time | uint64 | 900,876,875 | 910,257,541 | 922,101,500 |
| block-id | Block ID | uint64 | 17 | 33 | 40 |
| color | Color | uint32 | 0 | 0 | 0 |
| track-id | Track | uint32 | 1014 | 1014 | 1014 |

### tick (frequency=100, documentation=Provides modelers with a regular reference time for modeling fixed time-based statistics. The ticks are evenly spaced with a configurable frequency specifying the number of events to generate per second, so a tick schema with a frequency of 10 will generate a row every 100ms.), 608 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | sample-time | 00:00.010.000 | 00:00.020.000 | 00:00.030.000 |

### tick (frequency=1, documentation=Provides modelers with a regular reference time for modeling fixed time-based statistics. The ticks are evenly spaced with a configurable frequency specifying the number of events to generate per second, so a tick schema with a frequency of 10 will generate a row every 100ms.), 7 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | sample-time | 00:01.000.000 | 00:02.000.000 | 00:03.000.000 |

### tick (frequency=10, documentation=Provides modelers with a regular reference time for modeling fixed time-based statistics. The ticks are evenly spaced with a configurable frequency specifying the number of events to generate per second, so a tick schema with a frequency of 10 will generate a row every 100ms.), 61 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | sample-time | 00:00.100.000 | 00:00.200.000 | 00:00.300.000 |

### tick (documentation=Provides modelers with a regular reference time for modeling fixed time-based statistics. The ticks are evenly spaced with a configurable frequency specifying the number of events to generate per second, so a tick schema with a frequency of 10 will generate a row every 100ms.), 608 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | sample-time | 00:00.010.000 | 00:00.020.000 | 00:00.030.000 |

### metal-resource-allocations (target-pid=SINGLE, documentation=Marks a point in time where the application may created a Metal resource), 179 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.873.178 | 00:00.879.276 | 00:00.879.286 |
| duration | Lifetime | duration |  |  |  |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| resource-id | ID | gpu-hardware-trace | 0x154d18901d | 0x154d189021 | 0x154d189022 |
| parent-resource-id | Parent ID | gpu-hardware-trace | 0xffffffffffffffff | 0xffffffffffffffff | 0xffffffffffffffff |
| label | Label | metal-object-label | Resource 0x154d18901d | Resource 0x154d189021 | Resource 0x154d189022 |
| vidmem-bytes | Video Memory Bytes | size-in-bytes |  |  |  |
| sysmem-bytes | System Memory Bytes | size-in-bytes | 16.00 KiB | 128.00 KiB | 128.00 KiB |
| resource-size | Resource Size | size-in-bytes | 16.00 KiB | 128.00 KiB | 128.00 KiB |
| event-label | Description | formatted-label | Resource 0x154d18901d (16.00 KiB, Shared) | Resource 0x154d189021 (128.00 KiB, Shared) | Resource 0x154d189022 (128.00 KiB, Shared) |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| resource-type | Resource Type | metal-object-label | Buffer | Buffer | Buffer |
| event-type | Event Type | gpu-memory-event-name | Allocation | Allocation | Allocation |
| backtrace | Backtrace | tagged-backtrace |  |  |  |
| event-icon | Event Icon | metal-event | Buffer | Buffer | Buffer |

### metal-visual-highlight-chain-driver (documentation=Visual highlight for Metal System Trace), 94967 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.906.299 | 00:00.906.299 | 00:00.910.308 |
| root-id | Root ID | uint64 | 91,487,768,656 | 91,487,768,656 | 91,487,768,658 |
| block-id | Block ID | uint64 | 4,229 | 4,211 | 4,276 |

### display-vsyncs-interval (documentation=Marks display vsyncs), 578 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:01.263.627 | 00:01.271.960 | 00:01.280.294 |
| duration | Duration | duration | 1 ns | 1 ns | 1 ns |
| display-name | Display Name | display-name | Display 1 | Display 1 | Display 1 |
| color | Color | render-buffer-depth | 2 | 2 | 2 |
| event-label | Label | narrative | VSync Request 00:01.263.627 | VSync Request 00:01.271.960 | VSync Request 00:01.280.294 |
| event | Event | vsync-event | VSYNC | VSYNC | VSYNC |

### metal-shader-profiler-shader-list (target-pid=SINGLE, documentation=Denotes compiled shaders), 2437 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.932.101 | 00:00.932.103 | 00:00.932.104 |
| name | Shader Name | metal-object-label | copyInteractionCounts (45) | findBlocksWithInteractions (13) | sortBoxData (12) |
| label | Function Label | metal-object-label |  |  |  |
| pso-name | Pipeline | metal-object-label | copyInteractionCounts (45) | findBlocksWithInteractions (13) | sortBoxData (12) |
| id | ID | uint64 | 45 | 13 | 12 |
| pc-start | PC Start | uint64 | 1,099,511,693,056 | 1,099,512,494,912 | 1,099,512,494,016 |
| pc-end | PC End | uint64 | 1,099,511,693,146 | 1,099,512,497,716 | 1,099,512,494,796 |
| shader-type | Shader Type | string | Compute | Compute | Compute |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |

### metal-command-buffer-completed (documentation=Marks when Metal Command Buffer are completed), 31682 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.907.346 | 00:00.910.537 | 00:00.923.236 |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189052 | 0x154d189054 |
| commit-id | commit-id | uint64 | 0 | 0 | 0 |

### metal-visual-highlight-chain-app (documentation=Visual highlight for Metal System Trace), 105408 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.900.869 | 00:00.900.876 | 00:00.910.252 |
| root-id | Root ID | uint64 | 91,487,768,656 | 91,487,768,656 | 91,487,768,658 |
| block-id | Block ID | uint64 | 23 | 17 | 34 |

### gpu-counter-value (documentation=GPU Counter Value), 1696110 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | event-time | 00:00.261.183 | 00:00.261.186 | 00:00.261.189 |
| counter-id | Counter ID | uint32 | 0 | 0 | 0 |
| value | Value | fixed-decimal | 0.0000 | 0.0000 | 0.0000 |
| accelerator-id | Accelerator ID | uint64 | 4,294,968,759 | 4,294,968,759 | 4,294,968,759 |
| sample-index | Sample ID | uint32 | 0 | 1 | 2 |
| ring-buffer-index | Ring Buffer Index | uint32 | 0 | 0 | 0 |

### metal-residency-set-usage-event (documentation=Denotes a MTLResidencySet usage), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | event-time |  |
| residency-set-id | Set Id | uint64 |  |
| label | Residency Set Label | metal-object-label |  |
| metal-object-label | Label | metal-object-label |  |
| event-label | Description | narrative |  |
| event-type | Event Type | metal-residency-set-usage-event |  |
| allocated-size | Allocated Size | size-in-bytes |  |
| num-allocations | Allocation Count | uint64 |  |
| process | Process | process |  |
| gpu | Metal Device | metal-device-name |  |
| event-icon | Event Icon | metal-event |  |
| lane | Lane | string |  |

### metal-driver-event-per-thread-intervals (target-pid=SINGLE, documentation=Denotes an interesting period of memory activity in the Metal driver.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Creation | start-time |  |
| duration | Duration | duration |  |
| gpu-driver-name | GPU Driver Name | gpu-driver-name |  |
| event-type | Event Type | gpu-driver-name |  |
| event-depth | Depth | metal-nesting-level |  |
| event-label | Event | formatted-label |  |
| event-priority | Priority | metal-workload-priority |  |
| connection-UUID | Connection UUID | connection-uuid64 |  |
| color | Color | render-buffer-depth |  |
| process | Process | process |  |
| thread | Thread | thread |  |
| gpu | Metal Device | metal-device-name |  |
| resource-id | Resource ID | metal-command-buffer-id |  |
| show-per-thread | Show per Thread | boolean |  |

### thread-info (documentation=Associates threads with their owning process.), 7232 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.000.000 | 00:00.000.000 | 00:00.000.000 |
| pid | Process ID | pid | 0 | 0 | 0 |
| tid | Thread ID | tid | 0x65 | 0x66 | 0x67 |
| process | Process | process | kernel (0) | kernel (0) | kernel (0) |
| thread | Thread | thread | VM_pageout_scan (0x65) (kernel, pid: 0) | idle #4 (0x66) (kernel, pid: 0) | sched_maintenance_thread (0x67) (kernel, pid: 0) |
| name | Thread Name | thread-name | VM_pageout_scan  0x65 | idle #4  0x66 | sched_maintenance_thread  0x67 |
| main-thread | Main Thread | boolean | No | No | No |

### display-compositor-interval (target-pid=SINGLE, documentation=Shows compositor events.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Time | start-time |  |
| duration | Duration | duration |  |
| compositor-name | Compositor Name | display-compositor-name |  |
| connection-UUID | Connection UUID | connection-uuid64 |  |
| vsync-id | VSync ID | displayed-surface-swap |  |
| color | Color | render-buffer-depth |  |
| event-priority | Priority | metal-workload-priority |  |
| event-label | Label | narrative |  |
| category | Category | display-compositor-event-name |  |
| event-depth | Depth | metal-nesting-level |  |

### metal-object-dependency-chain-display (track-id-base=2000, documentation=VObject Dependency for Metal System Trace), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| in-time | In Time | start-time |  |
| root-id | Root ID | uint64 |  |
| out-time | Out Time | uint64 |  |
| block-id | Block ID | uint64 |  |
| color | Color | uint32 |  |
| track-id | Track | uint32 |  |

### metal-visual-highlight-chain-display (documentation=Visual Highlight for Metal System Trace), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | start-time |  |
| root-id | Root ID | uint64 |  |
| block-id | Block ID | uint64 |  |

### metal-command-buffer-error (documentation=Marks Metal command buffer error), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | start-time |  |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id |  |
| error-code | Error Code | uint32 |  |

### metal-driver-intervals (target-pid=SINGLE, documentation=Denotes an interesting period of activity in the Metal driver.), 94967 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.900.921 | 00:00.900.924 | 00:00.910.277 |
| duration | Duration | duration | 5.38 ms | 5.37 ms | 31.08 µs |
| gpu-driver-name | GPU Driver Name | gpu-driver-name | Driver Processing | Driver Processing | Driver Processing |
| event-type | Event Type | metal-object-label | Command Buffer | Command Encoder | Command Buffer |
| event-depth | Depth | metal-nesting-level | 0 | 1 | 0 |
| event-label | Event | formatted-label | Command Buffer 0 (python (0x11ab9f0) (python, pid: 99926)) | Compute Command 0 | Command Buffer 0 (python (0x11aba0f) (python, pid: 99926)) |
| event-priority | Priority | metal-workload-priority | 0x0 | 0x0 | 0x0 |
| connection-UUID | Connection UUID | connection-uuid64 | 4211 | 4229 | 4275 |
| color | Color | render-buffer-depth | 0 | 0 | 0 |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| thread | Thread | thread | python (0x11ab9f0) (python, pid: 99926) | python (0x11ab9f0) (python, pid: 99926) | python (0x11aba0f) (python, pid: 99926) |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| object-id | Object ID | metal-command-buffer-id | 0xffffffffffffffff | 0xffffffffffffffff | 0xffffffffffffffff |
| lane | Lane | formatted-label |   |   |   |

### metal-residency-set-resource-event (documentation=Denotes a MTLResidencySet resource), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | event-time |  |
| residency-set-id | Set Id | uint64 |  |
| label | Label | metal-object-label |  |
| event-type | Event Type | metal-residency-set-resource-event |  |
| allocation-id | Allocation Id | metal-command-buffer-id |  |
| allocation-type | Allocation Type | metal-object-label |  |
| allocation-size | Allocated Size | size-in-bytes |  |
| allocation-label | Allocation label | metal-object-label |  |
| process | Process | process |  |
| gpu | Metal Device | metal-device-name |  |

### life-cycle-period (target-pid=SINGLE, documentation=Identifies where an application is in its lifecycle.), 2 rows

| mnemonic | name | engineering type | row 1 | row 2 |
|---|---|---|---|---|
| start | Start | start-time | 00:00.677.681 | 00:00.680.115 |
| group | Group | string | States | States |
| lane | Layout ID | layout-id | 0 | 0 |
| duration | Duration | duration | 2.43 ms | 116.62 µs |
| process | process | process | python (99926) | python (99926) |
| period | Lifecycle Period | app-period | Initializing - System Interface Initialization | Initializing - Static Runtime Initialization |
| narrative | Narrative | narrative | The system frameworks took 2.43 ms to initialize. | Initializing – Static Runtime Initialization |

### os-signpost-arg (category=ShaderTimeline, subsystem="com.apple.Metal.AGXSignposts", documentation=Holds a signpost metadata argument from the OS's Unified Logging and Tracing component.), 38840 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.932.101 | 00:00.932.101 | 00:00.932.101 |
| format-string | Format String | format-string | Name=%{public,signpost.description:attribute}s               | Name=%{public,signpost.description:attribute}s               | Name=%{public,signpost.description:attribute}s               |
| identifier | Signpost identifier | os-signpost-identifier | OS_SIGNPOST_ID_EXCLUSIVE | OS_SIGNPOST_ID_EXCLUSIVE | OS_SIGNPOST_ID_EXCLUSIVE |
| signpost-name | Signpost Name | signpost-name | FunctionCompiled | FunctionCompiled | FunctionCompiled |
| name | Name | string | arg0 | arg1 | arg2 |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| thread | Thread | thread | python (0x11aba0f) (python, pid: 99926) | python (0x11aba0f) (python, pid: 99926) | python (0x11aba0f) (python, pid: 99926) |
| subsystem | Subsystem | subsystem | com.apple.Metal.AGXSignposts | com.apple.Metal.AGXSignposts | com.apple.Metal.AGXSignposts |
| category | Category | category | ShaderTimeline | ShaderTimeline | ShaderTimeline |
| value | Value | any | copyInteractionCounts |  | compute |

### time-sample (sample-rate-micro-seconds=1000, target=SINGLE, callstack=user, all-thread-states=NO, documentation=Holds a raw CPU profiling sample.), 3276 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | sample-time | 00:00.413.135 | 00:00.413.135 | 00:00.678.398 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core |  |  | CPU 6 (P Core) |
| thread-state | Thread State | thread-state | Blocked | Blocked | Running |
| cp-kernel-callstack | Kernel Callstack ID | kperf-bt |  |  |  |
| cp-user-callstack | User Callstack ID | kperf-bt | PC:0x1054d0bf0, 1 frames, 0 regs, pid: 99926 | PC:0x1054d0bf0, 1 frames, 0 regs, pid: 99926 | PC:0x18288ab80, 14 frames, 1 regs, pid: 99926 |
| sample-type | Sample type | time-sample-kind | Stackshot | Stackshot | Timer Fired |

### gpu-shader-profiler-interval (documentation=GPU Shader Profiler Interval), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Creation | start-time |  |
| duration | Duration | duration |  |
| pc | PC | uint64 |  |
| submission-id | Submission Id | uint32 |  |
| datamaster | Datamaster | uint32 |  |

### metal-driver-event-intervals (target-pid=SINGLE, documentation=Denotes an interesting period of memory activity in the Metal driver.), 208 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.900.969 | 00:00.901.038 | 00:00.901.625 |
| duration | Duration | duration | 6.62 µs | 387.08 µs | 3.62 µs |
| gpu-driver-name | GPU Driver Name | gpu-driver-name | Driver Processing | Driver Processing | Driver Processing |
| event-type | Event Type | gpu-driver-name | Wire Memory | Wire Memory | Wire Memory |
| event-depth | Depth | metal-nesting-level | 0 | 0 | 0 |
| event-label | Event | formatted-label | Wire 16.00 KiB System Memory (Success) (python (0x11ab9f0) ( | Wire 31.97 MiB System Memory (Success) (python (0x11ab9f0) ( | Wire 16.00 KiB System Memory (Success) (python (0x11ab9f0) ( |
| event-priority | Priority | metal-workload-priority | 0x0 | 0x0 | 0x0 |
| connection-UUID | Connection UUID | connection-uuid64 | -1 | -1 | -1 |
| color | Color | render-buffer-depth | 0 | 0 | 0 |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| thread | Thread | thread | python (0x11ab9f0) (python, pid: 99926) | python (0x11ab9f0) (python, pid: 99926) | python (0x11ab9f0) (python, pid: 99926) |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| resource-id | Resource ID | metal-command-buffer-id | 0xffffffffffffffff | 0xffffffffffffffff | 0xffffffffffffffff |
| show-per-thread | Show per Thread | boolean |  |  |  |

### displayed-surfaces-interval (target-pid=SINGLE, documentation=Shows when a surface is being displayed.), 14 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Swap Time | start-time | 00:01.263.627 | 00:01.513.627 | 00:01.721.961 |
| duration | Duration | duration | 250.00 ms | 208.33 ms | 541.67 ms |
| cpu-to-display-latency | CPU to Display Latency | duration |  |  |  |
| display-name | Display Name | display-name | Display 1 | Display 1 | Display 1 |
| connection-UUID | Connection UUID | connection-uuid64 | 867 | 1248 | 2131 |
| surface-id | Surface ID | uint64 | 560 | 1,162 | 560 |
| pixel-format | Pixel Format | string |  |  |  |
| color | Color | render-buffer-depth | 0 | 1 | 0 |
| event-priority | Priority | metal-workload-priority | 0x1 | 0x1 | 0x1 |
| event-label | Label | narrative | Surface 560 | Surface 1,162 | Surface 560 |
| category | Category | display-event-name | Display | Display | Display |
| event-depth | Depth | metal-nesting-level | 0 | 0 | 0 |
| direct-to-display | Direct to Display | boolean | No | No | No |
| resolution | Resolution | size-in-pixels |  |  |  |
| detachment-reason | Direct to Display Failing Reason | formatted-label |  |  |  |
| detachment-suggestion | Direct to Display Failing Suggestion | formatted-label |  |  |  |

### display-events-interval (documentation=Shows generic display events), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Start Time | start-time |  |
| duration | Duration | duration |  |
| event-name | Event Name | display-event-name |  |
| surface-id | Surface ID | displayed-surface-swap |  |
| display-name | Display Name | display-name |  |
| color | Color | render-buffer-depth |  |
| event-priority | Priority | metal-workload-priority |  |
| event-label | Description | narrative |  |
| event-depth | Depth | metal-nesting-level |  |
| connection-UUID | Connection UUID | connection-uuid64 |  |

### metal-shader-profiler-intervals (target-pid=SINGLE, documentation=Denotes Shader Timeline intervals), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Start | start-time |  |
| duration | Sample Duration | duration |  |
| name | Shader Name | metal-object-label |  |
| label | Function Label | metal-object-label |  |
| pso-label | Pipeline | metal-object-label |  |
| event-name | Event Name | gpu-event-name |  |
| shader-type | Shader Type | metal-object-label |  |
| percent-of-kick | % GPU Work | percent |  |
| total-kick-percent | % Total GPU Work | percent |  |
| color | Color | render-buffer-depth |  |
| event-priority | Priority | metal-workload-priority |  |
| process | Process | process |  |
| gpu | Metal Device | metal-device-name |  |
| channel-name | Channel Name | gpu-channel-name |  |
| event-depth | Depth | metal-nesting-level |  |
| connection-UUID | Connection UUID | connection-uuid64 |  |

### metal-gpu-intervals (target-pid=SINGLE, documentation=Denotes an interesting period of activity in the GPU.), 63342 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.907.208 | 00:00.910.416 | 00:00.923.091 |
| duration | Duration | duration | 13.83 µs | 6.83 µs | 13.67 µs |
| channel-name | Channel Name | gpu-channel-name | Compute | Compute | Compute |
| frame-number | Frame | gpu-frame-number | Frame 1 | Frame 2 | Frame 3 |
| start-latency | CPU to GPU Latency | duration | 6.33 ms | 159.12 µs | 990.42 µs |
| event-depth | Depth | metal-nesting-level | 0 | 0 | 0 |
| event-label | Label | formatted-label | Command Buffer 0:Compute Command 0   (python (99926)) 0x4e18 | Command Buffer 0:Compute Command 0   (python (99926)) 0x4e18 | Command Buffer 0:Compute Command 0   (python (99926)) 0x4e18 |
| state | State | gpu-state | Active | Active | Active |
| connection-UUID | Connection UUID | connection-uuid64 | 1 | 2 | 3 |
| color | Color | render-buffer-depth | 0 | 0 | 0 |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| channel-subtitle | Channel Subtitle | metal-object-label |  |  |  |
| iosurface-accesses | IOSurface Accesses | formatted-label |  |  |  |
| bytes | Bytes | size-in-bytes | 0 Bytes | 0 Bytes | 0 Bytes |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189052 | 0x154d189054 |
| encoder-id | Encoder Id | metal-command-buffer-id | 0x154d189051 | 0x154d189053 | 0x154d189055 |
| gpu-submission-id | GPU Submission Id | uint64 | 1,310,232,665 | 1,310,232,709 | 1,310,232,742 |

### time-profile (target-pid=SINGLE, context-switch-sampling=0, high-frequency-sampling=0, record-waiting-threads=0, needs-kernel-callstack=0, documentation=When combined with other time-profile samples, creates a statistical picture of where your application is spending its time.), 3274 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Sample Time | sample-time | 00:00.678.398 | 00:00.679.398 | 00:00.680.398 |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| core | Core | core | CPU 6 (P Core) | CPU 6 (P Core) | CPU 6 (P Core) |
| thread-state | State | thread-state | Running | Running | Running |
| weight | Weight | weight | 1.00 ms | 1.00 ms | 1.00 ms |
| stack | Backtrace | tagged-backtrace |  |  |  |

### gpu-performance-device-state-intervals (requested-consistent-state=0, documentation=Denotes the average performance state of the device.), 7 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start | start-time | 00:00.922.304 | 00:00.929.937 | 00:00.946.138 |
| duration | Duration | duration | 5.05 ms | 5.23 ms | 7.75 ms |
| accelerator-id | Accelerator Id | uint64 | 1,463 | 1,463 | 1,463 |
| state | State | uint32 | 1 | 1 | 3 |
| desired-state | Desired State | uint32 | 0 | 0 | 0 |

### gpu-counter-info (counter-profile=0, counter-device=0, shader-profiler=0, documentation=GPU Counter Info), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| timestamp | Timestamp | event-time | 00:00.000.000 |
| counter-id | Counter ID | uint32 | 0 |
| name | Name | gpu-counter-name | RT Unit Active |
| max-value | Max Value | uint64 | 100 |
| accelerator-id | Accelerator ID | uint64 | 4,294,968,759 |
| description | Description | string | Percentage of GPU Cores where raytracing unit is active. |
| group-index | Group Index | uint32 | 1 |
| type | Type | string | Percentage |
| ring-buffer-count | Ring Buffer Count | uint32 | 1 |
| require-weighted-accumulation | Require Weighted Accumulation | boolean | No |
| sample-interval | Sample Interval | uint32 | 0 |

### metal-application-command-buffer-submissions (target-pid=SINGLE, documentation=Marks Metal command buffer submissions), 31652 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Creation | start-time | 00:00.900.359 | 00:00.908.795 | 00:00.920.666 |
| duration | Duration | duration | 517.50 µs | 1.46 ms | 1.44 ms |
| event-type | Event Type | metal-event-name | CommandBufferSubmission | CommandBufferSubmission | CommandBufferSubmission |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| track-label | Track Label | metal-object-label |  |  |  |
| num-encoders | # Encoders | uint32 | 1 | 1 | 1 |
| encoder-time | Encoder Time | duration | 498.88 µs | 1.45 ms | 1.43 ms |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| event-icon | Event Icon | metal-event | Green | Green | Green |
| event-label | Note | narrative | Committed "Command Buffer 0" with 1 encoders | Committed "Command Buffer 0" with 1 encoders | Committed "Command Buffer 0" with 1 encoders |
| encoder-time-label | Encoder Time Label | narrative | 498.88 µs Metal Encoder duration (python (99926)) | 1.45 ms Metal Encoder duration (python (99926)) | 1.43 ms Metal Encoder duration (python (99926)) |
| frame-number | Frame # | uint32 | 1 | 2 | 3 |
| color | Color | render-buffer-depth | 0 | 0 | 0 |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189052 | 0x154d189054 |

### device-gpu-info (documentation=Marks related info about GPUs connected to the machine.), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| timestamp | Timestamp | event-time | 00:00.000.000 |
| accelerator-id | Accelerator ID | uint64 | 4,294,968,759 |
| device-name | Device Name | metal-object-label | M3 Ultra |
| vendor-name | Vendor Name | metal-object-label | Apple |
| recommended-max-working-set-size | Recommended Max Working Set Size | size-in-bytes | 77.76 GiB |
| headless | Headless | boolean | No |
| removable | Removable | boolean | No |
| low-power | Low Power | boolean | No |
| mobile | Mobile | boolean | Yes |
| agx-tracecode-version | AGX Tracecode Version | string | 3.44.12 |
| perf-map | Performance State Map | uint64 | 18,446,744,073,709,551,615 |

### metal-known-compositor-process (documentation=Marks compositor processes), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.000.000 |
| compositor-name | Compositor Name | metal-object-label | WindowServer |
| pid | PID | uint64 | 635 |
| process | Process | process | WindowServer (635) |

### os-log (enable-priority-inversion-detection=0, target-pid=SINGLE, message-type=Fault, category="Hang Risk" "Severe Hang Risk" CFNetwork Contacts CoreML, subsystem="com.apple.runtime-issues", documentation=Holds a message from the OS's Unified Logging and Tracing component.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| process | Process | process |  |
| message-type | Type | event-type |  |
| format-string | Format String | format-string |  |
| backtrace | Backtrace | text-backtrace |  |
| subsystem | Subsystem | subsystem |  |
| category | Category | category |  |
| message | Message | os-log-metadata |  |
| emit-location | Emit Location | return-location |  |

### metal-gpu-info (documentation=Marks GPU info), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.000.000 |
| gpu-name | GPU Name | metal-object-label | M3 Ultra |
| gpu-index | GPU Index | uint32 | 1 |
| accelerator-id | Accelerator ID | uint64 | 1,463 |
| mobile | Mobile | boolean | Yes |

### graphics-compiler-activity-intervals (target-pid=SINGLE, documentation=Denotes a period of activity in the graphics compiler in the Metal API.), 52 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start Time | start-time | 00:00.885.143 | 00:00.890.229 | 00:00.890.282 |
| duration | Duration | duration | 4.97 ms | 25.17 µs | 16.38 µs |
| event-plane | Plane | metal-encoding-para | 0x0 | 0x0 | 0x0 |
| compiler | Shader Compiler | shader-compiler-name | Metal Shader Compiler | Metal Shader Compiler | Metal Shader Compiler |
| program-type | Source | formatted-label | Compile Compute shader (python (99926)) | Compile Compute shader (python (99926)) | Compile Compute shader (python (99926)) |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| event-priority | Priority | metal-workload-priority | 0x0 | 0x0 | 0x0 |
| color | Color | render-buffer-depth | 3 | 3 | 3 |

### metal-command-buffer-frame-assignment (documentation=Resolves Metal Command Buffer frame assignment), 31682 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.900.359 | 00:00.908.795 | 00:00.920.666 |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189052 | 0x154d189054 |
| commit-time | Commit Time | uint64 | 900,876,875 | 910,257,541 | 922,101,500 |
| commit-id | Commit ID | uint64 | 0 | 0 | 0 |
| frame-number | Frame | uint32 | 1 | 2 | 3 |
| frame-color | Color | uint32 | 0 | 0 | 0 |
| cmdbuffer-index | Index | uint32 | 0 | 0 | 0 |
| has-present | Has Present | uint32 | 0 | 0 | 0 |
| is-compositor | Compositor Type | uint32 | 0 | 0 | 0 |
| type-name | Command Buffer Type | string | Command Buffer | Command Buffer | Command Buffer |
| present-surface-id | Present Surface ID | gpu-driver-surface | 0x0 | 0x0 | 0x0 |
| compositor-cmdbuffer-id | Compositor Commmand Buffer Id | metal-command-buffer-id | 0x0 | 0x0 | 0x0 |
| xr-frame | XR Frame | uint32 | 0 | 0 | 0 |
| pid | PID | uint64 | 99,926 | 99,926 | 99,926 |
| process | Process | process | python (99926) | python (99926) | python (99926) |

### kdebug-strings (codes="33,0x11", target=SINGLE, documentation=Associates numeric arguments with strings in kdebug trace points.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| raw-string | Raw String | raw-string |  |
| raw-string-id | Raw String ID | kdebug-string |  |
| class | Class | kdebug-class |  |
| subclass | Subclass | kdebug-subclass |  |
| code | Code | kdebug-code |  |
| function | Qualifier | kdebug-func |  |
| thread | Thread | thread |  |
| core-index | Core Index | core |  |

### kdebug-strings (codes="0x1f,0x05", target=SINGLE, documentation=Associates numeric arguments with strings in kdebug trace points.), 888 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.677.933 | 00:00.677.933 | 00:00.678.016 |
| raw-string | Raw String | raw-string | /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyl |  | /usr/lib/dyld |
| raw-string-id | Raw String ID | kdebug-string | 0x70ac0000210c90bc | 0x70ac0000210c90bc | 0x70ac0000210c90bd |
| class | Class | kdebug-class | 0x1f | 0x1f | 0x1f |
| subclass | Subclass | kdebug-subclass | 0x5 | 0x5 | 0x5 |
| code | Code | kdebug-code | 0xa | 0xa | 0x5 |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 6 (P Core) | CPU 6 (P Core) | CPU 6 (P Core) |

### kdebug-strings (codes="0x85,0x1" "0x85,0x2" "0x85,0x8" "0x85,0x30" "0x85,0xc0" "0x85,0xc1" "0x31,0xca", documentation=Associates numeric arguments with strings in kdebug trace points.), 106842 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.873.128 | 00:00.879.373 | 00:00.879.400 |
| raw-string | Raw String | raw-string | AGXHeap with guard | AGXHeap without guard | AGXHeap with guard |
| raw-string-id | Raw String ID | kdebug-string | 0x70ac0000210c94a8 | 0x70ac0000210c94a9 | 0x70ac0000210c94aa |
| class | Class | kdebug-class | 0x85 | 0x85 | 0x85 |
| subclass | Subclass | kdebug-subclass | 0x8 | 0x8 | 0x8 |
| code | Code | kdebug-code | 0x0 | 0x0 | 0x0 |
| function | Qualifier | kdebug-func | POINT | POINT | POINT |
| thread | Thread | thread | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) | Main Thread (0x11ab5b7) (python, pid: 99926) |
| core-index | Core Index | core | CPU 6 (P Core) | CPU 7 (P Core) | CPU 7 (P Core) |

### device-display-info (documentation=Marks related info about Displays connected to the machine.), 1 rows

| mnemonic | name | engineering type | row 1 |
|---|---|---|---|
| timestamp | Timestamp | event-time | 00:00.000.000 |
| accelerator-id | Accelerator ID | uint64 | 4,294,968,759 |
| display-id | Display ID | uint64 | 8 |
| device-name | Device Name | metal-object-label | external-7 |
| framebuffer-index | Frame Buffer Index | uint32 | 7 |
| resolution | Resolution | size-in-pixels | (1920,1080) |
| pixel-width | Pixel Width | uint32 | 4294967295 |
| pixel-height | Pixel Height | uint32 | 4294967295 |
| built-in | Built-In | boolean | No |
| max-refresh-rate | Max Refresh Rate | uint32 | 120 |
| is-main-display | Main Display | boolean | No |

### metal-gpu-counter-profile (counter-profile=0, counter-device=0, shader-profiler=0, documentation=Denotes GPU Counter value intervals), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | start-time |  |

### display-surface-queue (documentation=Describes display surface queueing events.), 15 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:01.259.187 | 00:01.509.484 | 00:01.717.656 |
| swap-id | Swap ID | displayed-surface-swap | 0xe34ad | 0xe34ae | 0xe34af |
| framebuffer-index | Framebuffer Index | uint32 | 41 | 41 | 41 |

### metal-application-event-interval (target-pid=SINGLE, documentation=Marks metal application events such as Debug Groups on command buffer), 10528 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start Time | start-time | 00:02.566.689 | 00:02.566.691 | 00:02.567.010 |
| duration | Duration | duration | 1.00 µs | 500 ns | 1.08 µs |
| event-depth | Depth | metal-nesting-level | 0 | 0 | 0 |
| gpu | Metal Device | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| event-type | Event Type | metal-event-name | Completion Handlers | Completion Handlers | Completion Handlers |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| thread | Thread | thread | python (0x11ab9f0) (python, pid: 99926) | python (0x11ab9f0) (python, pid: 99926) | python (0x11aba0f) (python, pid: 99926) |
| event-label | Event | formatted-label | Command Buffer 0 Scheduled Handler (python (99926)) | Command Buffer 0 Scheduled Handler (python (99926)) | Command Buffer 0 Scheduled Handler (python (99926)) |
| event-priority | Priority | metal-workload-priority | 0x1 | 0x1 | 0x1 |
| color | Color | render-buffer-depth | 0 | 0 | 0 |
| connection-UUID | Connection UUID | connection-uuid64 | 57119 | 57128 | 57142 |

### metal-gpu-counter-intervals (documentation=Denotes GPU Counter value intervals), 1696109 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start | start-time | 00:00.261.183 | 00:00.261.186 | 00:00.261.189 |
| duration | Duration | duration | 2.96 µs | 2.96 µs | 2.96 µs |
| counter-id | Counter ID | uint32 | 0 | 0 | 0 |
| name | Counter Name | gpu-counter-name | RT Unit Active | RT Unit Active | RT Unit Active |
| label | Label | formatted-label | 0.0000% (Percentage of GPU Cores where raytracing unit is ac | 0.0000% (Percentage of GPU Cores where raytracing unit is ac | 0.0000% (Percentage of GPU Cores where raytracing unit is ac |
| value | Value | fixed-decimal | 0.0000 | 0.0000 | 0.0000 |
| percent-value | Percent Value | percent | 0.0% | 0.0% | 0.0% |
| color | Color | uint32 | 0 | 0 | 0 |
| gpu | GPU | metal-device-name | M3 Ultra | M3 Ultra | M3 Ultra |
| group-index | Group Index | uint32 | 1 | 1 | 1 |
| is-percentage | Is Percentage | boolean | Yes | Yes | Yes |
| ring-buffer-index | Ring Buffer Index | uint32 | 2 | 2 | 2 |

### metal-gpu-execution-points (documentation=Denotes an interesting points of activity in the GPU.), 126684 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.907.208 | 00:00.907.221 | 00:00.910.416 |
| channel-id | Channel ID | metal-command-buffer-id | 0x123459 | 0x123459 | 0x123459 |
| function | Function | uint32 | 1 | 2 | 1 |
| slot-id | Slot ID | uint32 | 1310232665 | 1310232665 | 1310232709 |
| gpu-submission-id | GPU Submission ID | metal-command-buffer-id | 0x4e189059 | 0x4e189059 | 0x4e189085 |
| accelerator-id | Accelerator Id | uint64 | 18,446,744,073,709,551,615 | 18,446,744,073,709,551,615 | 18,446,744,073,709,551,615 |
| note | Note | string |  |   |  |

### os-signpost (category="CAMetalLayer.Stalls", subsystem="com.apple.coreanimation", documentation=Holds a signpost event from the OS's Unified Logging and Tracing component.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| process | Process | process |  |
| event-type | Event Type | event-type |  |
| scope | Scope | string |  |
| identifier | Signpost identifier | os-signpost-identifier |  |
| name | Name | signpost-name |  |
| format-string | Format String | format-string |  |
| backtrace | Backtrace | text-backtrace |  |
| subsystem | Subsystem | subsystem |  |
| category | Category | category |  |
| message | Message | os-log-metadata |  |
| emit-location | Emit Location | return-location |  |

### os-signpost (category=CAMetalLayer, subsystem="com.apple.coreanimation", documentation=Holds a signpost event from the OS's Unified Logging and Tracing component.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| process | Process | process |  |
| event-type | Event Type | event-type |  |
| scope | Scope | string |  |
| identifier | Signpost identifier | os-signpost-identifier |  |
| name | Name | signpost-name |  |
| format-string | Format String | format-string |  |
| backtrace | Backtrace | text-backtrace |  |
| subsystem | Subsystem | subsystem |  |
| category | Category | category |  |
| message | Message | os-log-metadata |  |
| emit-location | Emit Location | return-location |  |

### os-signpost (category=ShaderTimeline, subsystem="com.apple.Metal.AGXSignposts", documentation=Holds a signpost event from the OS's Unified Logging and Tracing component.), 4858 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| time | Timestamp | event-time | 00:00.932.101 | 00:00.932.103 | 00:00.932.104 |
| thread | Thread | thread | python (0x11aba0f) (python, pid: 99926) | python (0x11aba0f) (python, pid: 99926) | python (0x11aba0f) (python, pid: 99926) |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| event-type | Event Type | event-type | Event | Event | Event |
| scope | Scope | string | Process | Process | Process |
| identifier | Signpost identifier | os-signpost-identifier | OS_SIGNPOST_ID_EXCLUSIVE | OS_SIGNPOST_ID_EXCLUSIVE | OS_SIGNPOST_ID_EXCLUSIVE |
| name | Name | signpost-name | FunctionCompiled | FunctionCompiled | FunctionCompiled |
| format-string | Format String | format-string | Name=%{public,signpost.description:attribute}s               | Name=%{public,signpost.description:attribute}s               | Name=%{public,signpost.description:attribute}s               |
| backtrace | Backtrace | text-backtrace |  |  |  |
| subsystem | Subsystem | subsystem | com.apple.Metal.AGXSignposts | com.apple.Metal.AGXSignposts | com.apple.Metal.AGXSignposts |
| category | Category | category | ShaderTimeline | ShaderTimeline | ShaderTimeline |
| message | Message | os-log-metadata | Name=copyInteractionCounts              Label=               | Name=findBlocksWithInteractions              Label=          | Name=sortBoxData              Label=              Type=compu |
| emit-location | Emit Location | return-location | invocation function for block in AGX::Device<AGX::G15::Encod | invocation function for block in AGX::Device<AGX::G15::Encod | invocation function for block in AGX::Device<AGX::G15::Encod |

### os-signpost (category=InduceCondition, subsystem="com.apple.ConditionInducer.LowSeverity", documentation=Holds a signpost event from the OS's Unified Logging and Tracing component.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | event-time |  |
| thread | Thread | thread |  |
| process | Process | process |  |
| event-type | Event Type | event-type |  |
| scope | Scope | string |  |
| identifier | Signpost identifier | os-signpost-identifier |  |
| name | Name | signpost-name |  |
| format-string | Format String | format-string |  |
| backtrace | Backtrace | text-backtrace |  |
| subsystem | Subsystem | subsystem |  |
| category | Category | category |  |
| message | Message | os-log-metadata |  |
| emit-location | Emit Location | return-location |  |

### visual-connection (content=metal-connections, target-pid=SINGLE, documentation=Connects points on a graph between instruments or tracks.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| time | Timestamp | sample-time |  |
| duration | Duration | duration |  |
| uuid | UUID | connection-uuid64 |  |
| source-uuid | Source UUID | connection-uuid64 |  |
| sink-uuid | Sink UUID | connection-uuid64 |  |
| filter | Filter | connection-filter |  |
| metadata | Metadata | connection-meta |  |
| color | Color | any |  |
| route | Route | connection-route |  |

### runloop-events (target-pid=SINGLE), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | event-time |  |
| timestamp-accuracy | Timestamp Accuracy | string |  |
| interval-type | Runloop Interval | short-string |  |
| event-type | Event Type | kdebug-func |  |
| interval-identifier | Interval Identifier | short-string |  |
| nesting-level | Nesting Level | uint64 |  |
| mode | RunLoop Mode | medium-length-string |  |
| is-main | Main RunLoop | boolean |  |
| thread | Thread | thread |  |
| runloop-pointer | Runloop | address |  |
| timeout | Timeout | uint64 |  |
| other-arg | Other Argument | uint64 |  |

### graphics-compiler-spill-events (documentation=Marks compiler spill events), 78935 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.929.743 | 00:00.936.829 | 00:00.936.832 |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189058 | 0x154d18905c | 0x154d18905c |
| encoder-id | Encoder Id | uint64 | 91,487,768,667 | 91,487,768,669 | 91,487,768,669 |
| spilled-bytes | Spilled bytes | size-in-bytes | 16 Bytes | 16 Bytes | 16 Bytes |
| process | Process | process | python (99926) | python (99926) | python (99926) |

### displayed-surfaces-per-second (documentation=Shows how many surfaces have been displayed per second), 6 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start Time | start-time | 00:00.000.000 | 00:02.000.000 | 00:03.000.000 |
| duration | Duration | duration | 2.00 s | 1.00 s | 1.00 s |
| display-name | Display Name | display-name | Built-In Display | Built-In Display | Built-In Display |
| count | Count | uint32 | 2 | 3 | 4 |
| event-label | Label | narrative | 2 surface swaps | 3 surface swaps | 4 surface swaps |

### metal-kernel-resource-allocations (target-pid=SINGLE, documentation=Marks a point in time where the application may created a driver back for Metal resource), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | start-time |  |
| process | Process | process |  |
| thread | Thread | thread |  |
| resource-id | ID | displayed-surface-io-surface |  |
| vidmem-bytes | Video Memory Bytes | size-in-bytes |  |
| sysmem-bytes | System Memory Bytes | size-in-bytes |  |
| gpu | Metal Device | metal-device-name |  |
| resource-type | Resource Type | metal-object-label |  |
| event-type | Event Type | gpu-memory-event-name |  |

### metal-command-buffer-to-accelerator-id (documentation=Maps between Metal command buffer ID and accelerator ID), 31682 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:00.900.921 | 00:00.910.277 | 00:00.922.122 |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x154d189050 | 0x154d189052 | 0x154d189054 |
| accelerator-id | Accelerator ID | uint64 | 1,463 | 1,463 | 1,463 |

### metal-residency-set-interval (documentation=Denotes a MTLResidencySet interval), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| start | Creation | start-time |  |
| duration | Duration | duration |  |
| residency-set-id | Set Id | uint64 |  |
| label | Label | metal-object-label |  |
| event-priority | Priority | metal-workload-priority |  |
| event-type | Event Type | metal-residency-set-resource-event |  |
| event-depth | Event Depth | metal-nesting-level |  |
| color | Color | render-buffer-depth |  |
| process | Process | process |  |
| gpu | Metal Device | metal-device-name |  |
| event-label | Description | narrative |  |

### metal-io-surface-access (documentation=Denotes IO Surface accesses by Metal Applications), 81 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| timestamp | Timestamp | start-time | 00:01.258.381 | 00:01.258.381 | 00:01.258.433 |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id | 0x3ac1a69 | 0x3ac1a69 | 0x3ac1a69 |
| encoder-id | Encoder ID | uint64 | 61,610,602 | 61,610,602 | 61,610,603 |
| gpu-submission-id | GPU Submission ID | metal-command-buffer-id | 0x4e18b6c9 | 0x4e18b6c9 | 0x4e18b6d4 |
| submission-id | Submission ID | metal-command-buffer-id | 0x4e18b6c9 | 0x4e18b6c9 | 0x4e18b6d4 |
| segment-id | Segment ID | metal-command-buffer-id | 0x154e18b6c6 | 0x154e18b6c6 | 0x154e18b6d3 |
| channel-id | Channel ID | metal-command-buffer-id | 0x400059b | 0x400059b | 0x400059b |
| accelerator-id | Accelerator ID | uint64 | 4,294,968,759 | 4,294,968,759 | 4,294,968,759 |
| surface-id | Surface ID | uint64 | 239 | 560 | 560 |
| pixel-format | Pixel Format | string | 0vx& | 83b& | 83b& |
| width | Width | uint32 | 4480 | 1920 | 1920 |
| height | Height | uint32 | 3088 | 1080 | 1080 |
| access-type | Access Type | uint32 | 0 | 1 | 0 |
| pid | PID | uint64 | 635 | 635 | 635 |
| process | Process | process | WindowServer (635) | WindowServer (635) | WindowServer (635) |

### metal-object-dependency-chain-gpu (track-id-base=2000, documentation=Visual highlight for Metal System Trace), 63341 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| in-time | In Time | start-time | 00:00.907.208 | 00:00.910.416 | 00:00.923.091 |
| root-id | Root ID | uint64 | 91,504,545,880 | 91,504,545,924 | 91,504,545,957 |
| out-time | Out Time | uint64 | 907,221,916 | 910,423,500 | 923,105,583 |
| block-id | Block ID | uint64 | 1 | 2 | 3 |
| color | Color | uint32 | 0 | 0 | 0 |
| track-id | Track | uint32 | 1195049 | 1195049 | 1195049 |

### ca-client-presented-handler (documentation=Denotes CAMetalDrawable presented handlers.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | start-time |  |
| drawable-id | Drawable Id | displayed-surface-swap |  |
| status | Status | uint64 |  |
| at-time | Requested Time | start-time |  |
| delta | Delta | duration |  |
| thread | Thread | thread |  |
| process | Process | process |  |

### ca-client-present-request (documentation=Denotes client requests to present a CAMetalDrawable.), 0 rows

| mnemonic | name | engineering type |  |
|---|---|---|
| timestamp | Timestamp | start-time |  |
| cmdbuffer-id | Commmand Buffer Id | metal-command-buffer-id |  |
| surface-id | Surface Id | displayed-surface-swap |  |
| at-time | Requested Time | start-time |  |
| minimal-duration | Minimal Duration | start-time |  |
| thread | Thread | thread |  |
| process | Process | process |  |

### ProcessCPUUsage, 541 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start Time | start-time | 00:00.670.000 | 00:00.680.000 | 00:00.690.000 |
| duration | Duration | duration | 10.00 ms | 10.00 ms | 10.00 ms |
| process | Process | process | python (99926) | python (99926) | python (99926) |
| cpu-usage | CPU Usage | system-cpu-percent | 20.0% | 100.0% | 100.0% |

### SystemCPUUsage, 608 rows

| mnemonic | name | engineering type | row 1 | row 2 | row 3 |
|---|---|---|---|---|---|
| start | Start Time | start-time | 00:00.000.000 | 00:00.010.000 | 00:00.020.000 |
| duration | Duration | duration | 10.00 ms | 10.00 ms | 10.00 ms |
| cpu-usage | CPU Usage | system-cpu-percent | 0.0% | 0.0% | 0.0% |
