"""Ask the OpenCL platform for mixed and double precision on this Mac and print what it says."""
import openmm as mm

system = mm.System()
system.addParticle(1.0)
platform = mm.Platform.getPlatformByName("OpenCL")
for precision in ("single", "mixed", "double"):
    try:
        context = mm.Context(system, mm.VerletIntegrator(0.001), platform, {"Precision": precision})
        print(precision, "created:", platform.getPropertyValue(context, "Precision"), platform.getPropertyValue(context, "DeviceName"))
        del context
    except Exception as e:
        print(precision, "refused:", str(e).strip())
