; ModuleID = 'nanf-test.metal'
source_filename = "nanf-test.metal"
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64_v29-apple-macosx27.2.0"

; Function Attrs: argmemonly mustprogress nofree norecurse nosync nounwind willreturn
define void @nanChecks(float addrspace(1)* nocapture noundef readonly "air-buffer-no-alias" %0, i32 addrspace(1)* nocapture noundef writeonly "air-buffer-no-alias" %1, i32 noundef %2) local_unnamed_addr #0 {
  %4 = zext i32 %2 to i64
  %5 = getelementptr inbounds float, float addrspace(1)* %0, i64 %4
  %6 = load float, float addrspace(1)* %5, align 4, !tbaa !22, !alias.scope !26, !noalias !29
  %7 = fdiv fast float 1.000000e+00, %6
  %8 = bitcast float %6 to i32
  %9 = and i32 %8, 2147483647
  %10 = icmp ugt i32 %9, 2139095040
  %11 = zext i1 %10 to i32
  %12 = bitcast float %7 to i32
  %13 = and i32 %12, 2147483647
  %14 = icmp eq i32 %13, 2139095040
  %15 = or i32 %11, 2
  %16 = select i1 %14, i32 %15, i32 %11
  %17 = fmul fast float %6, %6
  %18 = bitcast float %17 to i32
  %19 = and i32 %18, 2139095040
  %20 = icmp eq i32 %19, 2139095040
  %21 = or i32 %16, 4
  %22 = select i1 %20, i32 %21, i32 %16
  %23 = fcmp fast ogt float %6, 0.000000e+00
  %24 = or i32 %22, 16
  %25 = select i1 %23, i32 %22, i32 %24
  %26 = getelementptr inbounds i32, i32 addrspace(1)* %1, i64 %4
  store i32 %25, i32 addrspace(1)* %26, align 4, !tbaa !31, !alias.scope !29, !noalias !26
  ret void
}

attributes #0 = { argmemonly mustprogress nofree norecurse nosync nounwind willreturn "approx-func-fp-math"="true" "frame-pointer"="all" "min-legal-vector-width"="0" "no-builtins" "no-infs-fp-math"="true" "no-nans-fp-math"="true" "no-signed-zeros-fp-math"="true" "no-trapping-math"="true" "stack-protector-buffer-size"="8" "unsafe-fp-math"="true" }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7, !8}
!air.kernel = !{!9}
!air.compile_options = !{!15, !16, !17}
!llvm.ident = !{!18}
!air.version = !{!19}
!air.language_version = !{!20}
!air.source_file_name = !{!21}

!0 = !{i32 2, !"SDK Version", [2 x i32] [i32 27, i32 2]}
!1 = !{i32 1, !"wchar_size", i32 4}
!2 = !{i32 7, !"frame-pointer", i32 2}
!3 = !{i32 7, !"air.max_device_buffers", i32 31}
!4 = !{i32 7, !"air.max_constant_buffers", i32 31}
!5 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!6 = !{i32 7, !"air.max_textures", i32 128}
!7 = !{i32 7, !"air.max_read_write_textures", i32 8}
!8 = !{i32 7, !"air.max_samplers", i32 16}
!9 = !{void (float addrspace(1)*, i32 addrspace(1)*, i32)* @nanChecks, !10, !11}
!10 = !{}
!11 = !{!12, !13, !14}
!12 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"float", !"air.arg_name", !"x"}
!13 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.read_write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"int", !"air.arg_name", !"out"}
!14 = !{i32 2, !"air.thread_position_in_grid", !"air.arg_type_name", !"uint", !"air.arg_name", !"i"}
!15 = !{!"air.compile.denorms_disable"}
!16 = !{!"air.compile.fast_math_enable"}
!17 = !{!"air.compile.framebuffer_fetch_enable"}
!18 = !{!"Apple metal version 32023.922 (metalfe-32023.922.2)"}
!19 = !{i32 2, i32 9, i32 0}
!20 = !{!"Metal", i32 3, i32 2, i32 0}
!21 = !{!"/private/tmp/openmm-metal-bench/ultra-mixed/ulp/nanf-test.metal"}
!22 = !{!23, !23, i64 0}
!23 = !{!"float", !24, i64 0}
!24 = !{!"omnipotent char", !25, i64 0}
!25 = !{!"Simple C++ TBAA"}
!26 = !{!27}
!27 = distinct !{!27, !28, !"air-alias-scope-arg(0)"}
!28 = distinct !{!28, !"air-alias-scopes(nanChecks)"}
!29 = !{!30}
!30 = distinct !{!30, !28, !"air-alias-scope-arg(1)"}
!31 = !{!32, !32, i64 0}
!32 = !{!"int", !24, i64 0}
